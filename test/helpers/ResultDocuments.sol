// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev Test inputs are constructed from a known UUID, not extracted with the implementation's scanner.
library ResultDocuments {
    function uuid(bytes16 entropy) internal pure returns (bytes memory id) {
        bytes memory hexId = bytes.concat(_hex(entropy));
        id = new bytes(36);
        uint256 digit;
        for (uint256 i; i < id.length; ++i) {
            if (i == 8 || i == 13 || i == 18 || i == 23) id[i] = "-";
            else id[i] = hexId[digit++];
        }
    }

    function _hex(bytes16 entropy) private pure returns (bytes32 text) {
        bytes16 alphabet = "0123456789abcdef";
        bytes memory encoded = new bytes(32);
        for (uint256 i; i < 16; ++i) {
            encoded[2 * i] = alphabet[uint8(entropy[i]) >> 4];
            encoded[2 * i + 1] = alphabet[uint8(entropy[i]) & 15];
        }
        assembly ("memory-safe") { text := mload(add(encoded, 32)) }
    }

    function proof(bytes16 entropy) internal pure returns (bytes memory) {
        return bytes.concat('{"jobId":"', uuid(entropy), '","state":"completed"}');
    }

    function repeat(bytes1 character, uint256 length) internal pure returns (bytes memory text) {
        text = new bytes(length);
        for (uint256 i; i < length; ++i) {
            text[i] = character;
        }
    }
}
