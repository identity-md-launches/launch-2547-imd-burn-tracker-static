// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BurnTracker} from "src/BurnTracker.sol";
import {BurnTrackerFixture} from "./BurnTracker.t.sol";
import {ResultDocuments} from "./helpers/ResultDocuments.sol";

/// forge-config: default.fuzz.runs = 1000
contract ResultDocumentPropertiesTest is BurnTrackerFixture {
    /// @dev All generated documents have sorted object keys and exactly the measured byte length.
    /// JSON decoding is an independent oracle; expected UUIDs originate outside the contract parser.
    function testFuzzCanonicalProofsAtMeasuredSizesDriveExactContinuation(
        bytes16 entropy,
        uint16 lengthSeed,
        uint16 alignmentSeed,
        uint8 escapeSeed
    ) public {
        bytes memory id = ResultDocuments.uuid(entropy);
        bytes memory doc = _document(id, bound(lengthSeed, 750, 4545), alignmentSeed, escapeSeed);
        assertEq(bytes(vm.parseJsonString(string(doc), ".jobId")), id, "test generator produced invalid JSON");
        assertEq(tracker.parentJobIdOf(doc), id);
        _complete(_open(), keccak256(doc));
        vm.warp(tracker.nextUpdateAt());
        vm.prank(caller);
        bytes32 request = tracker.updateBurntracker(doc, PRICE);
        assertEq(intake.bodyHash(), keccak256(bytes.concat(tracker.bodyPrefix(), id, tracker.bodySuffix())));
        assertEq(tracker.lastRequestId(), request);
        assertEq(token.balanceOf(caller), 100 ether - PRICE);
        assertEq(token.balanceOf(address(tracker)), 0);
        assertEq(token.allowance(address(tracker), address(intake)), 0);
    }

    function testBothMeasuredEndpointsAcrossEveryWordAlignmentAndEscapeMode() public view {
        bytes memory id = bytes(PARENT);
        for (uint256 endpoint; endpoint < 2; ++endpoint) {
            uint256 length = endpoint == 0 ? 750 : 4545;
            for (uint16 alignment; alignment < 32; ++alignment) {
                for (uint8 mode; mode < 8; ++mode) {
                    bytes memory doc = _document(id, length, alignment, mode);
                    assertEq(doc.length, length);
                    assertEq(tracker.parentJobIdOf(doc), id);
                }
            }
        }
    }

    function testFuzzDuplicateKeysRejectAuthenticatedProofBeforePayment(
        bytes16 entropy,
        uint16 lengthSeed,
        bool nested,
        bool escapedValue
    ) public {
        bytes memory id = ResultDocuments.uuid(entropy);
        bytes memory filler = ResultDocuments.repeat("x", bound(lengthSeed, 750, 4000));
        bytes memory value = escapedValue ? bytes("\\\"jobId\\\":\\\"decoy\\\"") : bytes("jobId");
        bytes memory doc = nested
            ? bytes.concat('{"a":{"jobId":"', id, '"},"b":"', filler, value, '","jobId":"', id, '"}')
            : bytes.concat('{"a":"', filler, value, '","jobId":"', id, '","jobId":"', id, '"}');
        _complete(_open(), keccak256(doc));
        vm.warp(tracker.nextUpdateAt());
        vm.prank(caller);
        vm.expectRevert(BurnTracker.InvalidResultJson.selector);
        tracker.updateBurntracker(doc, PRICE);
        assertEq(intake.nonce(), 1);
        assertEq(token.balanceOf(caller), 100 ether);
        assertEq(_state(), 2);
    }

    function testFuzzEscapedDecoysWithoutAKeyCannotSpendEvenWithMatchingHash(uint16 paddingSeed, uint8 escapeSeed)
        public
    {
        bytes memory padding = ResultDocuments.repeat("j", bound(paddingSeed, 750, 4000));
        bytes memory doc = bytes.concat(
            '{"a":"',
            padding,
            _escaped(escapeSeed),
            '","files":[{"path":"\\\"jobId\\\":\\\"12345678-1234-4abc-8def-123456789abc\\\""}],"state":"completed"}'
        );
        // Parsing the unrelated state verifies the generator's quote/backslash pairing.
        assertEq(vm.parseJsonString(string(doc), ".state"), "completed");
        _complete(_open(), keccak256(doc));
        vm.warp(tracker.nextUpdateAt());
        vm.prank(caller);
        vm.expectRevert(BurnTracker.InvalidResultJson.selector);
        tracker.updateBurntracker(doc, PRICE);
        assertEq(token.balanceOf(caller), 100 ether);
        assertEq(intake.nonce(), 1);
        assertEq(_state(), 2);
    }

    function testFuzzMalformedUuidRejectedByBothEntryPoints(bytes16 entropy, uint8 positionSeed, uint8 badSeed) public {
        bytes memory id = ResultDocuments.uuid(entropy);
        uint256 position = bound(positionSeed, 0, 35);
        bool dash = position == 8 || position == 13 || position == 18 || position == 23;
        // Map directly into invalid byte sets instead of discarding inputs with assume().
        uint256 bad = bound(badSeed, 0, dash ? 254 : 239);
        if (dash) {
            if (bad >= 45) ++bad;
        } else {
            if (bad >= 48) bad += 10; // Exclude 0..9.
            if (bad >= 97) bad += 6; // Exclude a..f.
        }
        id[position] = bytes1(uint8(bad));
        bytes memory doc = bytes.concat('{"jobId":"', id, '","state":"completed"}');
        vm.expectRevert();
        tracker.parentJobIdOf(doc);
        _ready();
        vm.prank(owner);
        vm.expectRevert(BurnTracker.InvalidParentJobId.selector);
        tracker.recover(string(id));
        assertEq(intake.nonce(), 1);
        assertEq(token.balanceOf(owner), 100 ether - PRICE);
        assertEq(_state(), 2);
    }

    function testWrongUuidLengthsAtWordBoundariesRejected() public {
        uint256[9] memory lengths = [uint256(0), 1, 31, 32, 35, 37, 63, 64, 65];
        _ready();
        for (uint256 i; i < lengths.length; ++i) {
            bytes memory id = ResultDocuments.repeat("a", lengths[i]);
            vm.expectRevert();
            tracker.parentJobIdOf(bytes.concat('{"jobId":"', id, '"}'));
            vm.prank(owner);
            vm.expectRevert(BurnTracker.InvalidParentJobId.selector);
            tracker.recover(string(id));
        }
        assertEq(intake.nonce(), 1);
        assertEq(_state(), 2);
    }

    function testEquivalentJsonMeaningIsInsufficientWithoutExactHash() public {
        _ready();
        bytes memory equivalent = bytes(string.concat('{"state":"completed", "jobId":"', PARENT, '"}'));
        assertEq(vm.parseJsonString(string(equivalent), ".jobId"), PARENT);
        assertEq(vm.parseJsonString(string(equivalent), ".state"), "completed");
        vm.prank(caller);
        vm.expectRevert(BurnTracker.InvalidHash.selector);
        tracker.updateBurntracker(equivalent, PRICE);
        assertEq(token.balanceOf(caller), 100 ether);
        assertEq(intake.nonce(), 1);
        _update();
        assertEq(intake.nonce(), 2);
    }

    /// @dev Sorted, nested JSON with arbitrary string content on both sides of the sole jobId.
    function _document(bytes memory id, uint256 length, uint16 splitSeed, uint8 escapeSeed)
        private
        pure
        returns (bytes memory doc)
    {
        bytes memory escape = _escaped(escapeSeed);
        bytes memory head = '{"complete":true,"delivery":{"failure":"';
        bytes memory middle = bytes.concat(
            '"},"files":[{"path":"',
            escape,
            '"}],"jobId":"',
            id,
            '","launch":null,"projectId":"',
            id,
            '","source":[{"node":"'
        );
        bytes memory tail = '"}],"state":"completed"}';
        uint256 padding = length - head.length - middle.length - tail.length - escape.length;
        uint256 beforeId = uint256(splitSeed) % (padding + 1);
        doc = bytes.concat(
            head,
            ResultDocuments.repeat("j", beforeId),
            escape,
            middle,
            ResultDocuments.repeat("k", padding - beforeId),
            tail
        );
    }

    function _escaped(uint8 seed) private pure returns (bytes memory) {
        bytes[8] memory values = [
            bytes(""),
            bytes("\\\\"),
            bytes("\\\"jobId\\\":\\\"decoy\\\""),
            bytes("\\u006aobId"),
            bytes("\\b\\f\\n\\r\\t\\u0000"),
            bytes(unicode"雪 café € — jobId"),
            bytes("\\\\\\\""),
            bytes("jjkkjjkk]]{{::jobId")
        ];
        return values[seed % values.length];
    }
}
