// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// Gas analysis: `forge test --match-contract Gas -vv`
// Prints a per-stage breakdown of verification and the cost of single vs multicall resolution.
// Numbers are execution gas inside eth_call (no intrinsic/calldata cost unless stated).

import {Test, console} from "forge-std/Test.sol";
import {BlueskyResolver, IBlueskyGateway} from "../../contracts/BlueskyResolver.sol";
import {BlueskyVerifier} from "../../contracts/BlueskyVerifier.sol";
import {BlueskyRecords} from "../../contracts/BlueskyRecords.sol";
import {Secp256k1} from "../../contracts/Secp256k1.sol";

contract GasHarness {
    struct Stages {
        uint256 anchor;
        uint256 account;
        uint256 identity;
        uint256 commit;
        uint256 profileMst;
        uint256 total;
    }

    function stages(bytes memory handle, bytes memory anchorDid, BlueskyVerifier.Proof memory proof)
        external
        view
        returns (Stages memory g)
    {
        uint256 t = gasleft();
        BlueskyVerifier.verifyPLC(proof.anchor);
        g.anchor = t - gasleft();

        t = gasleft();
        (bytes memory did,,) = BlueskyVerifier.verifyPLC(proof.ops);
        g.account = t - gasleft();

        t = gasleft();
        address key = BlueskyVerifier.verifyIdentity(handle, proof.ops[proof.ops.length - 1]);
        g.identity = t - gasleft();

        t = gasleft();
        (bytes32 root,) = BlueskyVerifier.verifyCommit(proof.commit, did, key);
        g.commit = t - gasleft();

        t = gasleft();
        bytes32[] memory digests = new bytes32[](proof.nodes.length);
        for (uint256 i; i < digests.length; i++) {
            digests[i] = sha256(proof.nodes[i]);
        }
        BlueskyVerifier.mstGet(proof.nodes, digests, root, "app.bsky.actor.profile/self");
        g.profileMst = t - gasleft();

        t = gasleft();
        BlueskyVerifier.verify(handle, anchorDid, 0, proof);
        g.total = t - gasleft();
    }

    function didKey(bytes memory key) external view returns (uint256 gas) {
        uint256 t = gasleft();
        Secp256k1.didKeyToAddress(key);
        gas = t - gasleft();
    }

    function answer(BlueskyVerifier.Profile memory p, bytes memory data) external view returns (uint256 gas) {
        uint256 t = gasleft();
        BlueskyRecords.answer(p, data);
        gas = t - gasleft();
    }

    function verify(bytes memory handle, bytes memory anchorDid, BlueskyVerifier.Proof memory proof)
        external
        view
        returns (BlueskyVerifier.Profile memory)
    {
        return BlueskyVerifier.verify(handle, anchorDid, 0, proof);
    }
}

contract GasTest is Test {
    bytes constant NAME = hex"07616472616666790462736b790365746800"; // adraffy.bsky.eth
    bytes constant HANDLE = "adraffy.bsky.social";

    string json;
    BlueskyResolver resolver;
    GasHarness harness;
    bytes anchorDid;

    function setUp() public {
        json = vm.readFile("test/fixtures/adraffy.bsky.social.json");
        anchorDid = bytes(vm.parseJsonString(json, ".anchorDid"));
        string[] memory urls = new string[](1);
        urls[0] = "http://localhost:8016";
        bytes32 parent = keccak256(abi.encode(keccak256(abi.encode(bytes32(0), keccak256("eth"))), keccak256("bsky")));
        resolver = new BlueskyResolver(urls, parent, anchorDid, 0);
        harness = new GasHarness();
    }

    function _proof() internal view returns (BlueskyVerifier.Proof memory p) {
        p.anchor = vm.parseJsonBytesArray(json, ".anchor");
        p.ops = vm.parseJsonBytesArray(json, ".ops");
        p.commit = vm.parseJsonBytes(json, ".commit");
        p.nodes = vm.parseJsonBytesArray(json, ".nodes");
        p.profile = vm.parseJsonBytes(json, ".profile");
        p.links = vm.parseJsonBytesArray(json, ".links");
    }

    function _response() internal view returns (bytes memory) {
        BlueskyVerifier.Proof memory p = _proof();
        return abi.encode(p.anchor, p.ops, p.commit, p.nodes, p.profile, p.links);
    }

    /// @dev calldata cost of an eth_call to resolveCallback (16/nonzero byte, 4/zero byte)
    function _calldataGas(bytes memory data) internal pure returns (uint256 g) {
        for (uint256 i; i < data.length; i++) {
            g += data[i] == 0 ? 4 : 16;
        }
    }

    function _callback(bytes memory data) internal view returns (uint256 gas, uint256 calldataGas) {
        bytes memory extra = abi.encode(HANDLE, data);
        bytes memory response = _response();
        calldataGas = _calldataGas(abi.encodeCall(BlueskyResolver.resolveCallback, (response, extra)));
        uint256 t = gasleft();
        resolver.resolveCallback(response, extra);
        gas = t - gasleft();
    }

    function _records(uint256 k) internal pure returns (bytes[] memory calls) {
        string[6] memory keys = ["avatar", "description", "name", "url", "com.github", "com.twitter"];
        calls = new bytes[](k);
        for (uint256 i; i < k; i++) {
            if (i == 0) calls[i] = abi.encodeWithSelector(BlueskyRecords.ADDR, bytes32(0));
            else if (i == 1) calls[i] = abi.encodeWithSelector(BlueskyRecords.ADDR_COIN, bytes32(0), uint256(60));
            else calls[i] = abi.encodeWithSelector(BlueskyRecords.TEXT, bytes32(0), keys[(i - 2) % keys.length]);
        }
    }

    function test_gas_breakdown() public view {
        BlueskyVerifier.Proof memory p = _proof();
        GasHarness.Stages memory g = harness.stages(HANDLE, anchorDid, p);
        uint256 rest = g.total - g.anchor - g.account - g.identity - g.commit - g.profileMst;
        console.log("== verification stages (execution gas)");
        console.log("anchor PLC chain (ops)       ", g.anchor, p.anchor.length);
        console.log("account PLC chain (ops)      ", g.account, p.ops.length);
        console.log("identity (handle + key)      ", g.identity);
        console.log("commit (sig + rev)           ", g.commit);
        console.log("MST profile lookup (nodes)   ", g.profileMst, p.nodes.length);
        console.log("profile + links (links)      ", rest, p.links.length);
        console.log("total verify                 ", g.total);
        console.log("one did:key -> address       ", harness.didKey("did:key:zQ3shpKnbdPx3g3CmPf5cRVTPe1HtSwVn5ish3wSnDPQCbLJK"));
        console.log("proof size (bytes)           ", _response().length);
    }

    function test_gas_records() public view {
        BlueskyVerifier.Profile memory prof = harness.verify(HANDLE, anchorDid, _proof());
        console.log("== answering one record (execution gas, after verification)");
        console.log("addr(node)                   ", harness.answer(prof, abi.encodeWithSelector(BlueskyRecords.ADDR, bytes32(0))));
        console.log("addr(node, 60)               ", harness.answer(prof, abi.encodeWithSelector(BlueskyRecords.ADDR_COIN, bytes32(0), uint256(60))));
        console.log("text(avatar)                 ", harness.answer(prof, abi.encodeWithSelector(BlueskyRecords.TEXT, bytes32(0), "avatar")));
        console.log("text(com.github)             ", harness.answer(prof, abi.encodeWithSelector(BlueskyRecords.TEXT, bytes32(0), "com.github")));
    }

    function test_gas_multicall() public view {
        (uint256 single, uint256 cd1) = _callback(abi.encodeWithSelector(BlueskyRecords.ADDR, bytes32(0)));
        console.log("== resolveCallback: k separate calls vs one multicall (execution gas)");
        console.log("single addr() callback       ", single);
        console.log("  + calldata gas             ", cd1);
        console.log("  + intrinsic                ", uint256(21000));
        uint256[5] memory ks = [uint256(1), 2, 4, 6, 8];
        for (uint256 i; i < ks.length; i++) {
            uint256 k = ks[i];
            bytes[] memory calls = _records(k);
            uint256 separate;
            for (uint256 j; j < k; j++) {
                (uint256 g,) = _callback(calls[j]);
                separate += g;
            }
            (uint256 multi,) = _callback(abi.encodeWithSelector(BlueskyRecords.MULTICALL, calls));
            console.log("k, separate, multicall       ", k, separate, multi);
        }
    }
}
