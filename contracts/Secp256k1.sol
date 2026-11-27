// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {CBOR} from "./CBOR.sol";

/// @notice secp256k1 helpers for atproto: did:key -> address, and ECDSA over sha256.
library Secp256k1 {
    error UnsupportedKey(bytes didKey);

    uint256 constant P = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F;
    uint256 constant LIMB = 120; // base58 accumulator: 3 x 120-bit limbs (35-byte value fits in 280 bits)
    uint256 constant LIMB_MASK = (1 << LIMB) - 1;

    function _modexp(uint256 base, uint256 e, uint256 m) private view returns (uint256) {
        (bool ok, bytes memory out) = address(5).staticcall(abi.encode(32, 32, 32, base, e, m));
        require(ok && out.length == 32);
        return abi.decode(out, (uint256));
    }

    /// @notice compressed point (0x02/0x03 || x) -> ethereum address
    function compressedToAddress(uint8 prefix, uint256 x) internal view returns (address) {
        require(x < P && (prefix == 2 || prefix == 3));
        uint256 y2 = addmod(mulmod(mulmod(x, x, P), x, P), 7, P);
        uint256 y = _modexp(y2, (P + 1) >> 2, P);
        require(mulmod(y, y, P) == y2, "not on curve");
        if ((y & 1) != (prefix & 1)) y = P - y;
        return address(uint160(uint256(keccak256(abi.encode(x, y)))));
    }

    function _b58(uint8 c) private pure returns (uint256) {
        // 123456789 ABCDEFGH JKLMN PQRSTUVWXYZ abcdefghijk mnopqrstuvwxyz
        if (c >= 0x31 && c <= 0x39) return c - 0x31;
        if (c >= 0x41 && c <= 0x48) return c - 0x41 + 9;
        if (c >= 0x4a && c <= 0x4e) return c - 0x4a + 17;
        if (c >= 0x50 && c <= 0x5a) return c - 0x50 + 22;
        if (c >= 0x61 && c <= 0x6b) return c - 0x61 + 33;
        if (c >= 0x6d && c <= 0x7a) return c - 0x6d + 44;
        return type(uint256).max;
    }

    /// @notice "did:key:z<base58btc(0xe7 0x01 || compressed point)>" -> address
    function didKeyToAddress(bytes memory didKey) internal view returns (address) {
        bytes memory prefix = "did:key:z";
        if (didKey.length <= prefix.length || !CBOR.eqAt(didKey, 0, prefix.length, prefix)) revert UnsupportedKey(didKey);
        // base58 decode into V = l2 * 2^240 + l1 * 2^120 + l0, each limb < 2^120
        uint256 l0;
        uint256 l1;
        uint256 l2;
        for (uint256 i = prefix.length; i < didKey.length; i++) {
            uint256 v = _b58(uint8(didKey[i]));
            if (v == type(uint256).max) revert UnsupportedKey(didKey);
            l0 = l0 * 58 + v;
            l1 = l1 * 58 + (l0 >> LIMB);
            l2 = l2 * 58 + (l1 >> LIMB);
            l0 &= LIMB_MASK;
            l1 &= LIMB_MASK;
            if (l2 >> 40 != 0) revert UnsupportedKey(didKey); // more than 35 bytes
        }
        // V is 35 bytes: 0xe7 0x01 <0x02|0x03> || x (32 bytes)
        uint256 top = l2 >> 16; // V >> 256
        if (top >> 8 != 0xe701) revert UnsupportedKey(didKey);
        uint256 x;
        unchecked {
            x = ((l2 & 0xffff) << 240) | (l1 << LIMB) | l0;
        }
        return compressedToAddress(uint8(top), x);
    }

    /// @notice the two addresses that could have produced (r || s) over `digest`
    function recover(bytes32 digest, bytes memory sig) internal pure returns (address a, address b) {
        if (sig.length != 64) return (address(0), address(0));
        bytes32 r = CBOR.load32(sig, 0);
        bytes32 s = CBOR.load32(sig, 32);
        a = ecrecover(digest, 27, r, s);
        b = ecrecover(digest, 28, r, s);
    }

    /// @notice atproto ECDSA: signature (r || s) over sha256(message)
    function verify(bytes32 digest, bytes memory sig, address signer) internal pure returns (bool) {
        if (signer == address(0)) return false;
        (address a, address b) = recover(digest, sig);
        return a == signer || b == signer;
    }
}
