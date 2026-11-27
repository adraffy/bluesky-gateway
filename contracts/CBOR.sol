// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Minimal DAG-CBOR reader over memory bytes (offset based).
/// Positions are byte offsets into `b`. All reads are bounds checked.
library CBOR {
    error CBORInvalid(uint256 pos);
    error CBORMissing(bytes key);

    uint8 constant MAJOR_UINT = 0;
    uint8 constant MAJOR_BYTES = 2;
    uint8 constant MAJOR_TEXT = 3;
    uint8 constant MAJOR_ARRAY = 4;
    uint8 constant MAJOR_MAP = 5;
    uint8 constant MAJOR_TAG = 6;
    uint8 constant NULL = 0xf6;
    uint256 constant TAG_CID = 42;

    function header(bytes memory b, uint256 p) internal pure returns (uint8 major, uint256 arg, uint256 q) {
        uint8 x = uint8(b[p]);
        major = x >> 5;
        uint8 info = x & 31;
        if (info < 24) return (major, info, p + 1);
        uint256 n;
        if (info == 24) n = 1;
        else if (info == 25) n = 2;
        else if (info == 26) n = 4;
        else if (info == 27) n = 8;
        else revert CBORInvalid(p);
        q = p + 1;
        for (uint256 i; i < n; i++) {
            arg = (arg << 8) | uint8(b[q + i]);
        }
        q += n;
    }

    /// @notice returns the position after the item at `p`
    function skip(bytes memory b, uint256 p) internal pure returns (uint256 q) {
        uint8 major;
        uint256 arg;
        (major, arg, q) = header(b, p);
        if (major == MAJOR_BYTES || major == MAJOR_TEXT) {
            q += arg;
            if (q > b.length) revert CBORInvalid(p);
        } else if (major == MAJOR_ARRAY) {
            for (uint256 i; i < arg; i++) q = skip(b, q);
        } else if (major == MAJOR_MAP) {
            for (uint256 i; i < arg << 1; i++) q = skip(b, q);
        } else if (major == MAJOR_TAG) {
            q = skip(b, q);
        }
    }

    /// @notice requires `b` to be exactly one CBOR item
    function requireSingle(bytes memory b) internal pure {
        if (b.length == 0 || skip(b, 0) != b.length) revert CBORInvalid(0);
    }

    /// @notice returns (found, position of the value for `key`) in the map at `p`
    function get(bytes memory b, uint256 p, bytes memory key) internal pure returns (bool found, uint256 v) {
        (uint8 major, uint256 n, uint256 q) = header(b, p);
        if (major != MAJOR_MAP) revert CBORInvalid(p);
        for (uint256 i; i < n; i++) {
            (uint8 km, uint256 klen, uint256 kq) = header(b, q);
            if (km != MAJOR_TEXT) revert CBORInvalid(q);
            v = kq + klen;
            if (eqAt(b, kq, klen, key)) return (true, v);
            q = skip(b, v);
        }
        return (false, 0);
    }

    function mustGet(bytes memory b, uint256 p, bytes memory key) internal pure returns (uint256 v) {
        bool found;
        (found, v) = get(b, p, key);
        if (!found) revert CBORMissing(key);
    }

    function isNull(bytes memory b, uint256 p) internal pure returns (bool) {
        return uint8(b[p]) == NULL;
    }

    function readText(bytes memory b, uint256 p) internal pure returns (bytes memory) {
        (uint8 major, uint256 len, uint256 q) = header(b, p);
        if (major != MAJOR_TEXT) revert CBORInvalid(p);
        return slice(b, q, len);
    }

    function readBytes(bytes memory b, uint256 p) internal pure returns (bytes memory) {
        (uint8 major, uint256 len, uint256 q) = header(b, p);
        if (major != MAJOR_BYTES) revert CBORInvalid(p);
        return slice(b, q, len);
    }

    function readUint(bytes memory b, uint256 p) internal pure returns (uint256 v) {
        uint8 major;
        (major, v,) = header(b, p);
        if (major != MAJOR_UINT) revert CBORInvalid(p);
    }

    /// @notice returns (length, position of the first element)
    function readArray(bytes memory b, uint256 p) internal pure returns (uint256 n, uint256 q) {
        uint8 major;
        (major, n, q) = header(b, p);
        if (major != MAJOR_ARRAY) revert CBORInvalid(p);
    }

    /// @notice optional text field of the map at `p` (empty if absent)
    function optText(bytes memory b, uint256 p, bytes memory key) internal pure returns (bytes memory) {
        (bool found, uint256 v) = get(b, p, key);
        return found ? readText(b, v) : bytes("");
    }

    /// @notice CIDv1 link: tag 42 + bytes(0x00 0x01 <codec> 0x12 0x20 <sha256>)
    function readCID(bytes memory b, uint256 p) internal pure returns (uint8 codec, bytes32 digest) {
        (uint8 major, uint256 tag, uint256 q) = header(b, p);
        if (major != MAJOR_TAG || tag != TAG_CID) revert CBORInvalid(p);
        uint256 len;
        (major, len, q) = header(b, q);
        if (major != MAJOR_BYTES || len != 37) revert CBORInvalid(q);
        if (b[q] != 0x00 || b[q + 1] != 0x01 || b[q + 3] != 0x12 || b[q + 4] != 0x20) revert CBORInvalid(q);
        codec = uint8(b[q + 2]);
        digest = load32(b, q + 5);
    }

    /// @notice CID link or null
    function readOptCID(bytes memory b, uint256 p) internal pure returns (bool, bytes32 digest) {
        if (isNull(b, p)) return (false, 0);
        uint8 codec;
        (codec, digest) = readCID(b, p);
        if (codec != 0x71) revert CBORInvalid(p);
        return (true, digest);
    }

    /// @notice re-encodes the top-level map `b` without `key` (canonical DAG-CBOR stays canonical)
    function without(bytes memory b, bytes memory key) internal pure returns (bytes memory) {
        (uint8 major, uint256 n, uint256 q) = header(b, 0);
        if (major != MAJOR_MAP || n == 0) revert CBORInvalid(0);
        uint256 start = q;
        for (uint256 i; i < n; i++) {
            (uint8 km, uint256 klen, uint256 kq) = header(b, q);
            if (km != MAJOR_TEXT) revert CBORInvalid(q);
            uint256 end = skip(b, kq + klen);
            if (eqAt(b, kq, klen, key)) {
                return bytes.concat(encodeHeader(MAJOR_MAP, n - 1), slice(b, start, q - start), slice(b, end, b.length - end));
            }
            q = end;
        }
        revert CBORMissing(key);
    }

    function encodeHeader(uint8 major, uint256 n) internal pure returns (bytes memory) {
        uint8 m = major << 5;
        if (n < 24) return abi.encodePacked(m | uint8(n));
        if (n < 0x100) return abi.encodePacked(m | 24, uint8(n));
        if (n < 0x10000) return abi.encodePacked(m | 25, uint16(n));
        if (n < 0x100000000) return abi.encodePacked(m | 26, uint32(n));
        return abi.encodePacked(m | 27, uint64(n));
    }

    // memory helpers

    function slice(bytes memory b, uint256 start, uint256 len) internal pure returns (bytes memory r) {
        if (start + len > b.length) revert CBORInvalid(start);
        r = new bytes(len);
        assembly {
            mcopy(add(r, 32), add(add(b, 32), start), len)
        }
    }

    function load32(bytes memory b, uint256 p) internal pure returns (bytes32 v) {
        if (p + 32 > b.length) revert CBORInvalid(p);
        assembly {
            v := mload(add(add(b, 32), p))
        }
    }

    function eqAt(bytes memory b, uint256 start, uint256 len, bytes memory key) internal pure returns (bool) {
        if (len != key.length || start + len > b.length) return false;
        bytes32 h;
        assembly {
            h := keccak256(add(add(b, 32), start), len)
        }
        return h == keccak256(key);
    }
}
