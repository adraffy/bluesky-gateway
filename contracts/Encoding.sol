// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice base32 (RFC 4648 lower, no padding), base64url, CID strings, and atproto TIDs.
library Encoding {
    error InvalidEncoding(uint256 pos);

    bytes constant B32 = "abcdefghijklmnopqrstuvwxyz234567";

    /// @notice atproto TID -> microseconds since the unix epoch.
    /// A TID is a 64-bit integer (top bit 0, then 53 bits of microseconds, then a 10-bit clock id)
    /// written as 13 chars of base32-sortable ("234567abcdefghijklmnopqrstuvwxyz").
    function tidMicros(bytes memory tid) internal pure returns (uint256) {
        if (tid.length != 13) revert InvalidEncoding(tid.length);
        uint256 n;
        for (uint256 i; i < 13; i++) {
            uint8 c = uint8(tid[i]);
            uint256 v;
            if (c >= 0x32 && c <= 0x37) v = c - 0x32; // 2-7
            else if (c >= 0x61 && c <= 0x7a) v = c - 0x61 + 6; // a-z
            else revert InvalidEncoding(i);
            n = (n << 5) | v;
        }
        // 13 * 5 = 65 bits: the padding bit and the integer's top bit must both be 0
        if (n >> 63 != 0) revert InvalidEncoding(0);
        return n >> 10;
    }

    function base32(bytes memory data) internal pure returns (bytes memory out) {
        out = new bytes((data.length * 8 + 4) / 5);
        uint256 buf;
        uint256 bits;
        uint256 j;
        for (uint256 i; i < data.length; i++) {
            buf = (buf << 8) | uint8(data[i]);
            bits += 8;
            while (bits >= 5) {
                bits -= 5;
                out[j++] = B32[(buf >> bits) & 31];
            }
            buf &= (1 << bits) - 1;
        }
        if (bits > 0) out[j] = B32[(buf << (5 - bits)) & 31];
    }

    /// @notice multibase string of a CIDv1 with sha2-256: "b" + base32(0x01 codec 0x12 0x20 digest)
    function cidString(uint8 codec, bytes32 digest) internal pure returns (bytes memory) {
        return bytes.concat("b", base32(abi.encodePacked(uint8(0x01), codec, uint8(0x12), uint8(0x20), digest)));
    }

    function base64url(bytes memory s) internal pure returns (bytes memory out) {
        out = new bytes((s.length * 6) / 8);
        uint256 buf;
        uint256 bits;
        uint256 j;
        for (uint256 i; i < s.length; i++) {
            uint8 c = uint8(s[i]);
            uint256 v;
            if (c >= 0x41 && c <= 0x5a) v = c - 0x41; // A-Z
            else if (c >= 0x61 && c <= 0x7a) v = c - 0x61 + 26; // a-z
            else if (c >= 0x30 && c <= 0x39) v = c - 0x30 + 52; // 0-9
            else if (c == 0x2d) v = 62; // -
            else if (c == 0x5f) v = 63; // _
            else revert InvalidEncoding(i);
            buf = (buf << 6) | v;
            bits += 6;
            if (bits >= 8) {
                bits -= 8;
                out[j++] = bytes1(uint8(buf >> bits));
                buf &= (1 << bits) - 1;
            }
        }
    }
}
