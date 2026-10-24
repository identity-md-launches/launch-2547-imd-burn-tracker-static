// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

/// @dev Intake v2's public client interface, from the supplied protocol reference.
interface IIntake {
    struct Callback {
        address target;
        bytes4 selector;
    }

    function priceOf(bytes32 action, address asset) external view returns (uint256);
    function requestWithFailure(
        bytes32 action,
        bytes calldata body,
        Callback calldata callback,
        bytes4 onFailure,
        address asset,
        uint256 amount
    ) external payable returns (bytes32 requestId);
}

/// @notice Persistent payer for the IMD burn tracker and its owner-defined refresh template.
/// @dev No funds are escrowed. The Intake spends the payment even if work fails or is refused.
contract BurnTracker is ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    uint8 public constant UNOPENED = 1;
    uint8 public constant IDLE = 2;
    uint8 public constant PENDING = 3;
    uint8 public constant STUCK = 4;
    uint8 public constant OPEN = 1;
    uint8 public constant CONTINUE = 2;
    uint8 public constant RECOVER = 3;
    uint32 public constant MIN_TIMING = 1 hours;
    uint32 public constant MAX_TIMING = 30 days;
    uint256 public constant MAX_BODY_BYTES = 16_384;

    address public owner;
    address public pendingOwner;
    address public intake;
    address public asset;
    bytes32 public openAction;
    bytes32 public continueAction;
    bytes public bodyPrefix;
    bytes public bodySuffix;
    /// @dev 1 is an initial sentinel, never usable in UNOPENED. Zero hashes are rejected so this
    /// callback-written slot stays nonzero for its entire lifetime (including after recovery).
    bytes32 public resultHash = bytes32(uint256(1));
    bytes32 public lastRequestId;
    address private _pendingIntake;
    bool private _defaultBody = true;

    /// @dev Exactly one slot. State and timing are always nonzero; callbacks never create a slot.
    struct Status {
        uint8 state;
        uint8 pendingKind;
        uint40 lastDone;
        uint40 orderedAt;
        uint40 staleAt;
        uint32 cooldown;
        uint32 staleAfter;
    }

    Status private _status;

    error NotOwner();
    error NotPendingOwner();
    error InvalidAddress();
    error InvalidAction();
    error InvalidTiming();
    error InvalidBody();
    error InvalidHash();
    error InvalidResultJson();
    error InvalidParentJobId();
    error WrongState();
    error CooldownActive(uint256 until);
    error NotPending(bytes32 requestId);
    error InvalidFailureStatus();
    error ActionNotSold();
    error PriceTooHigh(uint256 quoted, uint256 maximum);
    error UnsupportedAsset();
    error InvalidRequestId();

    event Ordered(bytes32 indexed requestId, uint8 kind, address indexed payer, uint256 amount, string parentJobId);
    event Updated(bytes32 indexed requestId, bytes32 resultHash, string uri);
    event Failed(bytes32 indexed requestId, uint8 status, bytes32 reason, uint8 newState);
    event ResultHashSet(bytes32 indexed previousRequestId, bytes32 resultHash);
    event BodySet(bytes prefix, bytes suffix);
    event ActionsSet(bytes32 openAction, bytes32 continueAction);
    event IntakeSet(address intake, address asset);
    event TimingSet(uint32 cooldown, uint32 staleAfter);
    event Withdrawn(address indexed token, address indexed to, uint256 amount);
    event OwnershipTransferStarted(address indexed owner, address indexed pendingOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(
        address owner_,
        address intake_,
        address asset_,
        bytes32 openAction_,
        bytes32 continueAction_,
        uint32 cooldown_,
        uint32 staleAfter_
    ) {
        if (owner_ == address(0) || intake_ == address(0) || asset_ == address(0)) {
            revert InvalidAddress();
        }
        if (openAction_ == bytes32(0) || continueAction_ == bytes32(0)) revert InvalidAction();
        _checkTiming(cooldown_, staleAfter_);
        owner = owner_;
        intake = intake_;
        asset = asset_;
        openAction = openAction_;
        continueAction = continueAction_;
        _pendingIntake = intake_;
        _status = Status(UNOPENED, 0, 0, 0, 0, cooldown_, staleAfter_);
        bodyPrefix = '{"parentJobId":"';
        bodySuffix = _initialSuffix();
        emit OwnershipTransferred(address(0), owner_);
    }

    /// @notice The owner opens a project, or replaces a failed/stale hosting order.
    function open(bytes calldata body) external onlyOwner nonReentrant returns (bytes32 requestId) {
        uint8 state = _status.state;
        if (state != UNOPENED && state != STUCK && !_stale()) revert WrongState();
        return _order(OPEN, openAction, body, "", type(uint256).max);
    }

    /// @notice Anyone can fund a refresh using the exact bytes authenticated by the last callback.
    function updateBurntracker(bytes calldata resultJson, uint256 maxPrice)
        external
        nonReentrant
        returns (bytes32 requestId)
    {
        if (_status.state != IDLE) revert WrongState();
        uint256 until = nextUpdateAt();
        if (block.timestamp < until) revert CooldownActive(until);
        if (keccak256(resultJson) != resultHash) revert InvalidHash();
        bytes memory parent = parentJobIdOf(resultJson);
        return _order(CONTINUE, continueAction, _bodyOf(parent), string(parent), maxPrice);
    }

    /// @notice Owner override for blocked work or a lost callback. The named parent must be a UUID.
    function recover(string calldata parentJobId) external onlyOwner nonReentrant returns (bytes32 requestId) {
        _checkRecoverable();
        bytes memory parent = bytes(parentJobId);
        _checkUuid(parent);
        return _order(RECOVER, continueAction, _bodyOf(parent), parentJobId, type(uint256).max);
    }

    /// @notice Adopt a completion off chain; cancels the awaited callback and restarts the cooldown.
    function setResultHash(bytes32 hash) external onlyOwner nonReentrant {
        _checkRecoverable();
        if (hash == bytes32(0)) revert InvalidHash();
        resultHash = hash;
        _done();
        emit ResultHashSet(lastRequestId, hash);
    }

    /// @dev Intentionally only two existing slots can be written, with no external calls.
    function onResult(bytes32 requestId, bytes32 hash, string calldata uri) external {
        _checkCallback(requestId);
        if (hash == bytes32(0)) revert InvalidHash();
        resultHash = hash;
        _done();
        emit Updated(requestId, hash, uri);
    }

    /// @dev Status 1 is refusal; status 2 is failed work. Other statuses cannot settle an order.
    function onFailure(bytes32 requestId, uint8 failureStatus, bytes32 reason, uint16, uint16, bytes calldata)
        external
    {
        _checkCallback(requestId);
        if (failureStatus != 1 && failureStatus != 2) revert InvalidFailureStatus();
        uint8 kind = _status.pendingKind;
        uint8 newState = STUCK;
        if (failureStatus == 1) {
            if (kind == OPEN) {
                newState = UNOPENED;
            } else if (kind == CONTINUE) {
                newState = IDLE;
                _status.lastDone = uint40(block.timestamp);
            }
        }
        _status.state = newState;
        _status.pendingKind = 0;
        emit Failed(requestId, failureStatus, reason, newState);
    }

    /// @notice Extract the sole literal jobId key from canonical result JSON. Skips whole strings,
    /// including escaped quotes; rejects escaped keys (canonical result keys are unescaped).
    /// This is a bounded-purpose extractor, not a general JSON/schema validator.
    function parentJobIdOf(bytes calldata json) public pure returns (bytes memory parent) {
        uint256 n = json.length;
        if (n < 2 || json[0] != "{" || json[n - 1] != "}") revert InvalidResultJson();
        return _plainParent(json);
    }

    function _escapedParent(bytes calldata json) private pure returns (bytes memory parent) {
        uint256 idOffset;
        // The scanner works in calldata; only the 36-byte UUID is copied to memory. Within a
        // string it locates quote/backslash candidates in 32-byte words, then checks candidates.
        // This avoids a Solidity bounds check and a new word scan for every character.
        assembly ("memory-safe") {
            function invalidJson() {
                mstore(0, 0x777873aa)
                revert(28, 4)
            }
            function invalidId() {
                mstore(0, 0x77da5df1)
                revert(28, 4)
            }
            function skipSpace(p, end) -> next {
                next := p
                for {} lt(next, end) {} {
                    let c := byte(0, calldataload(next))
                    if iszero(or(or(eq(c, 32), eq(c, 9)), or(eq(c, 10), eq(c, 13)))) { break }
                    next := add(next, 1)
                }
            }
            function stringEnd(p, end) -> close, escaped {
                for {} lt(p, end) {} {
                    let w := calldataload(p)
                    let q := xor(w, 0x2222222222222222222222222222222222222222222222222222222222222222)
                    let b := xor(w, 0x5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c)
                    let ones := 0x0101010101010101010101010101010101010101010101010101010101010101
                    let high := 0x8080808080808080808080808080808080808080808080808080808080808080
                    let mask := or(and(and(sub(q, ones), not(q)), high), and(and(sub(b, ones), not(b)), high))
                    if iszero(mask) {
                        p := add(p, 32)
                        continue
                    }
                    // Locate the first candidate with binary search. Multiplication/division by
                    // powers of two avoids ambiguity about Yul shift operand ordering.
                    if iszero(div(mask, 0x100000000000000000000000000000000)) {
                        p := add(p, 16)
                        mask := mul(mask, 0x100000000000000000000000000000000)
                    }
                    if iszero(div(mask, 0x1000000000000000000000000000000000000000000000000)) {
                        p := add(p, 8)
                        mask := mul(mask, 0x10000000000000000)
                    }
                    if iszero(div(mask, 0x100000000000000000000000000000000000000000000000000000000)) {
                        p := add(p, 4)
                        mask := mul(mask, 0x100000000)
                    }
                    if iszero(div(mask, 0x1000000000000000000000000000000000000000000000000000000000000)) {
                        p := add(p, 2)
                        mask := mul(mask, 0x10000)
                    }
                    if iszero(byte(0, mask)) { p := add(p, 1) }
                    if iszero(lt(p, end)) { invalidJson() }
                    let c := byte(0, calldataload(p))
                    if eq(c, 34) {
                        close := p
                        leave
                    }
                    if eq(c, 92) {
                        escaped := 1
                        p := add(p, 1)
                    }
                    // Borrow in the zero-byte test can add false candidates, never omit one.
                    // A false candidate is skipped by one byte and the remaining word rescanned.
                    p := add(p, 1)
                }
                invalidJson()
            }
            let end := add(json.offset, json.length)
            let p := add(json.offset, 1)
            let found := 0
            for {} lt(p, end) {} {
                if iszero(eq(byte(0, calldataload(p)), 34)) {
                    p := add(p, 1)
                    continue
                }
                let start := add(p, 1)
                let close, escaped := stringEnd(start, end)
                p := skipSpace(add(close, 1), end)
                if eq(byte(0, calldataload(p)), 58) {
                    if escaped { invalidJson() }
                    if and(
                        eq(sub(close, start), 5),
                        eq(
                            and(
                                calldataload(start),
                                0xffffffffff000000000000000000000000000000000000000000000000000000
                            ),
                            0x6a6f624964000000000000000000000000000000000000000000000000000000
                        )
                    ) {
                        if found { invalidJson() }
                        found := 1
                        p := skipSpace(add(p, 1), end)
                        if or(
                            gt(add(p, 38), end),
                            or(
                                iszero(eq(byte(0, calldataload(p)), 34)),
                                iszero(eq(byte(0, calldataload(add(p, 37))), 34))
                            )
                        ) { invalidId() }
                        idOffset := sub(add(p, 1), json.offset)
                        p := skipSpace(add(p, 38), end)
                        let c := byte(0, calldataload(p))
                        if or(iszero(lt(p, end)), iszero(or(eq(c, 44), eq(c, 125)))) { invalidJson() }
                    }
                }
            }
            if iszero(found) { invalidJson() }
        }
        parent = json[idOffset:idOffset + 36];
        _checkUuid(parent);
    }

    /// @dev In valid canonical JSON without escapes, the literal token "jobId" followed by a
    /// colon is necessarily a key. Documents containing any backslash use the lexical scanner.
    function _plainParent(bytes calldata json) private pure returns (bytes memory parent) {
        uint256 offset;
        bool escaped;
        assembly ("memory-safe") {
            function ws(p, end) -> next {
                next := p
                for {} lt(next, end) {} {
                    let c := byte(0, calldataload(next))
                    if iszero(or(or(eq(c, 32), eq(c, 9)), or(eq(c, 10), eq(c, 13)))) { break }
                    next := add(next, 1)
                }
            }
            let end := add(json.offset, json.length)
            let found := 0
            for { let p := add(json.offset, 1) } lt(p, end) {} {
                let chunk := calldataload(p)
                let b := xor(chunk, 0x5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c)
                if and(
                    and(sub(b, 0x0101010101010101010101010101010101010101010101010101010101010101), not(b)),
                    0x8080808080808080808080808080808080808080808080808080808080808080
                ) {
                    escaped := 1
                    break
                }
                let w := xor(chunk, 0x6a6a6a6a6a6a6a6a6a6a6a6a6a6a6a6a6a6a6a6a6a6a6a6a6a6a6a6a6a6a6a6a)
                let mask :=
                    and(
                        and(sub(w, 0x0101010101010101010101010101010101010101010101010101010101010101), not(w)),
                        0x8080808080808080808080808080808080808080808080808080808080808080
                    )
                if iszero(mask) {
                    p := add(p, 32)
                    continue
                }
                // Binary search the most significant candidate byte.
                if iszero(div(mask, 0x100000000000000000000000000000000)) {
                    p := add(p, 16)
                    mask := mul(mask, 0x100000000000000000000000000000000)
                }
                if iszero(div(mask, 0x1000000000000000000000000000000000000000000000000)) {
                    p := add(p, 8)
                    mask := mul(mask, 0x10000000000000000)
                }
                if iszero(div(mask, 0x100000000000000000000000000000000000000000000000000000000)) {
                    p := add(p, 4)
                    mask := mul(mask, 0x100000000)
                }
                if iszero(div(mask, 0x1000000000000000000000000000000000000000000000000000000000000)) {
                    p := add(p, 2)
                    mask := mul(mask, 0x10000)
                }
                if iszero(byte(0, mask)) { p := add(p, 1) }
                if iszero(lt(p, end)) { break }
                if and(
                    eq(byte(0, calldataload(sub(p, 1))), 34),
                    eq(
                        and(calldataload(p), 0xffffffffffff0000000000000000000000000000000000000000000000000000),
                        0x6a6f624964220000000000000000000000000000000000000000000000000000
                    )
                ) {
                    let colon := ws(add(p, 6), end)
                    if eq(byte(0, calldataload(colon)), 58) {
                        if found {
                            mstore(0, 0x777873aa)
                            revert(28, 4)
                        }
                        found := 1
                        let value := ws(add(colon, 1), end)
                        if or(
                            gt(add(value, 38), end),
                            or(
                                iszero(eq(byte(0, calldataload(value)), 34)),
                                iszero(eq(byte(0, calldataload(add(value, 37))), 34))
                            )
                        ) {
                            mstore(0, 0x77da5df1)
                            revert(28, 4)
                        }
                        offset := sub(add(value, 1), json.offset)
                        let tail := ws(add(value, 38), end)
                        let c := byte(0, calldataload(tail))
                        if or(iszero(lt(tail, end)), iszero(or(eq(c, 44), eq(c, 125)))) {
                            mstore(0, 0x777873aa)
                            revert(28, 4)
                        }
                    }
                }
                p := add(p, 1)
            }
            if and(iszero(escaped), iszero(found)) {
                mstore(0, 0x777873aa)
                revert(28, 4)
            }
        }
        if (escaped) return _escapedParent(json);
        parent = json[offset:offset + 36];
        _checkUuid(parent);
    }

    function _checkUuid(bytes memory id) private pure {
        if (id.length != 36) revert InvalidParentJobId();
        assembly ("memory-safe") {
            let start := add(id, 32)
            for { let i := 0 } lt(i, 36) { i := add(i, 1) } {
                // Read only the two allocated, aligned data words, including for the final byte.
                let c := byte(and(i, 31), mload(add(start, and(i, not(31)))))
                let dash := or(or(eq(i, 8), eq(i, 13)), or(eq(i, 18), eq(i, 23)))
                let valid := or(and(gt(c, 47), lt(c, 58)), and(gt(c, 96), lt(c, 103)))
                if dash { valid := eq(c, 45) }
                if iszero(valid) {
                    mstore(0, 0x77da5df1)
                    revert(28, 4)
                }
            }
        }
    }

    /// @dev Constructor stores both public parts. Until setBody is used, the identical literal
    /// avoids reading 23 cold storage words on each refresh. Owner-edited parts use storage.
    function _bodyOf(bytes memory parent) private view returns (bytes memory) {
        if (_defaultBody) return bytes.concat(bytes('{"parentJobId":"'), parent, _initialSuffix());
        return bytes.concat(bodyPrefix, parent, bodySuffix);
    }

    function _initialSuffix() private pure returns (bytes memory) {
        return bytes(
            "\",\"objective\":\"Refresh the IMD burn tracker\'s data and host the site again. Build it with the repository\'s own build script (package.json), which needs network access: it refreshes the data files in dist/data/ from public sources, or keeps them and notes why in dist/data/imd-refresh-status.json. Change nothing else: the hosted files are dist/ after that build. Decide, do not ask: a question blocks the job.\",\"shape\":\"chain\",\"steps\":[{\"skill\":\"import-site\"},{\"skill\":\"site-content-check\",\"acceptanceCriteria\":[\"only files under dist/data/ differ from the parent version\",\"dist/index.html loads with no console error and shows the data\'s refresh time from dist/data/imd-refresh-status.json\"]}],\"ipfs\":true,\"github\":true}"
        );
    }

    /// @notice Current continuation price; a zero quote means the action is not sold.
    function price() public view returns (uint256) {
        return IIntake(intake).priceOf(continueAction, asset);
    }

    /// @notice Earliest refresh time in IDLE; zero in other states (not permission to update).
    function nextUpdateAt() public view returns (uint256) {
        return _status.state == IDLE ? uint256(_status.lastDone) + _status.cooldown : 0;
    }

    function status()
        external
        view
        returns (
            uint8 state,
            uint8 pendingKind,
            uint40 lastDone,
            uint40 orderedAt,
            uint40 staleAt,
            uint32 cooldown,
            uint32 staleAfter
        )
    {
        Status memory s = _status;
        return (s.state, s.pendingKind, s.lastDone, s.orderedAt, s.staleAt, s.cooldown, s.staleAfter);
    }

    function setBody(bytes calldata prefix, bytes calldata suffix) external onlyOwner nonReentrant {
        if (prefix.length + suffix.length + 36 > MAX_BODY_BYTES) revert InvalidBody();
        _defaultBody = false;
        bodyPrefix = prefix;
        bodySuffix = suffix;
        emit BodySet(prefix, suffix);
    }

    function setActions(bytes32 open_, bytes32 continue_) external onlyOwner nonReentrant {
        if (open_ == bytes32(0) || continue_ == bytes32(0)) revert InvalidAction();
        openAction = open_;
        continueAction = continue_;
        emit ActionsSet(open_, continue_);
    }

    function setIntake(address intake_, address asset_) external onlyOwner nonReentrant {
        if (intake_ == address(0) || asset_ == address(0)) revert InvalidAddress();
        intake = intake_;
        asset = asset_;
        emit IntakeSet(intake_, asset_);
    }

    function setTiming(uint32 cooldown_, uint32 staleAfter_) external onlyOwner nonReentrant {
        _checkTiming(cooldown_, staleAfter_);
        _status.cooldown = cooldown_;
        _status.staleAfter = staleAfter_;
        emit TimingSet(cooldown_, staleAfter_);
    }

    function withdraw(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        if (token == address(0) || to == address(0)) revert InvalidAddress();
        IERC20(token).safeTransfer(to, amount);
        emit Withdrawn(token, to, amount);
    }

    function transferOwnership(address next) external onlyOwner nonReentrant {
        if (next == address(0)) revert InvalidAddress();
        pendingOwner = next;
        emit OwnershipTransferStarted(owner, next);
    }

    function acceptOwnership() external nonReentrant {
        if (pendingOwner == address(0) || msg.sender != pendingOwner) revert NotPendingOwner();
        address previous = owner;
        owner = msg.sender;
        pendingOwner = address(0);
        emit OwnershipTransferred(previous, msg.sender);
    }

    function _order(uint8 kind, bytes32 action, bytes memory body, string memory parent, uint256 maximum)
        private
        returns (bytes32 requestId)
    {
        if (body.length == 0 || body.length > MAX_BODY_BYTES) revert InvalidBody();
        address to = intake;
        IERC20 token = IERC20(asset);
        uint256 amount = IIntake(to).priceOf(action, address(token));
        if (amount == 0) revert ActionNotSold();
        if (amount > maximum) revert PriceTooHigh(amount, maximum);

        _status.state = PENDING;
        _status.pendingKind = kind;
        _status.orderedAt = uint40(block.timestamp);
        _status.staleAt = uint40(block.timestamp + _status.staleAfter);
        _pendingIntake = to;

        uint256 beforeBalance = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        if (token.balanceOf(address(this)) != beforeBalance + amount) revert UnsupportedAsset();
        token.forceApprove(to, amount);
        requestId = IIntake(to)
            .requestWithFailure(
                action,
                body,
                IIntake.Callback(address(this), this.onResult.selector),
                this.onFailure.selector,
                address(token),
                amount
            );
        if (requestId == bytes32(0) || requestId == lastRequestId) revert InvalidRequestId();
        lastRequestId = requestId;
        // A configured replacement must consume the payment too. Never leave a spend allowance.
        if (token.allowance(address(this), to) != 0) token.forceApprove(to, 0);
        if (token.balanceOf(address(this)) != beforeBalance) revert UnsupportedAsset();
        emit Ordered(requestId, kind, msg.sender, amount, parent);
    }

    function _checkCallback(bytes32 requestId) private view {
        if (
            _reentrancyGuardEntered() || msg.sender != _pendingIntake || _status.state != PENDING
                || requestId != lastRequestId
        ) revert NotPending(requestId);
    }

    function _checkRecoverable() private view {
        if (_status.state != IDLE && _status.state != STUCK && !_stale()) revert WrongState();
    }

    function _stale() private view returns (bool) {
        return _status.state == PENDING && block.timestamp >= _status.staleAt;
    }

    function _done() private {
        _status.state = IDLE;
        _status.pendingKind = 0;
        _status.lastDone = uint40(block.timestamp);
    }

    function _checkTiming(uint32 cooldown_, uint32 staleAfter_) private pure {
        if (cooldown_ < MIN_TIMING || cooldown_ > MAX_TIMING || staleAfter_ < MIN_TIMING || staleAfter_ > MAX_TIMING) {
            revert InvalidTiming();
        }
    }
}
