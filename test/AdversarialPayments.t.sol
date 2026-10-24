// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BurnTracker, IIntake} from "src/BurnTracker.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BurnTrackerFixture} from "./BurnTracker.t.sol";

/// @dev Deliberately nonstandard behaviors are confined to this adversarial test double.
contract AdversarialToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => mapping(address => bool)) internal approvedZero;
    uint256 public approvalCalls;
    uint8 public mode;
    bool public stickyAllowance;
    bool public zeroFirst;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function configure(uint8 mode_, bool sticky_, bool zeroFirst_) external {
        mode = mode_;
        stickyAllowance = sticky_;
        zeroFirst = zeroFirst_;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        ++approvalCalls;
        if (zeroFirst && amount != 0 && !approvedZero[msg.sender][spender]) return false;
        if (amount == 0) approvedZero[msg.sender][spender] = true;
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return _response();
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (!stickyAllowance) allowance[from][msg.sender] -= amount;
        else require(allowance[from][msg.sender] >= amount, "allowance");
        _move(from, to, amount);
        return _response();
    }

    function _move(address from, address to, uint256 amount) private {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }

    function _response() private view returns (bool) {
        if (mode == 1) return false; // Reports failure AFTER moving funds.
        if (mode == 2) revert("token reverted after transfer");
        if (mode == 3) {
            assembly ("memory-safe") { return(0, 0) }
        }
        if (mode == 4) {
            assembly ("memory-safe") {
                mstore(0, 1)
                return(31, 1)
            }
        }
        return true;
    }
}

contract ScriptedIntake is IIntake {
    using SafeERC20 for IERC20;
    uint256 public quote = 17;
    uint256 public calls;
    bytes32 public requestId = bytes32("request one");
    uint8 public pullMode;
    bool public revertAfterPull;
    bytes public hook;
    bool public hookSucceeded;
    bytes public hookReturn;
    address public immutable treasury;

    constructor(address treasury_) {
        treasury = treasury_;
    }

    function priceOf(bytes32, address) external view returns (uint256) {
        return quote;
    }

    function configure(bytes32 id, uint8 mode, bool failAfter) external {
        requestId = id;
        pullMode = mode;
        revertAfterPull = failAfter;
    }

    function setHook(bytes calldata data) external {
        hook = data;
    }

    function requestWithFailure(bytes32, bytes calldata, Callback calldata cb, bytes4, address asset, uint256 amount)
        external
        payable
        returns (bytes32)
    {
        require(amount == quote, "price changed");
        ++calls;
        if (pullMode != 1) IERC20(asset).safeTransferFrom(msg.sender, treasury, pullMode == 2 ? amount - 1 : amount);
        require(!revertAfterPull, "intake reverted after payment");
        if (hook.length != 0) (hookSucceeded, hookReturn) = cb.target.call(hook);
        return requestId;
    }
}

/// @dev Both attempts are in ONE transaction, to exercise transient-lock rollback and release.
contract BatchSponsor {
    function approve(IERC20 token, BurnTracker tracker) external {
        token.approve(address(tracker), type(uint256).max);
    }

    function retryAfterRevert(BurnTracker tracker, bytes calldata proof, uint256 quote) external returns (bytes32 id) {
        (bool ok, bytes memory reason) =
            address(tracker).call(abi.encodeCall(tracker.updateBurntracker, (proof, quote - 1)));
        require(!ok && bytes4(reason) == BurnTracker.PriceTooHigh.selector, "expected price failure");
        return tracker.updateBurntracker(proof, quote);
    }

    function attemptTwice(BurnTracker tracker, bytes calldata proof, uint256 quote) external returns (bytes32 id) {
        id = tracker.updateBurntracker(proof, quote);
        (bool ok, bytes memory reason) =
            address(tracker).call(abi.encodeCall(tracker.updateBurntracker, (proof, quote)));
        require(!ok && bytes4(reason) == BurnTracker.WrongState.selector, "second order should be blocked");
    }
}

contract AdversarialPaymentsTest is Test {
    BurnTracker internal tracker;
    AdversarialToken internal token;
    ScriptedIntake internal intake;
    address internal owner = makeAddr("payment owner");
    address internal treasury = makeAddr("payment treasury");
    bytes32 internal constant OPEN = bytes32("job.open@job-1");
    bytes32 internal constant CONTINUE = bytes32("job.continue@job-1");
    bytes internal constant BODY = '{"objective":"build dashboard","skill":"build-website"}';

    function setUp() public {
        vm.warp(1_800_000_000);
        token = new AdversarialToken();
        intake = new ScriptedIntake(treasury);
        tracker = new BurnTracker(owner, address(intake), address(token), OPEN, CONTINUE, 86400, 172800);
        token.mint(owner, 100);
        token.mint(address(tracker), 7); // A donation must survive both successful and reverted orders.
        vm.prank(owner);
        token.approve(address(tracker), 100);
    }

    function testZeroRequestIdRollsBackPaymentAndPendingState() public {
        intake.configure(0, 0, false);
        vm.prank(owner);
        vm.expectRevert(BurnTracker.InvalidRequestId.selector);
        tracker.open(BODY);
        _assertInitialBalances();
        assertEq(tracker.lastRequestId(), bytes32(0));
    }

    function testRepeatedRequestIdCannotSpendAnotherPaymentOrReplaceAwaitedOrder() public {
        vm.prank(owner);
        bytes32 first = tracker.open(BODY);
        vm.warp(block.timestamp + 2 days);
        vm.prank(owner);
        vm.expectRevert(BurnTracker.InvalidRequestId.selector);
        tracker.open(BODY);
        assertEq(token.balanceOf(owner), 83);
        assertEq(token.balanceOf(treasury), 17);
        assertEq(token.balanceOf(address(tracker)), 7);
        assertEq(token.allowance(owner, address(tracker)), 83);
        assertEq(token.allowance(address(tracker), address(intake)), 0);
        assertEq(intake.calls(), 1);
        assertEq(tracker.lastRequestId(), first);
        // Failed replacement leaves the first order answerable, despite its elapsed deadline.
        vm.prank(address(intake));
        tracker.onResult(first, keccak256("first result"), "ipfs://first/result.json");
        (uint8 state,,,,,,) = tracker.status();
        assertEq(state, 2);
    }

    function testIntakeMustConsumeFullPrice() public {
        for (uint8 mode = 1; mode <= 2; ++mode) {
            intake.configure("request one", mode, false);
            vm.prank(owner);
            vm.expectRevert(BurnTracker.UnsupportedAsset.selector);
            tracker.open(BODY);
            _assertInitialBalances();
        }
    }

    function testIntakeRevertAfterTransferRollsBackBothTransfersAndAllowance() public {
        intake.configure("request one", 0, true);
        vm.prank(owner);
        vm.expectRevert("intake reverted after payment");
        tracker.open(BODY);
        _assertInitialBalances();
    }

    function testFalseTokenReturnAfterTransferCannotStrandFunds() public {
        token.configure(1, false, false);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        tracker.open(BODY);
        _assertInitialBalances();
    }

    function testTokenRevertAfterTransferRollsBack() public {
        token.configure(2, false, false);
        vm.prank(owner);
        vm.expectRevert("token reverted after transfer");
        tracker.open(BODY);
        _assertInitialBalances();
    }

    function testMalformedTokenReturnRejectedAtomically() public {
        token.configure(4, false, false);
        vm.prank(owner);
        vm.expectRevert();
        tracker.open(BODY);
        _assertInitialBalances();
    }

    function testNoReturnTokenIsSupportedWithoutLeavingFundsOrApproval() public {
        token.configure(3, false, false);
        vm.prank(owner);
        tracker.open(BODY);
        _assertPaidOnce();
        vm.prank(owner);
        tracker.withdraw(address(token), owner, 7);
        assertEq(token.balanceOf(address(tracker)), 0);
        assertEq(token.balanceOf(owner), 90);
    }

    function testResidualAllowanceIsExplicitlyRevoked() public {
        token.configure(0, true, false);
        uint256 approvals = token.approvalCalls();
        vm.prank(owner);
        tracker.open(BODY);
        _assertPaidOnce();
        assertEq(token.approvalCalls() - approvals, 2, "approve exact amount, then revoke residual");
    }

    function testForceApproveHandlesAZeroFirstToken() public {
        token.configure(0, false, true);
        uint256 approvals = token.approvalCalls();
        vm.prank(owner);
        tracker.open(BODY);
        _assertPaidOnce();
        assertEq(token.approvalCalls() - approvals, 3, "failed approval, reset to zero, exact approval");
    }

    function testFalseReturnWithdrawalPreservesDonations() public {
        token.configure(1, false, false);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        tracker.withdraw(address(token), owner, 7);
        _assertInitialBalances();
    }

    function testSynchronousResultCannotSettleStaleOrderDuringReplacement() public {
        _synchronousCallback(false);
    }

    function testSynchronousFailureCannotSettleStaleOrderDuringReplacement() public {
        _synchronousCallback(true);
    }

    function _synchronousCallback(bool failure) private {
        vm.prank(owner);
        bytes32 oldId = tracker.open(BODY);
        bytes32 oldHash = tracker.resultHash();
        vm.warp(block.timestamp + 2 days);
        intake.configure("request two", 0, false);
        intake.setHook(
            failure
                ? abi.encodeCall(
                    tracker.onFailure, (oldId, uint8(2), bytes32("failed"), uint16(0), uint16(0), bytes(""))
                )
                : abi.encodeCall(tracker.onResult, (oldId, keccak256("synchronous result"), "early"))
        );
        vm.prank(owner);
        bytes32 next = tracker.open(BODY);
        assertFalse(intake.hookSucceeded());
        assertEq(intake.hookReturn(), abi.encodeWithSelector(BurnTracker.NotPending.selector, oldId));
        assertEq(tracker.resultHash(), oldHash);
        (uint8 state, uint8 kind, uint40 done,,,,) = tracker.status();
        assertEq(state, 3);
        assertEq(kind, 1);
        assertEq(done, 0);
        assertEq(tracker.lastRequestId(), next);
        assertEq(token.balanceOf(treasury), 34);
        vm.prank(address(intake));
        tracker.onResult(next, keccak256("actual result"), "ipfs://actual/result.json");
        assertEq(tracker.resultHash(), keccak256("actual result"));
    }

    function _assertInitialBalances() private view {
        assertEq(token.balanceOf(owner), 100);
        assertEq(token.balanceOf(treasury), 0);
        assertEq(token.balanceOf(address(tracker)), 7);
        assertEq(token.allowance(owner, address(tracker)), 100);
        assertEq(token.allowance(address(tracker), address(intake)), 0);
        assertEq(intake.calls(), 0);
        (uint8 state, uint8 kind,, uint40 ordered, uint40 stale,,) = tracker.status();
        assertEq(state, 1);
        assertEq(kind, 0);
        assertEq(ordered, 0);
        assertEq(stale, 0);
    }

    function _assertPaidOnce() private view {
        assertEq(token.balanceOf(owner), 83);
        assertEq(token.balanceOf(treasury), 17);
        assertEq(token.balanceOf(address(tracker)), 7);
        assertEq(token.allowance(address(tracker), address(intake)), 0);
        assertEq(intake.calls(), 1);
    }
}

contract SponsorTransactionTest is BurnTrackerFixture {
    function testRevertedAttemptCanRetryInTheSameTransaction() public {
        _ready();
        BatchSponsor sponsor = _sponsor();
        bytes32 id = sponsor.retryAfterRevert(tracker, PROOF, PRICE);
        assertEq(tracker.lastRequestId(), id);
        assertEq(intake.nonce(), 2);
        assertEq(token.balanceOf(address(sponsor)), 0);
        assertEq(token.balanceOf(treasury), 2 * PRICE);
    }

    function testTwoAttemptsInOneTransactionPayOnlyForFirstOrder() public {
        _ready();
        BatchSponsor sponsor = _sponsor();
        bytes32 id = sponsor.attemptTwice(tracker, PROOF, PRICE);
        assertEq(tracker.lastRequestId(), id);
        assertEq(intake.nonce(), 2);
        assertEq(token.balanceOf(address(sponsor)), 0);
        assertEq(token.balanceOf(treasury), 2 * PRICE);
    }

    function testAnotherSponsorCannotSpendOrSupersedeWinningUpdate() public {
        _ready();
        bytes32 id = _update();
        vm.prank(owner);
        vm.expectRevert(BurnTracker.WrongState.selector);
        tracker.updateBurntracker(PROOF, type(uint256).max);
        assertEq(token.balanceOf(owner), 100 ether - PRICE);
        assertEq(token.balanceOf(caller), 100 ether - PRICE);
        assertEq(intake.nonce(), 2);
        assertEq(tracker.lastRequestId(), id);
    }

    function testDonationsCannotSubsidizeCallerWithInsufficientBalanceOrApproval() public {
        _ready();
        token.mint(address(tracker), 100 ether);
        address emptySponsor = makeAddr("unfunded sponsor");
        vm.startPrank(emptySponsor);
        token.approve(address(tracker), PRICE);
        vm.expectRevert();
        tracker.updateBurntracker(PROOF, PRICE);
        vm.stopPrank();
        vm.prank(caller);
        token.approve(address(tracker), PRICE - 1);
        vm.prank(caller);
        vm.expectRevert();
        tracker.updateBurntracker(PROOF, PRICE);
        assertEq(token.balanceOf(address(tracker)), 100 ether);
        assertEq(token.balanceOf(treasury), PRICE);
        assertEq(token.allowance(address(tracker), address(intake)), 0);
        assertEq(intake.nonce(), 1);
        assertEq(_state(), 2);
    }

    function _sponsor() private returns (BatchSponsor sponsor) {
        sponsor = new BatchSponsor();
        token.mint(address(sponsor), PRICE);
        sponsor.approve(IERC20(address(token)), tracker);
    }
}
