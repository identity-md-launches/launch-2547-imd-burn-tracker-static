// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BurnTracker} from "src/BurnTracker.sol";
import {BurnTrackerFixture} from "./BurnTracker.t.sol";
import {ResultDocuments} from "./helpers/ResultDocuments.sol";
import {MockToken} from "./helpers/MockIntake.sol";

contract BoundaryRulesTest is BurnTrackerFixture {
    function testTimingEndpointsAcceptedByConstructorAndSetter() public {
        uint32[2] memory endpoints = [uint32(1 hours), uint32(30 days)];
        for (uint256 c; c < 2; ++c) {
            for (uint256 s; s < 2; ++s) {
                BurnTracker deployed =
                    new BurnTracker(owner, address(intake), address(token), OPEN, CONTINUE, endpoints[c], endpoints[s]);
                (,,,,, uint32 cooldown, uint32 staleAfter) = deployed.status();
                assertEq(cooldown, endpoints[c]);
                assertEq(staleAfter, endpoints[s]);
                vm.prank(owner);
                tracker.setTiming(endpoints[c], endpoints[s]);
                (,,,,, cooldown, staleAfter) = tracker.status();
                assertEq(cooldown, endpoints[c]);
                assertEq(staleAfter, endpoints[s]);
            }
        }
    }

    function testFuzzInvalidTimingCannotChangePendingDeadline(uint32 entropy, bool belowMinimum, bool changeCooldown)
        public
    {
        _open();
        bytes memory beforeStatus = _statusBytes();
        uint32 bad =
            belowMinimum ? uint32(bound(entropy, 0, 3599)) : uint32(bound(entropy, 30 days + 1, type(uint32).max));
        vm.prank(owner);
        vm.expectRevert(BurnTracker.InvalidTiming.selector);
        tracker.setTiming(changeCooldown ? bad : uint32(1 days), changeCooldown ? uint32(2 days) : bad);
        assertEq(_statusBytes(), beforeStatus);
        vm.expectRevert(BurnTracker.InvalidTiming.selector);
        new BurnTracker(
            owner,
            address(intake),
            address(token),
            OPEN,
            CONTINUE,
            changeCooldown ? bad : uint32(1 days),
            changeCooldown ? uint32(2 days) : bad
        );
    }

    /// @dev Exercises both shortening and extending staleAfter while a request is pending.
    function testFuzzAllOwnerEscapesRespectOriginalStaleDeadline(
        uint32 firstStale,
        uint32 changedStale,
        uint32 cooldownSeed
    ) public {
        firstStale = uint32(bound(firstStale, 1 hours, 30 days));
        changedStale = uint32(bound(changedStale, 1 hours, 30 days));
        uint32 cooldown = uint32(bound(cooldownSeed, 1 hours, 30 days));
        vm.prank(owner);
        tracker.setTiming(cooldown, firstStale);
        bytes32 abandoned = _open();
        uint256 deadline = vm.getBlockTimestamp() + firstStale;
        vm.prank(owner);
        tracker.setTiming(cooldown, changedStale);
        vm.warp(deadline - 1);
        vm.startPrank(owner);
        vm.expectRevert(BurnTracker.WrongState.selector);
        tracker.open(OPEN_BODY);
        vm.expectRevert(BurnTracker.WrongState.selector);
        tracker.recover(PARENT);
        vm.expectRevert(BurnTracker.WrongState.selector);
        tracker.setResultHash(keccak256(PROOF));
        vm.stopPrank();
        (,,,, uint40 stale,,) = tracker.status();
        assertEq(stale, deadline);
        assertEq(intake.nonce(), 1);
        vm.warp(deadline);
        vm.prank(owner);
        tracker.setResultHash(keccak256(PROOF));
        assertEq(tracker.nextUpdateAt(), deadline + cooldown);
        vm.prank(address(intake));
        vm.expectRevert(abi.encodeWithSelector(BurnTracker.NotPending.selector, abandoned));
        tracker.onFailure(abandoned, 1, "refused", 0, 0, "");
        vm.warp(deadline + cooldown - 1);
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(BurnTracker.CooldownActive.selector, deadline + cooldown));
        tracker.updateBurntracker(PROOF, PRICE);
        vm.warp(deadline + cooldown);
        _update();
        (,,,, stale,,) = tracker.status();
        assertEq(stale, vm.getBlockTimestamp() + changedStale);
    }

    function testFuzzInvalidCallbackStatusCannotChangeAnything(uint8 entropy, bool zeroStatus, bytes32 reason) public {
        bytes32 id = _open();
        bytes memory beforeStatus = _statusBytes();
        bytes32 beforeHash = tracker.resultHash();
        uint8 status = zeroStatus ? 0 : uint8(bound(entropy, 3, 255));
        vm.prank(address(intake));
        vm.expectRevert(BurnTracker.InvalidFailureStatus.selector);
        tracker.onFailure(id, status, reason, type(uint16).max, 1, "arbitrary metadata");
        assertEq(_statusBytes(), beforeStatus);
        assertEq(tracker.resultHash(), beforeHash);
        assertEq(token.balanceOf(treasury), PRICE);
        // A rejected callback must not burn the contract's opportunity to accept a valid one.
        _complete(id, keccak256(PROOF));
        assertEq(_state(), 2);
    }

    function testFuzzFailureMetadataCannotChangeRefusalTransition(
        bytes32 reason,
        uint16 agreed,
        uint16 answered,
        bytes32 signature
    ) public {
        _ready();
        bytes32 id = _update();
        vm.warp(vm.getBlockTimestamp() + 13);
        vm.expectEmit(true, false, false, true, address(tracker));
        emit Failed(id, 1, reason, 2);
        vm.prank(address(intake));
        tracker.onFailure(id, 1, reason, agreed, answered, abi.encode(signature));
        assertEq(_state(), 2);
        assertEq(tracker.resultHash(), keccak256(PROOF));
        assertEq(tracker.nextUpdateAt(), vm.getBlockTimestamp() + 1 days);
        assertEq(token.balanceOf(treasury), 2 * PRICE);
        assertEq(token.balanceOf(caller), 100 ether - PRICE);
    }

    function testFuzzLivePriceAndSlippageAtOneWeiBoundary(uint96 priceSeed) public {
        uint256 quote = bound(priceSeed, 1, 100 ether);
        _ready();
        intake.setPrice(CONTINUE, quote);
        assertEq(tracker.price(), quote);
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(BurnTracker.PriceTooHigh.selector, quote, quote - 1));
        tracker.updateBurntracker(PROOF, quote - 1);
        assertEq(token.balanceOf(caller), 100 ether);
        vm.prank(caller);
        bytes32 id = tracker.updateBurntracker(PROOF, quote);
        assertEq(tracker.lastRequestId(), id);
        assertEq(token.balanceOf(caller), 100 ether - quote);
        assertEq(token.balanceOf(treasury), PRICE + quote);
        assertEq(token.balanceOf(address(tracker)), 0);
        assertEq(token.allowance(address(tracker), address(intake)), 0);
    }

    function testOneWeiQuoteCanConsumeEntireSponsorsBalance() public {
        _ready();
        address oneWeiSponsor = makeAddr("one wei sponsor");
        token.mint(oneWeiSponsor, 1);
        intake.setPrice(CONTINUE, 1);
        vm.startPrank(oneWeiSponsor);
        token.approve(address(tracker), 1);
        tracker.updateBurntracker(PROOF, 1);
        vm.stopPrank();
        assertEq(token.balanceOf(oneWeiSponsor), 0);
        assertEq(token.allowance(oneWeiSponsor, address(tracker)), 0);
        assertEq(token.balanceOf(treasury), PRICE + 1);
        assertEq(token.balanceOf(address(tracker)), 0);
    }

    function testMaximumUint256PriceHasNoArithmeticTruncation() public {
        _ready();
        // Isolate a fresh token so its total held value fits uint256, even at this extreme.
        // MockToken has no fixed supply; all of this asset's value starts with the new sponsor.
        address maxSponsor = makeAddr("maximum amount sponsor");
        MockToken fresh = new MockToken();
        fresh.mint(maxSponsor, type(uint256).max);
        vm.prank(owner);
        tracker.setIntake(address(intake), address(fresh));
        intake.setPrice(CONTINUE, type(uint256).max);
        vm.startPrank(maxSponsor);
        fresh.approve(address(tracker), type(uint256).max);
        tracker.updateBurntracker(PROOF, type(uint256).max);
        vm.stopPrank();
        assertEq(fresh.balanceOf(maxSponsor), 0);
        assertEq(fresh.balanceOf(treasury), type(uint256).max);
        assertEq(fresh.balanceOf(address(tracker)), 0);
        assertEq(fresh.allowance(address(tracker), address(intake)), 0);
    }

    function testOpenBodyAtExactByteLimitIsForwardedUnchanged() public {
        bytes memory body = ResultDocuments.repeat("x", 16_384);
        vm.prank(owner);
        bytes32 id = tracker.open(body);
        assertEq(intake.bodyHash(), keccak256(body));
        assertEq(tracker.lastRequestId(), id);
        assertEq(token.balanceOf(owner), 100 ether - PRICE);
    }

    function testTemplateLimitCountsBothPartsAndThe36ByteParent() public {
        _ready();
        // This tests the on-chain byte limit; validation of owner-supplied JSON belongs to Intake.
        bytes memory prefix = ResultDocuments.repeat("x", 8_000);
        bytes memory suffix = ResultDocuments.repeat("y", 16_384 - 36 - prefix.length);
        vm.prank(owner);
        tracker.setBody(prefix, suffix);
        bytes memory beforePrefix = tracker.bodyPrefix();
        vm.prank(owner);
        vm.expectRevert(BurnTracker.InvalidBody.selector);
        tracker.setBody(prefix, bytes.concat(suffix, "y"));
        assertEq(tracker.bodyPrefix(), beforePrefix);
        assertEq(tracker.bodySuffix(), suffix);
        _update();
        bytes memory expected = bytes.concat(prefix, bytes(PARENT), suffix);
        assertEq(expected.length, 16_384);
        assertEq(intake.bodyHash(), keccak256(expected));
    }

    function testNewOwnerPaysRecoveryAndOldOwnerLosesAllPrivileges() public {
        bytes32 abandoned = _open();
        vm.prank(owner);
        tracker.transferOwnership(caller);
        vm.prank(caller);
        tracker.acceptOwnership();
        vm.warp(block.timestamp + 2 days);
        vm.startPrank(owner);
        vm.expectRevert(BurnTracker.NotOwner.selector);
        tracker.recover(PARENT);
        vm.expectRevert(BurnTracker.NotOwner.selector);
        tracker.withdraw(address(token), owner, 0);
        vm.stopPrank();
        vm.prank(caller);
        bytes32 recovery = tracker.recover(PARENT);
        assertEq(token.balanceOf(owner), 100 ether - PRICE);
        assertEq(token.balanceOf(caller), 100 ether - PRICE);
        vm.prank(address(intake));
        vm.expectRevert(abi.encodeWithSelector(BurnTracker.NotPending.selector, abandoned));
        tracker.onResult(abandoned, keccak256("abandoned"), "late");
        _complete(recovery, keccak256(PROOF));
        assertEq(_state(), 2);
    }

    function _statusBytes() private view returns (bytes memory data) {
        bool ok;
        (ok, data) = address(tracker).staticcall(abi.encodeCall(tracker.status, ()));
        assertTrue(ok);
    }
}
