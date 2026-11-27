// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BlueskyVerifier} from "./BlueskyVerifier.sol";
import {CBOR} from "./CBOR.sol";

/// @notice Maps a verified profile to ENS records. Mirrors src/records.ts.
library BlueskyRecords {
    error UnsupportedResolverProfile(bytes4 selector);

    bytes4 constant ADDR = 0x3b3b57de; // addr(bytes32)
    bytes4 constant ADDR_COIN = 0xf1cb7e06; // addr(bytes32,uint256)
    bytes4 constant TEXT = 0x59d1d43c; // text(bytes32,string)
    bytes4 constant MULTICALL = 0xac9650d8; // multicall(bytes[])

    uint256 constant COIN_ETH = 60;
    uint256 constant COIN_DEFAULT_EVM = 0x80000000; // ENSIP-19 default EVM address
    uint256 constant COIN_BASE = 0x80000000 | 8453; // ENSIP-11: 0x80000000 | chainId
    uint256 constant COIN_ARBITRUM = 0x80000000 | 42161;

    bytes constant DEFAULT_SUFFIX = "?default";

    bytes constant AVATAR_CDN = "https://cdn.bsky.app/img/avatar/plain/";

    /// @notice answers a record call, or `multicall(bytes[])` of record calls.
    /// Multicall follows ENS resolve-multicall: returns `abi.encode(bytes[])` where each result is the
    /// ABI-encoded answer, or the call's revert data padded to `length % 32 == 4`. Nested multicalls fail.
    function answer(BlueskyVerifier.Profile memory p, bytes memory data) internal pure returns (bytes memory) {
        if (bytes4(data) == MULTICALL) {
            bytes[] memory calls = abi.decode(_args(data), (bytes[]));
            bytes[] memory results = new bytes[](calls.length);
            for (uint256 i; i < calls.length; i++) {
                (bool ok, bytes memory v) = _answer(p, calls[i]);
                results[i] = ok ? v : _padError(v);
            }
            return abi.encode(results);
        }
        (bool ok, bytes memory v) = _answer(p, data);
        if (!ok) {
            assembly {
                revert(add(v, 32), mload(v))
            }
        }
        return v;
    }

    /// @return ok, and the ABI-encoded answer (or revert data)
    function _answer(BlueskyVerifier.Profile memory p, bytes memory data) private pure returns (bool, bytes memory) {
        bytes4 selector = bytes4(data);
        if (selector == ADDR && data.length >= 36) {
            (bool ok, address a) = addr(p, COIN_ETH);
            return (true, abi.encode(ok ? a : address(0)));
        } else if (selector == ADDR_COIN && data.length >= 68) {
            (, uint256 coinType) = abi.decode(_args(data), (bytes32, uint256));
            (bool ok, address a) = addr(p, coinType);
            return (true, abi.encode(ok ? abi.encodePacked(a) : bytes("")));
        } else if (selector == TEXT && data.length >= 100) {
            (, string memory key) = abi.decode(_args(data), (bytes32, string));
            return (true, abi.encode(string(text(p, bytes(key)))));
        }
        return (false, abi.encodeWithSelector(UnsupportedResolverProfile.selector, selector));
    }

    /// @notice pads revert data to `length % 32 == 4` so it can't be mistaken for an ABI-encoded answer
    function _padError(bytes memory v) private pure returns (bytes memory) {
        unchecked {
            uint256 pad = (4 - v.length) & 31;
            return pad == 0 ? v : bytes.concat(v, new bytes(pad));
        }
    }

    function _args(bytes memory data) private pure returns (bytes memory) {
        return CBOR.slice(data, 4, data.length - 4);
    }

    // addr

    struct Explorer {
        bytes prefix;
        uint256 coinType;
    }

    /// @notice block explorers whose address pages map to a coin type
    function _explorers() private pure returns (Explorer[3] memory) {
        return [
            Explorer("https://etherscan.io/address/", COIN_ETH),
            Explorer("https://basescan.org/address/", COIN_BASE),
            Explorer("https://arbiscan.io/address/", COIN_ARBITRUM)
        ];
    }

    /// @notice address for `coinType` from the first matching explorer link, in profile order.
    /// `COIN_DEFAULT_EVM` comes only from a link marked `?default`; there is no fallback between coin types.
    function addr(BlueskyVerifier.Profile memory p, uint256 coinType) internal pure returns (bool, address) {
        for (uint256 i; i < p.links.length; i++) {
            (bool ok, uint256 linkCoin, bool isDefault, address a) = _addressLink(p.links[i].url);
            if (ok && (coinType == COIN_DEFAULT_EVM ? isDefault : linkCoin == coinType)) return (true, a);
        }
        return (false, address(0));
    }

    /// @notice parses "{explorer}/address/0x<40 hex>" with an optional "?default" suffix
    /// @return ok, the explorer's coin type, whether it's marked default, and the address
    function _addressLink(bytes memory url) private pure returns (bool, uint256, bool, address) {
        Explorer[3] memory explorers = _explorers();
        for (uint256 i; i < explorers.length; i++) {
            bytes memory prefix = explorers[i].prefix;
            if (url.length < prefix.length + 42 || !CBOR.eqAt(url, 0, prefix.length, prefix)) continue;
            uint256 rest = url.length - prefix.length;
            bool isDefault;
            if (rest == 42 + DEFAULT_SUFFIX.length && CBOR.eqAt(url, prefix.length + 42, DEFAULT_SUFFIX.length, DEFAULT_SUFFIX)) {
                isDefault = true;
            } else if (rest != 42) {
                continue;
            }
            (bool ok, address a) = _parseAddr(url, prefix.length);
            if (ok) return (true, explorers[i].coinType, isDefault, a);
        }
        return (false, 0, false, address(0));
    }

    /// @notice parses "0x" + 40 hex at `p`
    function _parseAddr(bytes memory s, uint256 p) private pure returns (bool, address) {
        if (p + 42 > s.length || s[p] != "0" || s[p + 1] != "x") return (false, address(0));
        uint160 v;
        for (uint256 i = p + 2; i < p + 42; i++) {
            uint8 c = uint8(s[i]);
            uint8 d;
            if (c >= 0x30 && c <= 0x39) d = c - 0x30;
            else if (c >= 0x61 && c <= 0x66) d = c - 0x61 + 10;
            else if (c >= 0x41 && c <= 0x46) d = c - 0x41 + 10;
            else return (false, address(0));
            v = (v << 4) | d;
        }
        return (true, address(v));
    }

    // text

    struct Social {
        bytes prefix;
        bytes key;
    }

    function _socials() private pure returns (Social[3] memory) {
        return [
            Social("https://github.com/", "com.github"),
            Social("https://x.com/", "com.twitter"),
            Social("https://twitter.com/", "com.twitter")
        ];
    }

    function text(BlueskyVerifier.Profile memory p, bytes memory key) internal pure returns (bytes memory) {
        bytes32 k = keccak256(key);
        if (k == keccak256("name")) return p.displayName;
        if (k == keccak256("description")) return p.description;
        if (k == keccak256("avatar")) {
            return p.avatarCid.length > 0 ? bytes.concat(AVATAR_CDN, p.did, "/", p.avatarCid, "@jpeg") : bytes("");
        }
        if (k == keccak256("url")) {
            for (uint256 i; i < p.links.length; i++) {
                (bool isAddr,,,) = _addressLink(p.links[i].url);
                (bool isSocial,,) = _social(p.links[i].url);
                if (!isAddr && !isSocial) return p.links[i].url;
            }
            return "";
        }
        for (uint256 i; i < p.links.length; i++) {
            (bool ok, bytes memory sk, bytes memory value) = _social(p.links[i].url);
            if (ok && keccak256(sk) == k) return value;
        }
        return "";
    }

    /// @notice returns (ok, record key, first path segment after the site prefix)
    function _social(bytes memory url) private pure returns (bool, bytes memory, bytes memory) {
        Social[3] memory socials = _socials();
        for (uint256 i; i < socials.length; i++) {
            bytes memory prefix = socials[i].prefix;
            if (url.length <= prefix.length || !CBOR.eqAt(url, 0, prefix.length, prefix)) continue;
            uint256 end = prefix.length;
            while (end < url.length && url[end] != "/" && url[end] != "?" && url[end] != "#") end++;
            if (end == prefix.length) continue;
            return (true, socials[i].key, CBOR.slice(url, prefix.length, end - prefix.length));
        }
        return (false, "", "");
    }
}
