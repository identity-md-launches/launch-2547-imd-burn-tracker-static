// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BurnTrackerFixture} from "./BurnTracker.t.sol";
import {BurnTracker} from "../src/BurnTracker.sol";
import {Vm} from "forge-std/Vm.sol";

contract ParserAndGasTest is BurnTrackerFixture {
    function testRealResultDocumentsMatchMainnetHashesAndParseAndOrderExactBody() public {
        string memory provenance = vm.readFile("test/fixtures/results-provenance.json");
        for (uint256 i; i < 5; ++i) {
            // Provenance order is independent of file length; every fixture is also hash-checked
            // against the actual ABI-encoded Completed event retained from mainnet.
            string memory base = string.concat("$[", vm.toString(i), "]");
            bytes memory raw = vm.readFileBinary(vm.parseJsonString(provenance, string.concat(base, ".path")));
            bytes32 hash = vm.parseJsonBytes32(provenance, string.concat(base, ".keccak256"));
            bytes memory logData = vm.parseJsonBytes(provenance, string.concat(base, ".completionLog.data"));
            (uint8 status_, bytes32 recordedHash,,) = abi.decode(logData, (uint8, bytes32, string, bool));
            assertEq(status_, 0);
            assertEq(hash, recordedHash);
            assertEq(keccak256(raw), recordedHash);
            string memory parent = vm.parseJsonString(provenance, string.concat(base, ".jobId"));
            uint256 beforeGas = gasleft();
            assertEq(tracker.parentJobIdOf(raw), bytes(parent));
            emit log_named_uint(
                string.concat("parser gas for ", vm.toString(raw.length), " bytes"), beforeGas - gasleft()
            );
            bytes32 id;
            if (i == 0) {
                id = _open();
            } else {
                vm.prank(owner);
                id = tracker.recover(PARENT);
            }
            _complete(id, recordedHash);
            vm.warp(tracker.nextUpdateAt());
            vm.prank(caller);
            bytes32 next = tracker.updateBurntracker(raw, PRICE);
            assertEq(
                intake.bodyHash(), keccak256(bytes.concat(tracker.bodyPrefix(), bytes(parent), tracker.bodySuffix()))
            );
            _complete(next, recordedHash);
        }
    }

    function testParserRejectsMissingDuplicateMalformedAndUppercase() public {
        bytes[12] memory invalid = [
            bytes("{}"),
            bytes('{"x":"jobId"}'),
            bytes('{"jobId":null}'),
            bytes('{"jobId":123}'),
            bytes('{"jobId":""}'),
            bytes('{"jobId":"c9822c12-52e3-4d28-b474-a9ab751b10b"}'),
            bytes('{"jobId":"C9822c12-52e3-4d28-b474-a9ab751b10b3"}'),
            bytes('{"jobId":"c9822c12_52e3-4d28-b474-a9ab751b10b3"}'),
            bytes('{"jobId":"c9822c12-52e3-4d28-b474-a9ab751b10bg"}'),
            bytes('{"jobId":"c9822c12-52e3-4d28-b474-a9ab751b10b3","jobId":"c9822c12-52e3-4d28-b474-a9ab751b10b3"}'),
            bytes(
                '{"a":{"jobId":"c9822c12-52e3-4d28-b474-a9ab751b10b3"},"jobId":"c9822c12-52e3-4d28-b474-a9ab751b10b3"}'
            ),
            bytes(
                '{"jobId":"c9822c12-52e3-4d28-b474-a9ab751b10b3","j\\u006fbId":"c9822c12-52e3-4d28-b474-a9ab751b10b3"}'
            )
        ];
        for (uint256 i; i < invalid.length; ++i) {
            vm.expectRevert();
            tracker.parentJobIdOf(invalid[i]);
        }
    }

    function testEscapedQuoteInValueCannotForgeKey() public {
        bytes memory forged =
            '{"message":"an escaped quote \",\\\"jobId\\\":\\\"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa\\\""}';
        vm.expectRevert(BurnTracker.InvalidResultJson.selector);
        tracker.parentJobIdOf(forged);
        // A literal key in a later object member must still be found after escaped string content.
        bytes memory simpler = bytes(string.concat('{"a":"\\\"jobId\\\":\\\"fake\\\"","jobId":"', PARENT, '"}'));
        assertEq(tracker.parentJobIdOf(simpler), bytes(PARENT));
    }

    function testWhitespaceAndJobIdValueDoNotCountAsKey() public view {
        bytes memory doc = bytes(string.concat('{"a":"jobId","jobId" \t:\n "', PARENT, '"\r}'));
        assertEq(tracker.parentJobIdOf(doc), bytes(PARENT));
    }

    function testUnterminatedStringAndTruncatedUuidRevert() public {
        vm.expectRevert();
        tracker.parentJobIdOf('{"jobId":"abcd}');
        vm.expectRevert();
        tracker.parentJobIdOf('{"a":"unfinished\\}');
        vm.expectRevert();
        tracker.parentJobIdOf('{"jobId":"c9822c12-52e3-4d28-b474-a9ab751b10b3"');
    }

    function testFuzzParserUuidRoundTrip(bytes16 entropy, uint16 padding_) public view {
        bytes memory id = _uuid(entropy);
        uint256 padding = uint256(padding_) % 5000;
        bytes memory text = new bytes(padding);
        for (uint256 i; i < padding; ++i) {
            text[i] = "x";
        }
        bytes memory doc = bytes.concat('{"a":"', text, '\\\"jobId\\\":\\\"decoy\\\"","jobId":"', id, '","z":"end"}');
        assertEq(tracker.parentJobIdOf(doc), id);
    }

    function testFuzzDuplicateKeyAlwaysRejected(bytes16 entropy, bool nested) public {
        bytes memory id = _uuid(entropy);
        bytes memory head = nested ? bytes('{"a":{"jobId":"') : bytes('{"jobId":"');
        bytes memory middle = nested ? bytes('"},"jobId":"') : bytes('","jobId":"');
        vm.expectRevert(BurnTracker.InvalidResultJson.selector);
        tracker.parentJobIdOf(bytes.concat(head, id, middle, id, '"}'));
    }

    function testFuzzBadUuidByteRejected(bytes1 bad, uint8 position) public {
        uint256 p = uint256(position) % 36;
        bool dash = p == 8 || p == 13 || p == 18 || p == 23;
        vm.assume(dash ? bad != "-" : !((bad >= "0" && bad <= "9") || (bad >= "a" && bad <= "f")));
        bytes memory id = bytes(PARENT);
        id[p] = bad;
        vm.expectRevert();
        tracker.parentJobIdOf(bytes.concat('{"jobId":"', id, '"}'));
    }

    function testFuzzAnyAlterationOfAuthenticatedProofRejected(uint16 offset, bytes1 replacement) public {
        _ready();
        bytes memory mutated = PROOF;
        uint256 i = uint256(offset) % mutated.length;
        vm.assume(mutated[i] != replacement);
        mutated[i] = replacement;
        vm.expectRevert(BurnTracker.InvalidHash.selector);
        tracker.updateBurntracker(mutated, PRICE);
    }

    function testCallbacksWithin200kAndOnlyWriteConstructorInitializedSlots() public {
        BurnTracker pristine = new BurnTracker(owner, address(intake), address(token), OPEN, CONTINUE, 1 days, 2 days);
        bytes32 id = _open();
        _recordCallback(pristine, id, 0); // first completion: no zero resultHash or lastDone slot
        vm.warp(tracker.nextUpdateAt());
        id = _update(); // refused update
        _recordCallback(pristine, id, 1);
        vm.warp(tracker.nextUpdateAt());
        id = _update(); // failed update
        _recordCallback(pristine, id, 2);
        id = _open(); // refused open
        _recordCallback(pristine, id, 1);
        id = _open(); // failed open
        _recordCallback(pristine, id, 2);
        vm.prank(owner); // refused recovery
        id = tracker.recover(PARENT);
        _recordCallback(pristine, id, 1);
        vm.prank(owner); // failed recovery
        id = tracker.recover(PARENT);
        _recordCallback(pristine, id, 2);
        vm.prank(owner); // recovered result
        id = tracker.recover(PARENT);
        _recordCallback(pristine, id, 0);
    }

    function _recordCallback(BurnTracker pristine, bytes32 id, uint8 resultStatus) private {
        vm.cool(address(tracker));
        vm.startStateDiffRecording();
        if (resultStatus == 0) _complete(id, keccak256(PROOF));
        else _fail(id, resultStatus);
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
        uint256 writes;
        for (uint256 i; i < accesses.length; ++i) {
            for (uint256 j; j < accesses[i].storageAccesses.length; ++j) {
                Vm.StorageAccess memory a = accesses[i].storageAccesses[j];
                if (a.account != address(tracker) || !a.isWrite) continue;
                ++writes;
                assertTrue(a.previousValue != 0, "callback creates a storage slot");
                assertTrue(a.newValue != 0, "callback clears a storage slot");
                assertTrue(vm.load(address(pristine), a.slot) != 0, "not initialized by constructor");
            }
        }
        assertGt(writes, 0);
        uint256 used = intake.callbackGas();
        assertLt(used, 200_000);
        emit log_named_uint(resultStatus == 0 ? "result callback gas" : "failure callback gas", used);
    }

    function _uuid(bytes16 entropy) private pure returns (bytes memory id) {
        id = new bytes(36);
        bytes16 alphabet = "0123456789abcdef";
        uint256 j;
        for (uint256 i; i < 36; ++i) {
            if (i == 8 || i == 13 || i == 18 || i == 23) {
                id[i] = "-";
            } else {
                uint8 b = uint8(entropy[j / 2]);
                id[i] = alphabet[j % 2 == 0 ? b >> 4 : b & 15];
                ++j;
            }
        }
    }
}
