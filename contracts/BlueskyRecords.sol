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

    uint256 constant COIN_ETH = 60;
    uint256 constant COIN_DEFAULT_EVM = 0x80000000;

    bytes constant AVATAR_CDN = "https://cdn.bsky.app/img/avatar/plain/";

    function answer(BlueskyVerifier.Profile memory p, bytes memory data) internal pure returns (bytes memory) {
        bytes4 selector = bytes4(data);
        if (selector == ADDR) {
            (bool ok, address a) = ethAddress(p);
            return abi.encode(ok ? a : address(0));
        } else if (selector == ADDR_COIN) {
            (, uint256 coinType) = abi.decode(_args(data), (bytes32, uint256));
            if (coinType != COIN_ETH && coinType != COIN_DEFAULT_EVM) return abi.encode(bytes(""));
            (bool ok, address a) = ethAddress(p);
            return abi.encode(ok ? abi.encodePacked(a) : bytes(""));
        } else if (selector == TEXT) {
            (, string memory key) = abi.decode(_args(data), (bytes32, string));
            return abi.encode(string(text(p, bytes(key))));
        }
        revert UnsupportedResolverProfile(selector);
    }

    function _args(bytes memory data) private pure returns (bytes memory) {
        return CBOR.slice(data, 4, data.length - 4);
    }

    // addr

    /// @notice first link titled "eth" ending in "/0x<40 hex>", else "eth:0x<40 hex>" in the bio
    function ethAddress(BlueskyVerifier.Profile memory p) internal pure returns (bool, address) {
        for (uint256 i; i < p.links.length; i++) {
            (bool ok, address a) = _linkAddr(p.links[i]);
            if (ok) return (true, a);
        }
        return _bioAddr(p.description);
    }

    function _linkAddr(BlueskyVerifier.Link memory link) private pure returns (bool, address) {
        bytes memory url = link.url;
        if (keccak256(link.title) != keccak256("eth") || url.length <= 42 || url[url.length - 43] != "/") {
            return (false, address(0));
        }
        return _parseAddr(url, url.length - 42);
    }

    function _bioAddr(bytes memory bio) private pure returns (bool, address) {
        bytes memory tag = "eth:";
        for (uint256 i; i + 46 <= bio.length; i++) {
            if (i > 0 && !_isSpace(bio[i - 1])) continue;
            if (!CBOR.eqAt(bio, i, 4, tag)) continue;
            if (i + 46 < bio.length && !_isSpace(bio[i + 46])) continue;
            (bool ok, address a) = _parseAddr(bio, i + 4);
            if (ok) return (true, a);
        }
        return (false, address(0));
    }

    function _isSpace(bytes1 c) private pure returns (bool) {
        return c == " " || c == "\t" || c == "\r" || c == "\n";
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
                (bool isAddr,) = _linkAddr(p.links[i]);
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
