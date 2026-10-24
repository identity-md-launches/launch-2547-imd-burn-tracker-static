// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {BurnTracker, IIntake} from "../src/BurnTracker.sol";
import {MockToken, MockIntake} from "./helpers/MockIntake.sol";

abstract contract BurnTrackerFixture is Test {
    BurnTracker internal tracker;
    MockToken internal token;
    MockIntake internal intake;
    address internal owner = makeAddr("owner");
    address internal caller = makeAddr("refresh sponsor");
    address internal treasury = makeAddr("Intake treasury");
    address internal writer = makeAddr("Intake writer");
    bytes32 internal constant OPEN = bytes32("job.open@job-1");
    bytes32 internal constant CONTINUE = bytes32("job.continue@job-1");
    uint256 internal constant PRICE = 0.5 ether;
    bytes internal constant OPEN_BODY =
        '{"objective":"Build the IMD burn tracker","skill":"build-website","host":true}';
    string internal constant PARENT = "c9822c12-52e3-4d28-b474-a9ab751b10b3";
    bytes internal constant PROOF = '{"jobId":"c9822c12-52e3-4d28-b474-a9ab751b10b3","state":"completed"}';
    event Ordered(bytes32 indexed requestId, uint8 kind, address indexed payer, uint256 amount, string parentJobId);
    event Updated(bytes32 indexed requestId, bytes32 resultHash, string uri);
    event Failed(bytes32 indexed requestId, uint8 status, bytes32 reason, uint8 newState);

    function setUp() public {
        vm.warp(1_800_000_000);
        token = new MockToken();
        intake = new MockIntake(treasury, writer);
        intake.setPrice(OPEN, PRICE);
        intake.setPrice(CONTINUE, PRICE);
        tracker = new BurnTracker(owner, address(intake), address(token), OPEN, CONTINUE, 1 days, 2 days);
        token.mint(owner, 100 ether);
        token.mint(caller, 100 ether);
        vm.prank(owner);
        token.approve(address(tracker), type(uint256).max);
        vm.prank(caller);
        token.approve(address(tracker), type(uint256).max);
    }

    function _open() internal returns (bytes32 id) {
        vm.prank(owner);
        return tracker.open(OPEN_BODY);
    }

    function _complete(bytes32 id, bytes32 hash) internal {
        vm.prank(writer);
        assertTrue(intake.complete(id, hash, "ipfs://fixture/result.json"));
    }

    function _fail(bytes32 id, uint8 status_) internal {
        vm.prank(writer);
        assertTrue(intake.fail(id, status_, bytes32("failed")));
    }

    function _ready() internal {
        _complete(_open(), keccak256(PROOF));
        vm.warp(tracker.nextUpdateAt());
    }

    function _update() internal returns (bytes32) {
        vm.prank(caller);
        return tracker.updateBurntracker(PROOF, PRICE);
    }

    function _state() internal view returns (uint8 s) {
        (s,,,,,,) = tracker.status();
    }

    function _assertPending(uint8 kind) internal view {
        (uint8 s, uint8 k,, uint40 at, uint40 stale,,) = tracker.status();
        assertEq(s, 3);
        assertEq(k, kind);
        assertEq(at, block.timestamp);
        assertEq(stale, block.timestamp + 2 days);
    }
}

contract BurnTrackerTest is BurnTrackerFixture {
    function testConstructorStaticWordsAndExactTemplate() public view {
        assertEq(tracker.owner(), owner);
        assertEq(tracker.intake(), address(intake));
        assertEq(tracker.asset(), address(token));
        assertEq(tracker.openAction(), OPEN);
        assertEq(tracker.continueAction(), CONTINUE);
        assertEq(_state(), 1);
        assertEq(
            abi.encode(owner, address(intake), address(token), OPEN, CONTINUE, uint32(1 days), uint32(2 days)).length,
            7 * 32
        );
        bytes memory expected = vm.readFileBinary("test/fixtures/continuation-template.json");
        assertEq(bytes.concat(tracker.bodyPrefix(), bytes("{{PARENT}}"), tracker.bodySuffix()), expected);
        assertEq(tracker.nextUpdateAt(), 0);
    }

    function testConstructorWorksOnEmptyChainWithGivenMainnetAddresses() public {
        address mainIntake = 0xa43e6F75ee006411F79Ac1C84120606C2330DE82;
        address mainAsset = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
        assertEq(mainIntake.code.length, 0);
        assertEq(mainAsset.code.length, 0);
        BurnTracker deployed = new BurnTracker(owner, mainIntake, mainAsset, OPEN, CONTINUE, 86400, 172800);
        assertEq(deployed.owner(), owner);
        assertLt(address(deployed).code.length, 24_576);
    }

    function testOpenPaysLivePriceAndContractIsPayer() public {
        intake.setPrice(OPEN, PRICE + 10);
        bytes32 id = _open();
        (address payer, address target, bytes4 selector, bytes4 failure,) = intake.requests(id);
        assertEq(payer, address(tracker));
        assertEq(target, address(tracker));
        assertEq(selector, tracker.onResult.selector);
        assertEq(failure, tracker.onFailure.selector);
        assertEq(token.balanceOf(owner), 100 ether - PRICE - 10);
        assertEq(token.balanceOf(treasury), PRICE + 10);
        assertEq(token.balanceOf(address(tracker)), 0);
        assertEq(token.allowance(address(tracker), address(intake)), 0);
        assertEq(intake.allowanceAtRequest(), PRICE + 10);
        assertEq(intake.bodyHash(), keccak256(OPEN_BODY));
        assertEq(tracker.lastRequestId(), id);
        _assertPending(1);
    }

    function testOpenOnlyOwnerAndOneOrderAtATime() public {
        vm.expectRevert(BurnTracker.NotOwner.selector);
        tracker.open(OPEN_BODY);
        _open();
        vm.startPrank(owner);
        vm.expectRevert(BurnTracker.WrongState.selector);
        tracker.open(OPEN_BODY);
        vm.expectRevert(BurnTracker.WrongState.selector);
        tracker.recover(PARENT);
        vm.expectRevert(BurnTracker.WrongState.selector);
        tracker.setResultHash(keccak256(PROOF));
        vm.stopPrank();
        vm.expectRevert(BurnTracker.WrongState.selector);
        tracker.updateBurntracker(PROOF, PRICE);
    }

    function testOpenCannotReplaceCompletedSite() public {
        _ready();
        vm.prank(owner);
        vm.expectRevert(BurnTracker.WrongState.selector);
        tracker.open(OPEN_BODY);
    }

    function testUpdateRequiresCompletionAndCooldownAtBoundary() public {
        vm.expectRevert(BurnTracker.WrongState.selector);
        tracker.updateBurntracker(PROOF, PRICE);
        _complete(_open(), keccak256(PROOF));
        uint256 until = tracker.nextUpdateAt();
        vm.warp(until - 1);
        vm.expectRevert(abi.encodeWithSelector(BurnTracker.CooldownActive.selector, until));
        tracker.updateBurntracker(PROOF, PRICE);
        vm.warp(until);
        _update();
        _assertPending(2);
    }

    function testUpdateProofPriceExactBodyAndEvents() public {
        _ready();
        intake.setPrice(CONTINUE, PRICE + 123);
        bytes memory expected = bytes.concat(tracker.bodyPrefix(), bytes(PARENT), tracker.bodySuffix());
        bytes32 expectedId = keccak256(abi.encode(address(intake), intake.nonce() + 1));
        vm.expectEmit(true, true, false, true, address(tracker));
        emit Ordered(expectedId, 2, caller, PRICE + 123, PARENT);
        vm.prank(caller);
        bytes32 id = tracker.updateBurntracker(PROOF, PRICE + 123);
        assertEq(id, expectedId);
        assertEq(intake.bodyHash(), keccak256(expected));
        assertEq(intake.actionAtRequest(), CONTINUE);
        assertEq(intake.amountAtRequest(), PRICE + 123);
        assertEq(intake.allowanceAtRequest(), PRICE + 123);
        assertEq(tracker.price(), PRICE + 123);
        assertEq(token.balanceOf(caller), 100 ether - PRICE - 123);
        assertEq(token.balanceOf(owner), 100 ether - PRICE);
        assertEq(token.balanceOf(address(tracker)), 0);
        assertEq(token.allowance(address(tracker), address(intake)), 0);
    }

    function testPriceAboveMaximumRevertsBeforeAnyTokenCall() public {
        _ready();
        intake.setPrice(CONTINUE, PRICE + 1);
        // If reached, the token would fail instead. Record external calls as stronger evidence
        // than unchanged balances (which would also roll back after a late revert).
        token.setFailure(true);
        vm.startStateDiffRecording();
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(BurnTracker.PriceTooHigh.selector, PRICE + 1, PRICE));
        tracker.updateBurntracker(PROOF, PRICE);
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
        for (uint256 i; i < accesses.length; ++i) {
            assertTrue(accesses[i].account != address(token), "token was touched");
        }
        assertEq(_state(), 2);
    }

    function testWrongProofCannotSpendTokensOrChooseParent() public {
        _ready();
        bytes memory changed = bytes('{"jobId":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","state":"completed"}');
        vm.prank(caller);
        vm.expectRevert(BurnTracker.InvalidHash.selector);
        tracker.updateBurntracker(changed, PRICE);
        assertEq(token.balanceOf(caller), 100 ether);
        assertEq(_state(), 2);
    }

    function testAuthenticatedMalformedProofStillRejected() public {
        bytes memory malformed = '{"jobId":"not-a-uuid"}';
        _complete(_open(), keccak256(malformed));
        vm.warp(tracker.nextUpdateAt());
        vm.expectRevert(BurnTracker.InvalidParentJobId.selector);
        tracker.updateBurntracker(malformed, PRICE);
    }

    function testCompletionReplacesHashAndRestartsCooldown() public {
        _ready();
        bytes32 id = _update();
        vm.warp(block.timestamp + 45);
        bytes32 hash = keccak256("next result");
        vm.expectEmit(true, false, false, true, address(tracker));
        emit Updated(id, hash, "ipfs://fixture/result.json");
        _complete(id, hash);
        assertEq(tracker.resultHash(), hash);
        assertEq(_state(), 2);
        assertEq(tracker.nextUpdateAt(), block.timestamp + 1 days);
        (, uint8 kind, uint40 done,,,,) = tracker.status();
        assertEq(kind, 0);
        assertEq(done, block.timestamp);
        vm.warp(tracker.nextUpdateAt());
        vm.expectRevert(BurnTracker.InvalidHash.selector);
        tracker.updateBurntracker(PROOF, PRICE);
    }

    function testRefusedUpdatePreservesProofAndRestartsCooldown() public {
        _ready();
        bytes32 id = _update();
        vm.warp(block.timestamp + 300);
        vm.expectEmit(true, false, false, true, address(tracker));
        emit Failed(id, 1, bytes32("failed"), 2);
        _fail(id, 1);
        assertEq(_state(), 2);
        assertEq(tracker.resultHash(), keccak256(PROOF));
        assertEq(tracker.nextUpdateAt(), block.timestamp + 1 days);
        assertEq(token.balanceOf(caller), 100 ether - PRICE);
        vm.warp(tracker.nextUpdateAt());
        _update();
    }

    function testRefusedOpenReturnsToUnopenedAndCanRetry() public {
        _fail(_open(), 1);
        assertEq(_state(), 1);
        assertEq(tracker.nextUpdateAt(), 0);
        _open();
    }

    function testRefusedRecoveryGoesStuck() public {
        _ready();
        vm.prank(owner);
        bytes32 id = tracker.recover(PARENT);
        _assertPending(3);
        _fail(id, 1);
        assertEq(_state(), 4);
        assertEq(token.balanceOf(owner), 100 ether - 2 * PRICE);
    }

    function test_FailedOpenCanOpenAgain() public {
        _fail(_open(), 2);
        assertEq(_state(), 4);
        _open();
    }

    function test_FailedUpdateCanOpenAgain() public {
        _ready();
        _fail(_update(), 2);
        assertEq(_state(), 4);
        _open();
    }

    function test_FailedRecoveryCanRecoverAgain() public {
        _ready();
        vm.prank(owner);
        bytes32 id = tracker.recover(PARENT);
        _fail(id, 2);
        assertEq(_state(), 4);
        vm.prank(owner);
        tracker.recover(PARENT);
    }

    function testRecoveryOnlyAfterFixedStaleDeadlineAndRejectsLateCallback() public {
        bytes32 oldId = _open();
        (,,,, uint40 stale,,) = tracker.status();
        vm.prank(owner);
        tracker.setTiming(1 hours, 1 hours);
        vm.warp(stale - 1);
        vm.prank(owner);
        vm.expectRevert(BurnTracker.WrongState.selector);
        tracker.recover(PARENT);
        vm.warp(stale);
        vm.prank(owner);
        bytes32 id = tracker.recover(PARENT);
        assertTrue(id != oldId);
        (,,,, uint40 nextStale,,) = tracker.status();
        assertEq(nextStale, stale + 1 hours);
        vm.prank(address(intake));
        vm.expectRevert(abi.encodeWithSelector(BurnTracker.NotPending.selector, oldId));
        tracker.onResult(oldId, keccak256(PROOF), "late");
        vm.prank(address(intake));
        vm.expectRevert(abi.encodeWithSelector(BurnTracker.NotPending.selector, oldId));
        tracker.onFailure(oldId, 2, "failed", 0, 0, "");
        _complete(id, keccak256(PROOF));
    }

    function testStaleOpenCanOpenAgain() public {
        bytes32 id = _open();
        vm.warp(block.timestamp + 2 days);
        _open();
        vm.prank(address(intake));
        vm.expectRevert(abi.encodeWithSelector(BurnTracker.NotPending.selector, id));
        tracker.onResult(id, keccak256(PROOF), "late");
    }

    function testSetResultHashInIdleStuckAndStalePending() public {
        vm.prank(owner);
        vm.expectRevert(BurnTracker.WrongState.selector);
        tracker.setResultHash(keccak256(PROOF));
        bytes32 id = _open();
        vm.warp(block.timestamp + 2 days);
        vm.prank(owner);
        tracker.setResultHash(keccak256(PROOF));
        assertEq(_state(), 2);
        assertEq(tracker.nextUpdateAt(), block.timestamp + 1 days);
        vm.prank(address(intake));
        vm.expectRevert(abi.encodeWithSelector(BurnTracker.NotPending.selector, id));
        tracker.onResult(id, keccak256("old"), "late");
        vm.prank(owner);
        tracker.setResultHash(keccak256("adopt again"));
        assertEq(tracker.resultHash(), keccak256("adopt again"));
        vm.prank(owner);
        tracker.setResultHash(keccak256(PROOF));
        vm.warp(tracker.nextUpdateAt());
        _fail(_update(), 2);
        vm.prank(owner);
        tracker.setResultHash(keccak256(PROOF));
        assertEq(_state(), 2);
    }

    function testRecoverFromIdleBypassesCooldownAndUsesTemplate() public {
        _complete(_open(), keccak256(PROOF));
        vm.prank(owner);
        tracker.recover(PARENT);
        assertEq(intake.bodyHash(), keccak256(bytes.concat(tracker.bodyPrefix(), bytes(PARENT), tracker.bodySuffix())));
        assertEq(intake.actionAtRequest(), CONTINUE);
    }

    function testInvalidRecoveryIdsAndUnopenedRecovery() public {
        vm.prank(owner);
        vm.expectRevert(BurnTracker.WrongState.selector);
        tracker.recover(PARENT);
        _ready();
        vm.prank(owner);
        vm.expectRevert(BurnTracker.InvalidParentJobId.selector);
        tracker.recover("x\",\"objective\":\"evil");
    }

    function testCallbackAuthenticationAndOnceOnly() public {
        bytes32 id = _open();
        vm.expectRevert(abi.encodeWithSelector(BurnTracker.NotPending.selector, id));
        tracker.onResult(id, keccak256(PROOF), "");
        vm.expectRevert(abi.encodeWithSelector(BurnTracker.NotPending.selector, id));
        tracker.onFailure(id, 2, "failed", 0, 0, "");
        vm.prank(address(intake));
        vm.expectRevert(abi.encodeWithSelector(BurnTracker.NotPending.selector, bytes32("unknown")));
        tracker.onResult("unknown", keccak256(PROOF), "");
        _complete(id, keccak256(PROOF));
        vm.prank(address(intake));
        vm.expectRevert(abi.encodeWithSelector(BurnTracker.NotPending.selector, id));
        tracker.onResult(id, keccak256(PROOF), "");
        vm.prank(address(intake));
        vm.expectRevert(abi.encodeWithSelector(BurnTracker.NotPending.selector, id));
        tracker.onFailure(id, 1, "refused", 0, 0, "");
    }

    function test_FailureCannotBeAnsweredTwiceOrWithResult() public {
        bytes32 id = _open();
        _fail(id, 1);
        vm.prank(address(intake));
        vm.expectRevert(abi.encodeWithSelector(BurnTracker.NotPending.selector, id));
        tracker.onFailure(id, 2, "failed", 0, 0, "");
        vm.prank(address(intake));
        vm.expectRevert(abi.encodeWithSelector(BurnTracker.NotPending.selector, id));
        tracker.onResult(id, keccak256(PROOF), "");
    }

    function testZeroHashAndUnknownFailureStatusPreservePending() public {
        bytes32 id = _open();
        vm.prank(address(intake));
        vm.expectRevert(BurnTracker.InvalidHash.selector);
        tracker.onResult(id, 0, "");
        vm.prank(address(intake));
        vm.expectRevert(BurnTracker.InvalidFailureStatus.selector);
        tracker.onFailure(id, 3, "bad", 0, 0, "");
        assertEq(_state(), 3);
        _complete(id, keccak256(PROOF));
        vm.prank(owner);
        vm.expectRevert(BurnTracker.InvalidHash.selector);
        tracker.setResultHash(0);
    }

    function testChangingIntakeDoesNotChangePendingCallbackAuthority() public {
        bytes32 id = _open();
        MockIntake next = new MockIntake(treasury, writer);
        next.setPrice(CONTINUE, PRICE);
        vm.prank(owner);
        tracker.setIntake(address(next), address(token));
        vm.prank(address(next));
        vm.expectRevert(abi.encodeWithSelector(BurnTracker.NotPending.selector, id));
        tracker.onResult(id, keccak256(PROOF), "");
        _complete(id, keccak256(PROOF));
        vm.warp(tracker.nextUpdateAt());
        _update();
        assertEq(next.nonce(), 1);
    }

    function testSettersAndTwoStepOwnership() public {
        address nextOwner = makeAddr("next owner");
        vm.startPrank(owner);
        tracker.setBody('{"parentJobId":"', '","objective":"new","skill":"import-site"}');
        tracker.setActions("new.open", "new.continue");
        tracker.setTiming(1 hours, 30 days);
        tracker.transferOwnership(nextOwner);
        vm.stopPrank();
        assertEq(tracker.owner(), owner);
        assertEq(tracker.pendingOwner(), nextOwner);
        vm.expectRevert(BurnTracker.NotPendingOwner.selector);
        tracker.acceptOwnership();
        vm.prank(nextOwner);
        tracker.acceptOwnership();
        assertEq(tracker.owner(), nextOwner);
        assertEq(tracker.pendingOwner(), address(0));
        vm.prank(owner);
        vm.expectRevert(BurnTracker.NotOwner.selector);
        tracker.setTiming(2 hours, 2 days);
        assertEq(tracker.openAction(), bytes32("new.open"));
        assertEq(tracker.continueAction(), bytes32("new.continue"));
    }

    function testAllAdministrationIsOwnerOnly() public {
        vm.startPrank(caller);
        vm.expectRevert(BurnTracker.NotOwner.selector);
        tracker.recover(PARENT);
        vm.expectRevert(BurnTracker.NotOwner.selector);
        tracker.setResultHash(keccak256(PROOF));
        vm.expectRevert(BurnTracker.NotOwner.selector);
        tracker.setBody("x", "y");
        vm.expectRevert(BurnTracker.NotOwner.selector);
        tracker.setActions(OPEN, CONTINUE);
        vm.expectRevert(BurnTracker.NotOwner.selector);
        tracker.setIntake(address(intake), address(token));
        vm.expectRevert(BurnTracker.NotOwner.selector);
        tracker.setTiming(1 days, 2 days);
        vm.expectRevert(BurnTracker.NotOwner.selector);
        tracker.withdraw(address(token), caller, 1);
        vm.expectRevert(BurnTracker.NotOwner.selector);
        tracker.transferOwnership(caller);
        vm.stopPrank();
    }

    function testInvalidConfiguration() public {
        vm.startPrank(owner);
        vm.expectRevert(BurnTracker.InvalidAddress.selector);
        tracker.setIntake(address(0), address(token));
        vm.expectRevert(BurnTracker.InvalidAddress.selector);
        tracker.setIntake(address(intake), address(0));
        vm.expectRevert(BurnTracker.InvalidAddress.selector);
        tracker.transferOwnership(address(0));
        vm.expectRevert(BurnTracker.InvalidAction.selector);
        tracker.setActions(0, CONTINUE);
        vm.expectRevert(BurnTracker.InvalidAction.selector);
        tracker.setActions(OPEN, 0);
        vm.expectRevert(BurnTracker.InvalidTiming.selector);
        tracker.setTiming(3599, 2 days);
        vm.expectRevert(BurnTracker.InvalidTiming.selector);
        tracker.setTiming(30 days + 1, 2 days);
        vm.expectRevert(BurnTracker.InvalidTiming.selector);
        tracker.setTiming(1 days, 3599);
        vm.expectRevert(BurnTracker.InvalidTiming.selector);
        tracker.setTiming(1 days, 30 days + 1);
        vm.expectRevert(BurnTracker.InvalidBody.selector);
        tracker.setBody(new bytes(16_384), "");
        vm.stopPrank();
    }

    function testWithdrawOnlyOwnerRecoversAccidentalTokens() public {
        token.mint(address(tracker), 123);
        vm.prank(owner);
        tracker.withdraw(address(token), caller, 123);
        assertEq(token.balanceOf(caller), 100 ether + 123);
        vm.prank(owner);
        vm.expectRevert(BurnTracker.InvalidAddress.selector);
        tracker.withdraw(address(token), address(0), 1);
    }

    function testUnpricedActionsAndPaymentFailuresRollBack() public {
        intake.setPrice(OPEN, 0);
        vm.prank(owner);
        vm.expectRevert(BurnTracker.ActionNotSold.selector);
        tracker.open(OPEN_BODY);
        intake.setPrice(OPEN, PRICE);
        token.setFailure(true);
        vm.prank(owner);
        vm.expectRevert();
        tracker.open(OPEN_BODY);
        token.setFailure(false);
        intake.setRevert(true);
        vm.prank(owner);
        vm.expectRevert("order failed");
        tracker.open(OPEN_BODY);
        assertEq(_state(), 1);
        assertEq(token.balanceOf(owner), 100 ether);
        assertEq(token.balanceOf(treasury), 0);
        assertEq(token.allowance(address(tracker), address(intake)), 0);
    }

    function testFeeOnTransferTokenRejected() public {
        token.setFee(true);
        vm.prank(owner);
        vm.expectRevert(BurnTracker.UnsupportedAsset.selector);
        tracker.open(OPEN_BODY);
        assertEq(token.balanceOf(owner), 100 ether);
        assertEq(_state(), 1);
    }

    function testTokenAndIntakeReentrancyCannotOrderOrSettle() public {
        token.setHook(address(tracker), abi.encodeCall(tracker.updateBurntracker, (PROOF, PRICE)));
        bytes32 id = _open();
        assertFalse(token.hookSucceeded());
        _complete(id, keccak256(PROOF));
        vm.warp(tracker.nextUpdateAt());
        intake.setHook(address(tracker), abi.encodeCall(tracker.onResult, (id, keccak256("fake"), "early")));
        _update();
        assertFalse(token.hookSucceeded());
        assertFalse(intake.hookSucceeded());
        assertEq(_state(), 3);
    }

    function testBodyLengthBounds() public {
        vm.prank(owner);
        vm.expectRevert(BurnTracker.InvalidBody.selector);
        tracker.open("");
        vm.prank(owner);
        vm.expectRevert(BurnTracker.InvalidBody.selector);
        tracker.open(new bytes(16_385));
    }
}
