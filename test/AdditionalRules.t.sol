// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BurnTrackerFixture} from "./BurnTracker.t.sol";
import {BurnTracker} from "../src/BurnTracker.sol";
import {MockIntake, MockToken} from "./helpers/MockIntake.sol";

contract AdditionalRulesTest is BurnTrackerFixture {
    function testConstructorRejectsInvalidStaticConfiguration() public {
        vm.expectRevert(BurnTracker.InvalidAddress.selector);
        new BurnTracker(address(0), address(intake), address(token), OPEN, CONTINUE, 86400, 172800);
        vm.expectRevert(BurnTracker.InvalidAddress.selector);
        new BurnTracker(owner, address(0), address(token), OPEN, CONTINUE, 86400, 172800);
        vm.expectRevert(BurnTracker.InvalidAddress.selector);
        new BurnTracker(owner, address(intake), address(0), OPEN, CONTINUE, 86400, 172800);
        vm.expectRevert(BurnTracker.InvalidAction.selector);
        new BurnTracker(owner, address(intake), address(token), 0, CONTINUE, 86400, 172800);
        vm.expectRevert(BurnTracker.InvalidAction.selector);
        new BurnTracker(owner, address(intake), address(token), OPEN, 0, 86400, 172800);
        vm.expectRevert(BurnTracker.InvalidTiming.selector);
        new BurnTracker(owner, address(intake), address(token), OPEN, CONTINUE, 3599, 172800);
        vm.expectRevert(BurnTracker.InvalidTiming.selector);
        new BurnTracker(owner, address(intake), address(token), OPEN, CONTINUE, 86400, 30 days + 1);
    }

    function testOwnerEditedBodyAndActionsAreUsedForUpdatesAndRecovery() public {
        _ready();
        bytes memory prefix = '{"objective":"owner chooses this","parentJobId":"';
        bytes memory suffix = '","skill":"import-site","host":true}';
        vm.startPrank(owner);
        tracker.setBody(prefix, suffix);
        tracker.setActions("next.open", "next.continue");
        vm.stopPrank();
        intake.setPrice("next.continue", 123);
        vm.prank(caller);
        bytes32 id = tracker.updateBurntracker(PROOF, 123);
        assertEq(intake.bodyHash(), keccak256(bytes.concat(prefix, bytes(PARENT), suffix)));
        assertEq(intake.actionAtRequest(), bytes32("next.continue"));
        _complete(id, keccak256(PROOF));
        vm.prank(owner);
        tracker.recover(PARENT);
        assertEq(intake.bodyHash(), keccak256(bytes.concat(prefix, bytes(PARENT), suffix)));
    }

    function testOwnerCanChangeAssetAndNewIntakeForFutureOrders() public {
        _ready();
        MockToken nextToken = new MockToken();
        MockIntake next = new MockIntake(treasury, writer);
        next.setPrice(CONTINUE, 55);
        nextToken.mint(caller, 55);
        vm.prank(caller);
        nextToken.approve(address(tracker), 55);
        vm.prank(owner);
        tracker.setIntake(address(next), address(nextToken));
        vm.prank(caller);
        bytes32 id = tracker.updateBurntracker(PROOF, 55);
        (address payer,,,,) = next.requests(id);
        assertEq(payer, address(tracker));
        assertEq(nextToken.balanceOf(treasury), 55);
        assertEq(nextToken.balanceOf(caller), 0);
        assertEq(token.balanceOf(caller), 100 ether);
        assertEq(tracker.price(), 55);
    }

    function testCooldownSettingAffectsExistingIdleCompletion() public {
        _complete(_open(), keccak256(PROOF));
        uint256 done = block.timestamp;
        vm.prank(owner);
        tracker.setTiming(1 hours, 2 days);
        assertEq(tracker.nextUpdateAt(), done + 1 hours);
        vm.warp(done + 1 hours);
        _update();
    }

    function testCallbackStillAllowedAfterDeadlineUntilOwnerSupersedesIt() public {
        bytes32 id = _open();
        vm.warp(block.timestamp + 30 days);
        _complete(id, keccak256(PROOF));
        assertEq(_state(), 2);
        assertEq(tracker.nextUpdateAt(), block.timestamp + 1 days);
    }

    function testStaleRecoveryCanBeReplacedWithAnOpen() public {
        _ready();
        vm.prank(owner);
        bytes32 id = tracker.recover(PARENT);
        vm.warp(block.timestamp + 2 days);
        _open();
        vm.prank(address(intake));
        vm.expectRevert(abi.encodeWithSelector(BurnTracker.NotPending.selector, id));
        tracker.onFailure(id, 2, "late", 0, 0, "");
    }

    function testUnpricedUpdateAndZeroMaxPriceCannotMoveFunds() public {
        _ready();
        intake.setPrice(CONTINUE, 0);
        vm.prank(caller);
        vm.expectRevert(BurnTracker.ActionNotSold.selector);
        tracker.updateBurntracker(PROOF, PRICE);
        intake.setPrice(CONTINUE, PRICE);
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(BurnTracker.PriceTooHigh.selector, PRICE, 0));
        tracker.updateBurntracker(PROOF, 0);
        assertEq(token.balanceOf(caller), 100 ether);
        assertEq(_state(), 2);
    }

    function testUnknownFailureRequestCannotChangeAwaitedOrder() public {
        _open();
        vm.prank(address(intake));
        vm.expectRevert(abi.encodeWithSelector(BurnTracker.NotPending.selector, bytes32("not requested")));
        tracker.onFailure("not requested", 1, "body_refused", 0, 0, "");
        assertEq(_state(), 3);
    }

    function testOwnershipCannotBeAcceptedWithoutAProposal() public {
        vm.expectRevert(BurnTracker.NotPendingOwner.selector);
        tracker.acceptOwnership();
        vm.prank(address(0));
        vm.expectRevert(BurnTracker.NotPendingOwner.selector);
        tracker.acceptOwnership();
        assertEq(tracker.owner(), owner);
    }

    function testOwnershipProposalCanBeReplacedButOnlyLatestCandidateCanAccept() public {
        address oldCandidate = makeAddr("old candidate");
        address latest = makeAddr("latest candidate");
        vm.startPrank(owner);
        tracker.transferOwnership(oldCandidate);
        tracker.transferOwnership(latest);
        vm.stopPrank();
        vm.prank(oldCandidate);
        vm.expectRevert(BurnTracker.NotPendingOwner.selector);
        tracker.acceptOwnership();
        vm.prank(latest);
        tracker.acceptOwnership();
        assertEq(tracker.owner(), latest);
    }

    function testRuntimeFitsDeploymentPolicy() public view {
        bytes memory code = address(tracker).code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        bool reachable = true;
        for (uint256 j; j < code.length; ++j) {
            uint8 op = uint8(code[j]);
            if (op == 0x5b) reachable = true;
            if (op >= 0x60 && op <= 0x7f) {
                j += op - 0x5f;
                continue;
            }
            if (reachable) assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden application opcode");
            if (op == 0x00 || op == 0x56 || op == 0xf3 || op == 0xfd || op == 0xfe) reachable = false;
        }
    }

    function testFuzzPlainParserMatchesJsonDecoder(bytes32 entropy, uint8 fillLength) public view {
        bytes memory text = new bytes(uint256(fillLength) + 32);
        for (uint256 i; i < text.length; ++i) {
            bytes1 c = bytes1(uint8(32 + uint8(entropy[i % 32]) % 95));
            if (c == '"' || c == "\\") c = "k";
            text[i] = c;
        }
        bytes memory doc = bytes.concat('{"a":"', text, '","jobId":"', bytes(PARENT), '","z":"jobId"}');
        assertEq(tracker.parentJobIdOf(doc), bytes(vm.parseJsonString(string(doc), ".jobId")));
    }

    function testFuzzEscapedStringCannotForgeKey(uint8 slashCount_, uint8 alignment_) public {
        uint256 slashCount = uint256(slashCount_) % 16;
        bytes memory padding = new bytes(uint256(alignment_) % 64);
        for (uint256 i; i < padding.length; ++i) {
            padding[i] = "k";
        }
        bytes memory backslashes = new bytes(slashCount * 2);
        for (uint256 i; i < backslashes.length; ++i) {
            backslashes[i] = "\\";
        }
        bytes memory value =
            bytes.concat(padding, backslashes, "\\\"jobId\\\":\\\"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa\\\"");
        bytes memory missing = bytes.concat('{"a":"', value, '"}');
        vm.expectRevert(BurnTracker.InvalidResultJson.selector);
        tracker.parentJobIdOf(missing);
        bytes memory present = bytes.concat('{"a":"', value, '","jobId":"', bytes(PARENT), '"}');
        assertEq(tracker.parentJobIdOf(present), bytes(vm.parseJsonString(string(present), ".jobId")));
    }

    function testFuzzParserWordBorrowCandidates(uint8 alignment_, bool afterId) public view {
        bytes memory padding = new bytes(uint256(alignment_) % 64);
        for (uint256 i; i < padding.length; ++i) {
            padding[i] = "k";
        }
        bytes memory doc = afterId
            ? bytes.concat('{"jobId":"', bytes(PARENT), '","z":"', padding, 'jjkkjjkk"}')
            : bytes.concat('{"a":"', padding, 'jjkkjjkk","jobId":"', bytes(PARENT), '"}');
        assertEq(tracker.parentJobIdOf(doc), bytes(PARENT));
    }
}
