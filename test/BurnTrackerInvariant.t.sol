// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BurnTracker} from "src/BurnTracker.sol";
import {MockToken} from "./helpers/MockIntake.sol";
import {BurnTrackerHandler} from "./helpers/BurnTrackerHandler.sol";

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 128
/// forge-config: default.invariant.fail-on-revert = true
contract BurnTrackerInvariantTest is Test {
    BurnTrackerHandler internal handler;
    BurnTracker internal tracker;

    function setUp() public {
        vm.warp(1_800_000_000);
        handler = new BurnTrackerHandler();
        tracker = handler.tracker();
        bytes4[] memory selectors = new bytes4[](14);
        selectors[0] = handler.elapse.selector;
        selectors[1] = handler.order.selector;
        selectors[2] = handler.settle.selector;
        selectors[3] = handler.adopt.selector;
        selectors[4] = handler.rejectBadProof.selector;
        selectors[5] = handler.rejectCallback.selector;
        selectors[6] = handler.configure.selector;
        selectors[7] = handler.changePrices.selector;
        selectors[8] = handler.proposeOwner.selector;
        selectors[9] = handler.acceptOwner.selector;
        selectors[10] = handler.rejectAdministration.selector;
        selectors[11] = handler.donate.selector;
        selectors[12] = handler.withdraw.selector;
        // Give orders extra weight so campaigns spend time in all three pending kinds.
        selectors[13] = handler.order.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    /// @dev Per-actor balances catch the wrong wallet being charged; the total alone would not.
    function invariant_paymentsAndDonationsConserveEveryActorsFunds() public view {
        for (uint256 t; t < 2; ++t) {
            MockToken token = handler.tokens(t);
            uint256 total = token.balanceOf(address(tracker)) + token.balanceOf(handler.treasury());
            assertEq(
                token.balanceOf(handler.treasury()), handler.paid(t), "successful orders must be spent exactly once"
            );
            assertEq(
                token.balanceOf(address(tracker)),
                handler.donated(t) - handler.withdrawn(t),
                "orders consumed donated funds or stranded payment"
            );
            for (uint256 a; a < 4; ++a) {
                address actor = handler.actors(a);
                uint256 expected = handler.INITIAL_FUNDS() + handler.actorWithdrawn(t, actor)
                    - handler.actorPaid(t, actor) - handler.actorDonated(t, actor);
                assertEq(token.balanceOf(actor), expected, "wrong payer or unauthorized withdrawal");
                total += token.balanceOf(actor);
            }
            assertEq(total, 4 * handler.INITIAL_FUNDS(), "tokens created or lost");
            for (uint256 i; i < 2; ++i) {
                assertEq(
                    token.allowance(address(tracker), address(handler.intakes(i))), 0, "lingering Intake allowance"
                );
                assertEq(token.balanceOf(address(handler.intakes(i))), 0, "Intake retained payment");
            }
        }
    }

    function invariant_stateDeadlinesAndProofMatchTheRequestHistory() public view {
        (uint8 state, uint8 kind, uint40 done, uint40 ordered, uint40 stale, uint32 cooldown, uint32 staleAfter) =
            tracker.status();
        assertEq(state, handler.expectedState());
        assertEq(kind, handler.expectedKind());
        assertEq(done, handler.expectedDone());
        assertEq(ordered, handler.expectedOrdered());
        assertEq(stale, handler.expectedStale(), "pending deadline moved with configuration");
        assertEq(cooldown, handler.expectedCooldown());
        assertEq(staleAfter, handler.expectedStaleAfter());
        assertEq(tracker.nextUpdateAt(), state == 2 ? uint256(done) + cooldown : 0);
        assertEq(tracker.resultHash(), handler.expectedHash(), "unauthorized proof replacement");
        assertNotEq(tracker.resultHash(), bytes32(0), "callback slot cleared to zero");
        assertEq(tracker.lastRequestId(), handler.currentRequest());
        assertEq(
            handler.intakes(0).nonce() + handler.intakes(1).nonce(), handler.orders(), "phantom or unrecorded order"
        );
        if (state == 3) {
            assertGe(kind, 1);
            assertLe(kind, 3);
            assertNotEq(tracker.lastRequestId(), bytes32(0));
        } else {
            assertEq(kind, 0);
        }
    }

    function invariant_onlyAuthorizedConfigurationAndOwnershipPersist() public view {
        assertEq(tracker.owner(), handler.expectedOwner());
        assertEq(tracker.pendingOwner(), handler.expectedPendingOwner());
        assertEq(tracker.intake(), address(handler.intakes(handler.intakeIndex())));
        assertEq(tracker.asset(), address(handler.tokens(handler.tokenIndex())));
        assertEq(tracker.openAction(), handler.expectedOpen());
        assertEq(tracker.continueAction(), handler.expectedContinue());
        assertEq(tracker.bodyPrefix(), handler.expectedPrefix());
        assertEq(tracker.bodySuffix(), handler.expectedSuffix());
        assertEq(tracker.price(), handler.intakes(handler.intakeIndex()).prices(handler.expectedContinue()));
    }

    /// @dev Pins reachability so an all-reverting handler cannot silently satisfy the invariants.
    function testHandlerReachesPaymentRecoveryRotationAndOwnershipPaths() public {
        handler.order(0, 0, 1); // open
        handler.donate(0, 2, 3 ether);
        handler.configure(1, 1, 1); // pending callback must still use Intake 0
        handler.settle(0, bytes16(uint128(2)));
        handler.elapse(0, 1);
        handler.order(1, 1, 1); // sponsor update using asset and Intake 1
        handler.settle(1, bytes16(uint128(3))); // refusal retains its proof
        handler.order(2, 0, 1); // recovery bypasses cooldown
        handler.settle(2, bytes16(uint128(4))); // failure -> STUCK
        handler.adopt(bytes16(uint128(5)), 0);
        handler.order(2, 0, 1);
        handler.elapse(0, 3);
        handler.order(0, 0, 1); // stale replacement
        handler.rejectCallback(4, 0, keccak256("late"));
        handler.proposeOwner(2);
        handler.acceptOwner(1); // wrong nominee
        handler.acceptOwner(2);
        handler.withdraw(0, 2, 0, 1); // full donated balance
        handler.rejectAdministration(7, 0);
        assertEq(handler.orders(), 5);
        assertEq(handler.successfulCallbacks(), 3);
        assertEq(handler.superseded(), 1);
        assertGe(handler.rejectedCalls(), 3);
        invariant_paymentsAndDonationsConserveEveryActorsFunds();
        invariant_stateDeadlinesAndProofMatchTheRequestHistory();
        invariant_onlyAuthorizedConfigurationAndOwnershipPersist();
    }
}
