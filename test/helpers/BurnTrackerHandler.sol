// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BurnTracker} from "src/BurnTracker.sol";
import {MockToken, MockIntake} from "./MockIntake.sol";
import {ResultDocuments} from "./ResultDocuments.sol";

/// @notice A specification model and payment ledger driven by independent random operations.
/// @dev Expected transitions come from the assignment's four-state table. No storage is patched.
/// Reverts are checked explicitly; fail_on_revert makes unexpected handler failures fatal.
contract BurnTrackerHandler is Test {
    uint256 public constant INITIAL_FUNDS = 1_000_000 ether;
    bytes32 internal constant OPEN = bytes32("job.open@job-1");
    bytes32 internal constant CONTINUE = bytes32("job.continue@job-1");
    bytes internal constant OPEN_BODY = '{"host":true,"objective":"IMD burn tracker","skill":"build-website"}';
    string internal constant RECOVERY_PARENT = "12345678-1234-4abc-8def-123456789abc";

    BurnTracker public tracker;
    MockToken[2] public tokens;
    MockIntake[2] public intakes;
    address[4] public actors;
    address public treasury;
    address public writer;

    // Independent token ledger: donations are never available to pay a caller's order.
    uint256[2] public paid;
    uint256[2] public donated;
    uint256[2] public withdrawn;
    mapping(uint256 => mapping(address => uint256)) public actorPaid;
    mapping(uint256 => mapping(address => uint256)) public actorDonated;
    mapping(uint256 => mapping(address => uint256)) public actorWithdrawn;
    uint256 public orders;
    uint256 public successfulCallbacks;
    uint256 public rejectedCalls;
    uint256 public superseded;

    uint8 public expectedState = 1;
    uint8 public expectedKind;
    uint256 public expectedDone;
    uint256 public expectedOrdered;
    uint256 public expectedStale;
    uint32 public expectedCooldown = 1 days;
    uint32 public expectedStaleAfter = 2 days;
    address public expectedOwner;
    address public expectedPendingOwner;
    uint256 public intakeIndex;
    uint256 public tokenIndex;
    bytes32 public expectedOpen = OPEN;
    bytes32 public expectedContinue = CONTINUE;
    bytes public expectedPrefix;
    bytes public expectedSuffix;
    bytes32 public expectedHash;
    bytes32 public currentRequest;
    uint256 public awaitedIntake;
    bytes public currentProof;

    struct Order {
        bytes32 id;
        uint256 intakeNumber;
    }
    Order[] public history;

    constructor() {
        treasury = makeAddr("invariant treasury");
        writer = makeAddr("invariant writer");
        for (uint256 i; i < 4; ++i) {
            actors[i] = makeAddr(string.concat("actor ", vm.toString(i)));
        }
        expectedOwner = actors[0];
        for (uint256 i; i < 2; ++i) {
            tokens[i] = new MockToken();
            intakes[i] = new MockIntake(treasury, writer);
            intakes[i].setPrice(OPEN, 0.5 ether);
            intakes[i].setPrice(CONTINUE, 0.5 ether);
            intakes[i].setPrice("job.open@job-2", 1 ether);
            intakes[i].setPrice("job.continue@job-2", 1 ether);
        }
        tracker =
            new BurnTracker(expectedOwner, address(intakes[0]), address(tokens[0]), OPEN, CONTINUE, 1 days, 2 days);
        expectedPrefix = tracker.bodyPrefix();
        expectedSuffix = tracker.bodySuffix();
        expectedHash = tracker.resultHash();
        currentProof = ResultDocuments.proof(bytes16(uint128(1)));
        for (uint256 t; t < 2; ++t) {
            for (uint256 a; a < 4; ++a) {
                tokens[t].mint(actors[a], INITIAL_FUNDS);
                vm.prank(actors[a]);
                tokens[t].approve(address(tracker), type(uint256).max);
            }
        }
    }

    function elapse(uint256 seconds_, uint8 boundary) external {
        uint256 target = block.timestamp + bound(seconds_, 0, 3 days);
        if (boundary % 5 == 1) target = expectedDone + expectedCooldown;
        if (boundary % 5 == 2 && expectedStale != 0) target = expectedStale - 1;
        if (boundary % 5 == 3) target = expectedStale;
        if (boundary % 5 == 4) target = expectedStale + 1;
        if (target > block.timestamp) vm.warp(target);
    }

    /// @dev kind = 0/open, 1/update, 2/recover. Some calls intentionally have the wrong owner or price ceiling.
    function order(uint8 kindSeed, uint8 actorSeed, uint8 ceiling) external {
        uint8 kind = kindSeed % 3 + 1;
        address payer = actors[actorSeed % 4];
        if (kind != 2 && actorSeed % 4 != 3) payer = expectedOwner;
        bytes32 action = kind == 1 ? expectedOpen : expectedContinue;
        uint256 quote = intakes[intakeIndex].prices(action);
        uint256 maximum = ceiling % 3 == 0 && quote != 0 ? quote - 1 : quote;
        if (ceiling % 3 == 2) maximum = type(uint256).max;
        bool stale = expectedState == 3 && block.timestamp >= expectedStale;
        bool eligible;
        bytes memory data;
        bytes memory body;
        if (kind == 1) {
            eligible = payer == expectedOwner && (expectedState == 1 || expectedState == 4 || stale);
            data = abi.encodeCall(tracker.open, (OPEN_BODY));
            body = OPEN_BODY;
        } else if (kind == 2) {
            eligible = expectedState == 2 && block.timestamp >= expectedDone + expectedCooldown && quote <= maximum;
            data = abi.encodeCall(tracker.updateBurntracker, (currentProof, maximum));
            // currentProof is generated by the harness, so the expected parent is decoded independently.
            body =
                bytes.concat(expectedPrefix, bytes(vm.parseJsonString(string(currentProof), ".jobId")), expectedSuffix);
        } else {
            eligible = payer == expectedOwner && (expectedState == 2 || expectedState == 4 || stale);
            data = abi.encodeCall(tracker.recover, (RECOVERY_PARENT));
            body = bytes.concat(expectedPrefix, bytes(RECOVERY_PARENT), expectedSuffix);
        }
        eligible = eligible && quote != 0;
        vm.prank(payer);
        (bool ok, bytes memory returned) = address(tracker).call(data);
        assertEq(ok, eligible, "order eligibility differs from the specification");
        if (!ok) {
            ++rejectedCalls;
            return;
        }
        if (expectedState == 3) ++superseded;
        expectedState = 3;
        expectedKind = kind;
        expectedOrdered = block.timestamp;
        expectedStale = block.timestamp + expectedStaleAfter;
        currentRequest = abi.decode(returned, (bytes32));
        awaitedIntake = intakeIndex;
        history.push(Order(currentRequest, intakeIndex));
        ++orders;
        paid[tokenIndex] += quote;
        actorPaid[tokenIndex][payer] += quote;
        MockIntake source = intakes[intakeIndex];
        (address recordedPayer, address target, bytes4 selector, bytes4 failure,) = source.requests(currentRequest);
        assertEq(recordedPayer, address(tracker), "plane payer changed");
        assertEq(target, address(tracker));
        assertEq(selector, tracker.onResult.selector);
        assertEq(failure, tracker.onFailure.selector);
        assertEq(source.amountAtRequest(), quote);
        assertEq(source.allowanceAtRequest(), quote);
        assertEq(source.actionAtRequest(), action);
        assertEq(source.bodyHash(), keccak256(body), "caller changed the continuation template");
    }

    /// @dev The mock provides the real one-shot, 200,000-gas callback envelope.
    function settle(uint8 outcomeSeed, bytes16 entropy) external {
        if (expectedState != 3) {
            _reject(
                address(intakes[awaitedIntake]),
                abi.encodeCall(tracker.onResult, (currentRequest, keccak256("replay"), "replay"))
            );
            return;
        }
        uint8 outcome = outcomeSeed % 3;
        bytes memory proof = ResultDocuments.proof(entropy);
        vm.prank(writer);
        bool delivered = outcome == 0
            ? intakes[awaitedIntake].complete(currentRequest, keccak256(proof), "ipfs://invariant/result.json")
            : intakes[awaitedIntake].fail(currentRequest, outcome, bytes32("body_refused"));
        assertTrue(delivered, "awaited callback failed its 200k stipend");
        ++successfulCallbacks;
        if (outcome == 0) {
            expectedHash = keccak256(proof);
            currentProof = proof;
            expectedState = 2;
            expectedDone = block.timestamp;
        } else if (outcome == 1 && expectedKind == 1) {
            expectedState = 1;
        } else if (outcome == 1 && expectedKind == 2) {
            expectedState = 2;
            expectedDone = block.timestamp;
        } else {
            expectedState = 4;
        }
        expectedKind = 0;
    }

    function adopt(bytes16 entropy, uint8 actorSeed) external {
        address caller = actorSeed % 4 == 3 ? actors[3] : expectedOwner;
        bytes memory proof = ResultDocuments.proof(entropy);
        bool allowed = caller == expectedOwner
            && (expectedState == 2 || expectedState == 4 || (expectedState == 3 && block.timestamp >= expectedStale));
        vm.prank(caller);
        (bool ok,) = address(tracker).call(abi.encodeCall(tracker.setResultHash, (keccak256(proof))));
        assertEq(ok, allowed, "completion adoption eligibility");
        if (!ok) {
            ++rejectedCalls;
            return;
        }
        if (expectedState == 3) ++superseded;
        expectedHash = keccak256(proof);
        currentProof = proof;
        expectedState = 2;
        expectedKind = 0;
        expectedDone = block.timestamp;
    }

    function rejectBadProof(uint8 actorSeed, uint256 maximum) external {
        // Appending a byte always changes the authenticated bytes, even if the JSON meaning is unchanged.
        _reject(
            actors[actorSeed % 4], abi.encodeCall(tracker.updateBurntracker, (bytes.concat(currentProof, " "), maximum))
        );
    }

    function rejectCallback(uint8 modeSeed, uint256 historySeed, bytes32 hash) external {
        uint8 mode = modeSeed % 5;
        address source = address(intakes[awaitedIntake]);
        bytes32 id = currentRequest;
        bytes memory data;
        if (mode == 0) source = actors[0];
        if (mode == 1) id = bytes32(uint256(currentRequest) ^ 1);
        if (mode == 2) {
            data =
                abi.encodeCall(tracker.onFailure, (id, uint8(3), hash, uint16(4), uint16(2), bytes("invalid status")));
        } else if (mode == 3) {
            data = abi.encodeCall(tracker.onResult, (id, bytes32(0), "zero hash"));
        } else if (mode == 4 && history.length > 1) {
            Order memory old = history[historySeed % (history.length - 1)];
            source = address(intakes[old.intakeNumber]);
            data = abi.encodeCall(tracker.onFailure, (old.id, uint8(2), hash, uint16(0), uint16(0), bytes("late")));
        } else {
            if (mode == 4) source = actors[0];
            data = abi.encodeCall(tracker.onResult, (id, hash, "spoofed"));
        }
        _reject(source, data);
    }

    function configure(uint8 modeSeed, uint256 x, uint256 y) external {
        uint8 mode = modeSeed % 4;
        if (mode == 0) {
            expectedCooldown = uint32(bound(x, 1 hours, 30 days));
            expectedStaleAfter = uint32(bound(y, 1 hours, 30 days));
            vm.prank(expectedOwner);
            tracker.setTiming(expectedCooldown, expectedStaleAfter);
            // expectedStale deliberately remains the deadline captured when the order was placed.
        } else if (mode == 1) {
            intakeIndex = x % 2;
            tokenIndex = y % 2;
            vm.prank(expectedOwner);
            tracker.setIntake(address(intakes[intakeIndex]), address(tokens[tokenIndex]));
        } else if (mode == 2) {
            expectedOpen = x % 2 == 0 ? OPEN : bytes32("job.open@job-2");
            expectedContinue = y % 2 == 0 ? CONTINUE : bytes32("job.continue@job-2");
            vm.prank(expectedOwner);
            tracker.setActions(expectedOpen, expectedContinue);
        } else {
            expectedPrefix = bytes(string.concat('{"objective":"refresh ', vm.toString(x), '","parentJobId":"'));
            expectedSuffix = '","skill":"import-site","host":true}';
            vm.prank(expectedOwner);
            tracker.setBody(expectedPrefix, expectedSuffix);
        }
    }

    function changePrices(uint256 source, uint256 openPrice, uint256 continuePrice) external {
        intakes[source % 2].setPrice(expectedOpen, bound(openPrice, 0, 10 ether));
        intakes[source % 2].setPrice(expectedContinue, bound(continuePrice, 0, 10 ether));
    }

    function proposeOwner(uint8 actorSeed) external {
        expectedPendingOwner = actors[actorSeed % 4];
        vm.prank(expectedOwner);
        tracker.transferOwnership(expectedPendingOwner);
    }

    function acceptOwner(uint8 actorSeed) external {
        address candidate = actors[actorSeed % 4];
        vm.prank(candidate);
        (bool ok,) = address(tracker).call(abi.encodeCall(tracker.acceptOwnership, ()));
        assertEq(ok, candidate == expectedPendingOwner, "ownership accepted without current proposal");
        if (ok) {
            expectedOwner = candidate;
            expectedPendingOwner = address(0);
        } else {
            ++rejectedCalls;
        }
    }

    function rejectAdministration(uint8 modeSeed, uint8 actorSeed) external {
        address attacker = actors[actorSeed % 4];
        if (attacker == expectedOwner) attacker = actors[(actorSeed % 4 + 1) % 4];
        bytes memory data;
        uint8 mode = modeSeed % 8;
        if (mode == 0) data = abi.encodeCall(tracker.open, (OPEN_BODY));
        if (mode == 1) data = abi.encodeCall(tracker.recover, (RECOVERY_PARENT));
        if (mode == 2) data = abi.encodeCall(tracker.setResultHash, (keccak256("unauthorized")));
        if (mode == 3) data = abi.encodeCall(tracker.setTiming, (uint32(1 hours), uint32(1 hours)));
        if (mode == 4) data = abi.encodeCall(tracker.setIntake, (attacker, attacker));
        if (mode == 5) data = abi.encodeCall(tracker.setActions, (bytes32("evil"), bytes32("evil")));
        if (mode == 6) data = abi.encodeCall(tracker.setBody, (bytes("evil"), bytes("evil")));
        if (mode == 7) data = abi.encodeCall(tracker.transferOwnership, (attacker));
        _reject(attacker, data);
    }

    function donate(uint8 assetSeed, uint8 actorSeed, uint256 amount) external {
        uint256 t = assetSeed % 2;
        address donor = actors[actorSeed % 4];
        amount = bound(amount, 0, 10 ether);
        vm.prank(donor);
        assertTrue(tokens[t].transfer(address(tracker), amount));
        donated[t] += amount;
        actorDonated[t][donor] += amount;
    }

    function withdraw(uint8 assetSeed, uint8 recipientSeed, uint256 amount, uint8 modeSeed) external {
        uint256 t = assetSeed % 2;
        address recipient = actors[recipientSeed % 4];
        address caller = expectedOwner;
        uint256 held = donated[t] - withdrawn[t];
        amount = bound(amount, 0, held);
        uint8 mode = modeSeed % 4;
        if (mode == 1) amount = held; // Full withdrawal, including zero/dust.
        if (mode == 2) amount = held + 1;
        if (mode == 3) {
            caller = actors[0] == expectedOwner ? actors[1] : actors[0];
        }
        vm.prank(caller);
        (bool ok,) = address(tracker).call(abi.encodeCall(tracker.withdraw, (address(tokens[t]), recipient, amount)));
        assertEq(ok, mode < 2, "withdrawal authorization or balance check");
        if (ok) {
            withdrawn[t] += amount;
            actorWithdrawn[t][recipient] += amount;
        } else {
            ++rejectedCalls;
        }
    }

    function _reject(address caller, bytes memory data) private {
        vm.prank(caller);
        (bool ok,) = address(tracker).call(data);
        assertFalse(ok, "invalid call unexpectedly succeeded");
        ++rejectedCalls;
    }
}
