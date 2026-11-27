// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {CBOR} from "./CBOR.sol";
import {Encoding} from "./Encoding.sol";
import {Secp256k1} from "./Secp256k1.sol";

/// @notice Verifies an atproto profile proof without a trusted gateway:
/// anchor did:plc chain -> trusted PLC signers
/// user did:plc chain (latest op signed by a trusted signer, claims the handle) -> signing key
/// -> signed repo commit -> MST -> profile + link records.
library BlueskyVerifier {
    error InvalidPLC(uint256 op);
    error InvalidCommit();
    error HandleNotClaimed();
    error InvalidAnchor();
    error UntrustedPLCSigner(address signer);
    error MissingNode(bytes32 digest);
    error ProfileNotInCommit();
    error StaleCommit(uint256 time);

    struct Proof {
        bytes[] anchor; // signed PLC ops of the anchor DID (eg. bsky.app), genesis -> latest
        bytes[] ops; // signed PLC ops (DAG-CBOR), genesis -> latest
        bytes commit; // signed repo commit (DAG-CBOR)
        bytes[] nodes; // MST nodes (DAG-CBOR)
        bytes profile; // app.bsky.actor.profile/self
        bytes[] links; // app.bsky.actor.link records
    }

    struct Link {
        bytes url;
        bytes title;
    }

    struct Profile {
        bytes did;
        bytes displayName;
        bytes description;
        bytes avatarCid; // multibase CID string of the avatar blob, or empty
        Link[] links; // verified links, in profile order
        uint256 time; // commit time (seconds), from the signed `rev`
    }

    bytes constant PROFILE_KEY = "app.bsky.actor.profile/self";
    bytes constant LINK_COLLECTION = "app.bsky.actor.link/";
    uint8 constant CODEC_DAG_CBOR = 0x71;
    uint8 constant CODEC_RAW = 0x55;

    /// @param anchorDid DID whose latest rotation keys are the trusted PLC signers (eg. bsky.app)
    /// @param maxAge reject commits older than this many seconds (0 = no limit)
    function verify(bytes memory handle, bytes memory anchorDid, uint256 maxAge, Proof memory proof)
        internal
        view
        returns (Profile memory p)
    {
        (bytes memory did, address[] memory trusted,) = verifyPLC(proof.anchor);
        if (keccak256(did) != keccak256(anchorDid)) revert InvalidAnchor();
        address lastSigner;
        (p.did,, lastSigner) = verifyPLC(proof.ops);
        if (!_contains(trusted, lastSigner)) revert UntrustedPLCSigner(lastSigner);
        address signingKey = verifyIdentity(handle, proof.ops[proof.ops.length - 1]);
        bytes32 root;
        (root, p.time) = verifyCommit(proof.commit, p.did, signingKey);
        // future times are allowed: `rev` comes from the PDS clock, which may run ahead of the block
        if (maxAge != 0 && p.time + maxAge < block.timestamp) revert StaleCommit(p.time);

        bytes32[] memory digests = new bytes32[](proof.nodes.length);
        for (uint256 i; i < digests.length; i++) {
            digests[i] = sha256(proof.nodes[i]);
        }
        (bool found, bytes32 v) = mstGet(proof.nodes, digests, root, PROFILE_KEY);
        if (!found || v != sha256(proof.profile)) revert ProfileNotInCommit();

        bytes memory profile = proof.profile;
        CBOR.requireSingle(profile);
        p.displayName = CBOR.optText(profile, 0, "displayName");
        p.description = CBOR.optText(profile, 0, "description");
        (found, v) = _avatar(profile);
        if (found) p.avatarCid = Encoding.cidString(CODEC_RAW, v);
        p.links = _links(p.did, profile, proof, digests, root);
    }

    // PLC

    /// @notice verifies an op chain from genesis
    /// @return did derived from the genesis op
    /// @return rotation rotation keys of the latest op
    /// @return lastSigner rotation key that signed the latest op
    function verifyPLC(bytes[] memory ops)
        internal
        view
        returns (bytes memory did, address[] memory rotation, address lastSigner)
    {
        if (ops.length == 0) revert InvalidPLC(0);
        did = bytes.concat("did:plc:", CBOR.slice(Encoding.base32(abi.encodePacked(sha256(ops[0]))), 0, 24));
        rotation = _rotationKeys(ops[0]); // the genesis op is signed by its own rotation keys
        for (uint256 i; i < ops.length; i++) {
            bytes memory op = ops[i];
            CBOR.requireSingle(op);
            if (keccak256(CBOR.readText(op, CBOR.mustGet(op, 0, "type"))) != keccak256("plc_operation")) {
                revert InvalidPLC(i);
            }
            uint256 prev = CBOR.mustGet(op, 0, "prev");
            if (i == 0) {
                if (!CBOR.isNull(op, prev)) revert InvalidPLC(i);
            } else if (keccak256(CBOR.readText(op, prev)) != keccak256(Encoding.cidString(CODEC_DAG_CBOR, sha256(ops[i - 1])))) {
                revert InvalidPLC(i);
            }
            bytes memory sig = Encoding.base64url(CBOR.readText(op, CBOR.mustGet(op, 0, "sig")));
            bytes32 digest = sha256(CBOR.without(op, "sig"));
            lastSigner = _findSigner(digest, sig, rotation);
            if (lastSigner == address(0)) revert InvalidPLC(i);
            if (i > 0) rotation = _rotationKeys(op); // op 0's keys were decoded before the loop
        }
    }

    /// @notice the op claims `at://{handle}`; returns its repo signing key
    function verifyIdentity(bytes memory handle, bytes memory op) internal view returns (address) {
        if (!_hasText(op, CBOR.mustGet(op, 0, "alsoKnownAs"), bytes.concat("at://", handle))) {
            revert HandleNotClaimed();
        }
        uint256 vm = CBOR.mustGet(op, 0, "verificationMethods");
        return Secp256k1.didKeyToAddress(CBOR.readText(op, CBOR.mustGet(op, vm, "atproto")));
    }

    function _rotationKeys(bytes memory op) private view returns (address[] memory keys) {
        (uint256 n, uint256 q) = CBOR.readArray(op, CBOR.mustGet(op, 0, "rotationKeys"));
        keys = new address[](n);
        for (uint256 i; i < n; i++) {
            keys[i] = Secp256k1.didKeyToAddress(CBOR.readText(op, q));
            q = CBOR.skip(op, q);
        }
    }

    function _findSigner(bytes32 digest, bytes memory sig, address[] memory keys) private pure returns (address) {
        (address a, address b) = Secp256k1.recover(digest, sig);
        for (uint256 i; i < keys.length; i++) {
            address k = keys[i];
            if (k != address(0) && (k == a || k == b)) return k;
        }
        return address(0);
    }

    function _contains(address[] memory keys, address key) private pure returns (bool) {
        for (uint256 i; i < keys.length; i++) {
            if (keys[i] == key) return true;
        }
        return false;
    }

    function _hasText(bytes memory b, uint256 p, bytes memory value) private pure returns (bool) {
        (uint256 n, uint256 q) = CBOR.readArray(b, p);
        bytes32 h = keccak256(value);
        for (uint256 i; i < n; i++) {
            if (keccak256(CBOR.readText(b, q)) == h) return true;
            q = CBOR.skip(b, q);
        }
        return false;
    }

    // commit

    /// @return root MST root digest
    /// @return time commit time in seconds, from its signed `rev` (a TID)
    function verifyCommit(bytes memory commit, bytes memory did, address signer)
        internal
        pure
        returns (bytes32 root, uint256 time)
    {
        CBOR.requireSingle(commit);
        time = Encoding.tidMicros(CBOR.readText(commit, CBOR.mustGet(commit, 0, "rev"))) / 1e6;
        if (keccak256(CBOR.readText(commit, CBOR.mustGet(commit, 0, "did"))) != keccak256(did)) revert InvalidCommit();
        if (CBOR.readUint(commit, CBOR.mustGet(commit, 0, "version")) != 3) revert InvalidCommit();
        uint8 codec;
        (codec, root) = CBOR.readCID(commit, CBOR.mustGet(commit, 0, "data"));
        if (codec != CODEC_DAG_CBOR) revert InvalidCommit();
        bytes memory sig = CBOR.readBytes(commit, CBOR.mustGet(commit, 0, "sig"));
        if (!Secp256k1.verify(sha256(CBOR.without(commit, "sig")), sig, signer)) revert InvalidCommit();
    }

    // MST

    /// @notice looks up `key`; (false, 0) means provably absent from the tree at `root`
    function mstGet(bytes[] memory nodes, bytes32[] memory digests, bytes32 root, bytes memory key)
        internal
        pure
        returns (bool, bytes32)
    {
        bytes32 cur = root;
        bool has = true;
        while (has) {
            bytes memory node = nodes[_findNode(digests, cur)];
            (has, cur) = CBOR.readOptCID(node, CBOR.mustGet(node, 0, "l"));
            (uint256 n, uint256 q) = CBOR.readArray(node, CBOR.mustGet(node, 0, "e"));
            bytes memory prev;
            for (uint256 i; i < n; i++) {
                uint256 pre = CBOR.readUint(node, CBOR.mustGet(node, q, "p"));
                if (pre > prev.length) revert CBOR.CBORInvalid(q);
                prev = bytes.concat(CBOR.slice(prev, 0, pre), CBOR.readBytes(node, CBOR.mustGet(node, q, "k")));
                int256 c = _compare(prev, key);
                if (c == 0) {
                    (uint8 codec, bytes32 value) = CBOR.readCID(node, CBOR.mustGet(node, q, "v"));
                    if (codec != CODEC_DAG_CBOR) revert CBOR.CBORInvalid(q);
                    return (true, value);
                }
                if (c > 0) break;
                (has, cur) = CBOR.readOptCID(node, CBOR.mustGet(node, q, "t"));
                q = CBOR.skip(node, q);
            }
        }
        return (false, 0);
    }

    function _findNode(bytes32[] memory digests, bytes32 digest) private pure returns (uint256) {
        for (uint256 i; i < digests.length; i++) {
            if (digests[i] == digest) return i;
        }
        revert MissingNode(digest);
    }

    function _compare(bytes memory a, bytes memory b) private pure returns (int256) {
        uint256 n = a.length < b.length ? a.length : b.length;
        for (uint256 i; i < n; i++) {
            if (a[i] != b[i]) return uint8(a[i]) < uint8(b[i]) ? -1 : int256(1);
        }
        return a.length == b.length ? int256(0) : a.length < b.length ? -1 : int256(1);
    }

    // records

    function _avatar(bytes memory profile) private pure returns (bool, bytes32 digest) {
        (bool found, uint256 p) = CBOR.get(profile, 0, "avatar");
        if (!found) return (false, 0);
        uint8 codec;
        (codec, digest) = CBOR.readCID(profile, CBOR.mustGet(profile, p, "ref"));
        return (codec == CODEC_RAW, digest);
    }

    function _links(bytes memory did, bytes memory profile, Proof memory proof, bytes32[] memory digests, bytes32 root)
        private
        pure
        returns (Link[] memory links)
    {
        (bool found, uint256 p) = CBOR.get(profile, 0, "links");
        if (!found || proof.links.length == 0) return links;
        bytes32[] memory cids = new bytes32[](proof.links.length); // keccak of CID strings
        for (uint256 i; i < cids.length; i++) {
            cids[i] = keccak256(Encoding.cidString(CODEC_DAG_CBOR, sha256(proof.links[i])));
        }
        bytes memory prefix = bytes.concat("at://", did, "/", LINK_COLLECTION);
        (uint256 n, uint256 q) = CBOR.readArray(profile, p);
        links = new Link[](n);
        uint256 count;
        for (uint256 i; i < n; i++) {
            bytes32 ref = keccak256(CBOR.readText(profile, CBOR.mustGet(profile, q, "cid")));
            bytes memory uri = CBOR.readText(profile, CBOR.mustGet(profile, q, "uri"));
            q = CBOR.skip(profile, q);
            uint256 j;
            while (j < cids.length && cids[j] != ref) j++;
            if (j == cids.length) continue; // not provided
            if (uri.length <= prefix.length || !CBOR.eqAt(uri, 0, prefix.length, prefix)) continue;
            bytes memory key = bytes.concat(LINK_COLLECTION, CBOR.slice(uri, prefix.length, uri.length - prefix.length));
            (bool ok, bytes32 v) = mstGet(proof.nodes, digests, root, key);
            if (!ok || v != sha256(proof.links[j])) continue; // stale ref
            bytes memory link = proof.links[j];
            CBOR.requireSingle(link);
            links[count++] = Link(CBOR.readText(link, CBOR.mustGet(link, 0, "url")), CBOR.optText(link, 0, "title"));
        }
        assembly {
            mstore(links, count)
        }
    }
}
