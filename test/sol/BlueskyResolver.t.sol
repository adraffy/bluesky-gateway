// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {BlueskyResolver, IBlueskyGateway} from "../../contracts/BlueskyResolver.sol";
import {BlueskyVerifier} from "../../contracts/BlueskyVerifier.sol";
import {BlueskyRecords} from "../../contracts/BlueskyRecords.sol";
import {Encoding} from "../../contracts/Encoding.sol";

contract VerifierHarness {
    bytes public anchorDid;
    uint256 public maxAge;

    constructor(bytes memory anchor, uint256 _maxAge) {
        anchorDid = anchor;
        maxAge = _maxAge;
    }

    function tid(bytes memory s) external pure returns (uint256) {
        return Encoding.tidMicros(s);
    }

    function verify(bytes memory handle, BlueskyVerifier.Proof memory proof)
        external
        view
        returns (BlueskyVerifier.Profile memory)
    {
        return BlueskyVerifier.verify(handle, anchorDid, maxAge, proof);
    }
}

contract BlueskyResolverTest is Test {
    string constant FIXTURE = "test/fixtures/adraffy.bsky.social.json";
    // dns("adraffy.bsky.eth")
    bytes constant NAME = hex"07616472616666790462736b790365746800";
    bytes constant HANDLE = "adraffy.bsky.social";
    uint256 constant MAX_AGE = 30 days;

    BlueskyResolver resolver;
    VerifierHarness harness;
    string json;

    function setUp() public {
        json = vm.readFile(FIXTURE);
        string[] memory urls = new string[](1);
        urls[0] = "http://localhost:8016";
        bytes memory anchor = bytes(vm.parseJsonString(json, ".anchorDid"));
        resolver = new BlueskyResolver(urls, _namehash2("bsky", "eth"), anchor, MAX_AGE);
        harness = new VerifierHarness(anchor, 0);
    }

    function _namehash2(string memory a, string memory b) internal pure returns (bytes32) {
        bytes32 node = keccak256(abi.encode(bytes32(0), keccak256(bytes(b))));
        return keccak256(abi.encode(node, keccak256(bytes(a))));
    }

    function _proof() internal view returns (BlueskyVerifier.Proof memory p) {
        p.anchor = vm.parseJsonBytesArray(json, ".anchor");
        p.ops = vm.parseJsonBytesArray(json, ".ops");
        p.commit = vm.parseJsonBytes(json, ".commit");
        p.nodes = vm.parseJsonBytesArray(json, ".nodes");
        p.profile = vm.parseJsonBytes(json, ".profile");
        p.links = vm.parseJsonBytesArray(json, ".links");
    }

    function _response(BlueskyVerifier.Proof memory p) internal pure returns (bytes memory) {
        return abi.encode(p.anchor, p.ops, p.commit, p.nodes, p.profile, p.links);
    }

    function _callback(bytes memory data) internal view returns (bytes memory) {
        return resolver.resolveCallback(_response(_proof()), abi.encode(HANDLE, data));
    }

    function test_verify() public view {
        uint256 g = gasleft();
        BlueskyVerifier.Profile memory p = harness.verify(HANDLE, _proof());
        console.log("verify gas", g - gasleft());
        assertEq(string(p.did), vm.parseJsonString(json, ".did"));
        assertEq(p.time, vm.parseJsonUint(json, ".expected.time")); // TS and Solidity TID decoding agree
        assertEq(p.links.length, 1);
        (bool ok, address a) = BlueskyRecords.addr(p, BlueskyRecords.COIN_ETH);
        assertTrue(ok);
        assertEq(a, vm.parseJsonAddress(json, ".expected.eth"));
    }

    function test_supportsInterface() public view {
        assertTrue(resolver.supportsInterface(0x01ffc9a7)); // ERC-165
        assertTrue(resolver.supportsInterface(0x9061b923)); // IExtendedResolver
        assertTrue(resolver.supportsInterface(0x582de3e7)); // IERC7996
        assertFalse(resolver.supportsInterface(0xffffffff));
    }

    function test_supportsFeature() public view {
        assertEq(resolver.RESOLVE_MULTICALL(), bytes4(0x96b62db8)); // ENS ResolverFeatures.RESOLVE_MULTICALL
        assertTrue(resolver.supportsFeature(0x96b62db8));
        assertFalse(resolver.supportsFeature(0x86fb8da8)); // SINGULAR: records depend on the name
        assertFalse(resolver.supportsFeature(0x00000000));
    }

    // multicall

    function _multicall(bytes[] memory calls) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(BlueskyRecords.MULTICALL, calls);
    }

    function test_multicall() public view {
        bytes[] memory calls = new bytes[](6);
        calls[0] = abi.encodeWithSelector(BlueskyRecords.ADDR, bytes32(0));
        calls[1] = abi.encodeWithSelector(BlueskyRecords.ADDR_COIN, bytes32(0), uint256(60));
        calls[2] = abi.encodeWithSelector(BlueskyRecords.TEXT, bytes32(0), "avatar");
        calls[3] = abi.encodeWithSelector(BlueskyRecords.TEXT, bytes32(0), "description");
        calls[4] = abi.encodeWithSelector(0x12345678, bytes32(0)); // unsupported profile
        calls[5] = _multicall(new bytes[](0)); // nested multicall
        bytes[] memory res = abi.decode(_callback(_multicall(calls)), (bytes[]));
        assertEq(res.length, calls.length);
        address eth = vm.parseJsonAddress(json, ".expected.eth");
        // each answer matches the single-call answer
        for (uint256 i; i < 4; i++) {
            assertEq(res[i], _callback(calls[i]));
        }
        assertEq(abi.decode(res[0], (address)), eth);
        assertEq(abi.decode(res[1], (bytes)), abi.encodePacked(eth));
        assertEq(abi.decode(res[2], (string)), vm.parseJsonString(json, ".expected.avatar"));
        // failures are revert data with length % 32 == 4
        assertEq(res[4], abi.encodeWithSelector(BlueskyRecords.UnsupportedResolverProfile.selector, bytes4(0x12345678)));
        assertEq(res[5], abi.encodeWithSelector(BlueskyRecords.UnsupportedResolverProfile.selector, BlueskyRecords.MULTICALL));
        assertEq(res[4].length % 32, 4);
    }

    function test_multicall_empty() public view {
        bytes[] memory res = abi.decode(_callback(_multicall(new bytes[](0))), (bytes[]));
        assertEq(res.length, 0);
    }

    function test_multicall_shortCall() public view {
        bytes[] memory calls = new bytes[](2);
        calls[0] = hex"3b3b57de"; // addr(bytes32) selector without its argument
        calls[1] = hex"";
        bytes[] memory res = abi.decode(_callback(_multicall(calls)), (bytes[]));
        assertEq(res[0], abi.encodeWithSelector(BlueskyRecords.UnsupportedResolverProfile.selector, BlueskyRecords.ADDR));
        assertEq(res[1], abi.encodeWithSelector(BlueskyRecords.UnsupportedResolverProfile.selector, bytes4(0)));
    }

    function test_singleCall_unsupportedReverts() public {
        vm.expectRevert(abi.encodeWithSelector(BlueskyRecords.UnsupportedResolverProfile.selector, bytes4(0x12345678)));
        resolver.resolveCallback(_response(_proof()), abi.encode(HANDLE, abi.encodeWithSelector(0x12345678, bytes32(0))));
    }

    function test_resolve_multicall_revertsOffchainLookup() public {
        // the gateway request is the same; the multicall rides along in extraData
        bytes memory data = _multicall(new bytes[](2));
        vm.expectRevert(
            abi.encodeWithSelector(
                BlueskyResolver.OffchainLookup.selector,
                address(resolver),
                resolver.gateways(),
                abi.encodeCall(IBlueskyGateway.proveProfile, (string(HANDLE))),
                resolver.resolveCallback.selector,
                abi.encode(HANDLE, data)
            )
        );
        resolver.resolve(NAME, data);
    }

    function test_config() public view {
        assertEq(resolver.parent(), _namehash2("bsky", "eth"));
        assertEq(resolver.anchorDid(), bytes(vm.parseJsonString(json, ".anchorDid")));
        assertEq(resolver.maxAge(), MAX_AGE);
        assertEq(resolver.gateways().length, 1);
    }

    function test_handleFromName() public view {
        assertEq(resolver.handleFromName(NAME), HANDLE);
    }

    function test_resolve_revertsOffchainLookup() public {
        bytes memory data = abi.encodeWithSelector(BlueskyRecords.ADDR, bytes32(0));
        string[] memory urls = resolver.gateways();
        vm.expectRevert(
            abi.encodeWithSelector(
                BlueskyResolver.OffchainLookup.selector,
                address(resolver),
                urls,
                abi.encodeCall(IBlueskyGateway.proveProfile, (string(HANDLE))),
                resolver.resolveCallback.selector,
                abi.encode(HANDLE, data)
            )
        );
        resolver.resolve(NAME, data);
    }

    function test_resolve_rejectsOtherParent() public {
        // dns("adraffy.other.eth")
        bytes memory name = hex"07616472616666790565746865720365746800";
        vm.expectRevert(abi.encodeWithSelector(BlueskyResolver.UnsupportedName.selector, name));
        resolver.resolve(name, "");
    }

    function test_addr() public view {
        bytes memory res = _callback(abi.encodeWithSelector(BlueskyRecords.ADDR, bytes32(0)));
        assertEq(abi.decode(res, (address)), vm.parseJsonAddress(json, ".expected.eth"));
    }

    function test_addrCoin() public view {
        address expected = vm.parseJsonAddress(json, ".expected.eth");
        bytes memory res = _callback(abi.encodeWithSelector(BlueskyRecords.ADDR_COIN, bytes32(0), uint256(60)));
        assertEq(abi.decode(res, (bytes)), abi.encodePacked(expected));
        res = _callback(abi.encodeWithSelector(BlueskyRecords.ADDR_COIN, bytes32(0), uint256(0)));
        assertEq(abi.decode(res, (bytes)), "");
    }

    function test_text() public view {
        bytes memory res = _callback(abi.encodeWithSelector(BlueskyRecords.TEXT, bytes32(0), "avatar"));
        assertEq(abi.decode(res, (string)), vm.parseJsonString(json, ".expected.avatar"));
        res = _callback(abi.encodeWithSelector(BlueskyRecords.TEXT, bytes32(0), "description"));
        assertEq(abi.decode(res, (string)), vm.parseJsonString(json, ".expected.description"));
    }

    function test_rejectsRogueDID() public {
        // self-signed did:plc claiming the handle: valid chain, but not signed by an anchor key
        BlueskyVerifier.Proof memory p = _proof();
        p.ops = vm.parseJsonBytesArray(json, ".rogueOps");
        vm.expectPartialRevert(BlueskyVerifier.UntrustedPLCSigner.selector);
        harness.verify(HANDLE, p);
    }

    function test_rejectsWrongAnchor() public {
        // the account's own chain is a valid PLC chain, but not the anchor DID
        BlueskyVerifier.Proof memory p = _proof();
        p.anchor = p.ops;
        vm.expectRevert(BlueskyVerifier.InvalidAnchor.selector);
        harness.verify(HANDLE, p);
    }

    function test_rejectsTruncatedAnchor() public {
        // dropping the anchor's genesis op changes the derived DID
        BlueskyVerifier.Proof memory p = _proof();
        if (p.anchor.length < 2) return;
        bytes[] memory tail = new bytes[](p.anchor.length - 1);
        for (uint256 i; i < tail.length; i++) tail[i] = p.anchor[i + 1];
        p.anchor = tail;
        vm.expectRevert();
        harness.verify(HANDLE, p);
    }

    function test_callbackRejectsRogueDID() public {
        BlueskyVerifier.Proof memory p = _proof();
        p.ops = vm.parseJsonBytesArray(json, ".rogueOps");
        vm.expectPartialRevert(BlueskyVerifier.UntrustedPLCSigner.selector);
        resolver.resolveCallback(_response(p), abi.encode(HANDLE, abi.encodeWithSelector(BlueskyRecords.ADDR, bytes32(0))));
    }

    function test_rejectsTamperedProfile() public {
        BlueskyVerifier.Proof memory p = _proof();
        p.profile[p.profile.length - 1] ^= 0x01;
        vm.expectRevert(BlueskyVerifier.ProfileNotInCommit.selector);
        harness.verify(HANDLE, p);
    }

    function test_rejectsTamperedCommit() public {
        BlueskyVerifier.Proof memory p = _proof();
        p.commit[p.commit.length - 20] ^= 0x01; // inside the signature or data
        vm.expectRevert();
        harness.verify(HANDLE, p);
    }

    function test_rejectsWrongHandle() public {
        vm.expectRevert(BlueskyVerifier.HandleNotClaimed.selector);
        harness.verify("someoneelse.bsky.social", _proof());
    }

    // max-age

    function _addrData() internal pure returns (bytes memory) {
        return abi.encodeWithSelector(BlueskyRecords.ADDR, bytes32(0));
    }

    function test_maxAge_fresh() public {
        vm.warp(vm.parseJsonUint(json, ".expected.time") + MAX_AGE);
        _callback(_addrData());
    }

    function test_maxAge_stale() public {
        uint256 time = vm.parseJsonUint(json, ".expected.time");
        vm.warp(time + MAX_AGE + 1);
        vm.expectRevert(abi.encodeWithSelector(BlueskyVerifier.StaleCommit.selector, time));
        resolver.resolveCallback(_response(_proof()), abi.encode(HANDLE, _addrData()));
    }

    function test_maxAge_futureCommitAllowed() public {
        vm.warp(vm.parseJsonUint(json, ".expected.time") - 1 days);
        _callback(_addrData());
    }

    function test_maxAge_off() public {
        vm.warp(vm.parseJsonUint(json, ".expected.time") + 100 * 365 days);
        harness.verify(HANDLE, _proof()); // harness has maxAge = 0
    }

    function test_tid() public view {
        assertEq(harness.tid("3n3cybmytx62b"), 1795809833084836);
        assertEq(harness.tid("2222222222222"), 0);
        assertEq(harness.tid("bzzzzzzzzzzzz"), (uint256(1) << 53) - 1); // largest valid
    }

    function test_tid_rejectsMalformed() public {
        vm.expectRevert(abi.encodeWithSelector(Encoding.InvalidEncoding.selector, 12));
        harness.tid("3n3cybmytx62"); // 12 chars
        vm.expectRevert(abi.encodeWithSelector(Encoding.InvalidEncoding.selector, 0));
        harness.tid("czzzzzzzzzzzz"); // top bit set
        vm.expectRevert(abi.encodeWithSelector(Encoding.InvalidEncoding.selector, 12));
        harness.tid("3n3cybmytx62!"); // bad char
    }

    // mirrors test/records.test.ts

    address constant A = 0x51050ec063d393217B436747617aD1C2285Aeeee;
    address constant B = 0x000000000000000000000000000000000000dEaD;
    address constant C = 0x00000000000000000000000000000000000000cc;

    function _links(string[] memory urls) internal pure returns (BlueskyVerifier.Profile memory p) {
        p.did = "did:plc:x";
        p.links = new BlueskyVerifier.Link[](urls.length);
        for (uint256 i; i < urls.length; i++) {
            p.links[i] = BlueskyVerifier.Link(bytes(urls[i]), "");
        }
    }

    function _one(string memory url) internal pure returns (BlueskyVerifier.Profile memory) {
        string[] memory urls = new string[](1);
        urls[0] = url;
        return _links(urls);
    }

    function _addr(BlueskyVerifier.Profile memory p, uint256 coinType) internal pure returns (address a) {
        (, a) = BlueskyRecords.addr(p, coinType);
    }

    uint256 constant COIN_OPTIMISM = 0x80000000 | 10; // no explorer support: only reachable via #default
    uint256 constant COIN_BTC = 0;

    function test_records_chainFromCoinType() public pure {
        assertEq(BlueskyRecords.chainFromCoinType(BlueskyRecords.COIN_ETH), 1);
        assertEq(BlueskyRecords.chainFromCoinType(BlueskyRecords.COIN_BASE), 8453);
        assertEq(BlueskyRecords.chainFromCoinType(COIN_OPTIMISM), 10);
        assertEq(BlueskyRecords.chainFromCoinType(BlueskyRecords.COIN_DEFAULT_EVM), 0);
        assertEq(BlueskyRecords.chainFromCoinType(COIN_BTC), 0);
        assertEq(BlueskyRecords.chainFromCoinType(0x100000000), 0);
    }

    function test_records_explorers() public pure {
        string[] memory urls = new string[](3);
        urls[0] = "https://etherscan.io/address/0x51050ec063d393217B436747617aD1C2285Aeeee";
        urls[1] = "https://basescan.org/address/0x000000000000000000000000000000000000dEaD";
        urls[2] = "https://arbiscan.io/address/0x00000000000000000000000000000000000000cc";
        BlueskyVerifier.Profile memory p = _links(urls);
        assertEq(_addr(p, BlueskyRecords.COIN_ETH), A);
        assertEq(_addr(p, BlueskyRecords.COIN_BASE), B);
        assertEq(_addr(p, BlueskyRecords.COIN_ARBITRUM), C);
        assertEq(_addr(p, COIN_OPTIMISM), address(0)); // no #default
        assertEq(_addr(p, BlueskyRecords.COIN_DEFAULT_EVM), address(0));
        assertEq(BlueskyRecords.COIN_BASE, 0x80002105);
        assertEq(BlueskyRecords.COIN_ARBITRUM, 0x8000a4b1);
        p.links[0].title = "whatever"; // title is ignored
        assertEq(_addr(p, BlueskyRecords.COIN_ETH), A);
    }

    function test_records_default() public pure {
        string[] memory urls = new string[](2);
        urls[0] = "https://etherscan.io/address/0x51050ec063d393217B436747617aD1C2285Aeeee#default";
        urls[1] = "https://basescan.org/address/0x000000000000000000000000000000000000dEaD";
        BlueskyVerifier.Profile memory p = _links(urls);
        assertEq(_addr(p, BlueskyRecords.COIN_DEFAULT_EVM), A);
        assertEq(_addr(p, BlueskyRecords.COIN_ETH), A); // its own chain
        assertEq(_addr(p, BlueskyRecords.COIN_BASE), B); // chain-specific link wins over the default
        assertEq(_addr(p, BlueskyRecords.COIN_ARBITRUM), A); // known chain without a link: default
        assertEq(_addr(p, COIN_OPTIMISM), A); // unknown EVM chain: default
        assertEq(_addr(p, COIN_BTC), address(0)); // non-EVM: no default
        // any explorer can carry it; mainnet falls back too
        BlueskyVerifier.Profile memory q = _one("https://basescan.org/address/0x000000000000000000000000000000000000dEaD#default");
        assertEq(_addr(q, BlueskyRecords.COIN_DEFAULT_EVM), B);
        assertEq(_addr(q, BlueskyRecords.COIN_ETH), B);
    }

    function test_records_firstWins() public pure {
        string[] memory urls = new string[](2);
        urls[0] = "https://etherscan.io/address/0x51050ec063d393217B436747617aD1C2285Aeeee";
        urls[1] = "https://etherscan.io/address/0x000000000000000000000000000000000000dEaD";
        assertEq(_addr(_links(urls), BlueskyRecords.COIN_ETH), A);
        urls[0] = "https://basescan.org/address/0x000000000000000000000000000000000000dEaD#default";
        urls[1] = "https://etherscan.io/address/0x51050ec063d393217B436747617aD1C2285Aeeee#default";
        BlueskyVerifier.Profile memory p = _links(urls);
        assertEq(_addr(p, BlueskyRecords.COIN_DEFAULT_EVM), B);
        assertEq(_addr(p, BlueskyRecords.COIN_ETH), A); // chain-specific still wins
    }

    function test_records_strictFormat() public pure {
        string[11] memory bad = [
            "https://etherscan.io/address/0x51050ec063d393217B436747617aD1C2285Aeeee/",
            "https://etherscan.io/address/0x51050ec063d393217B436747617aD1C2285Aeeee?a=1",
            "https://etherscan.io/address/0x51050ec063d393217B436747617aD1C2285Aeeee?default",
            "https://etherscan.io/address/0x51050ec063d393217B436747617aD1C2285Aeeee#defaultx",
            "https://etherscan.io/address/0x51050ec063d393217B436747617aD1C2285Aeeee#",
            "https://etherscan.io/address/0x51050ec063d393217B436747617aD1C2285Aeee",
            "https://etherscan.io/token/0x51050ec063d393217B436747617aD1C2285Aeeee",
            "http://etherscan.io/address/0x51050ec063d393217B436747617aD1C2285Aeeee",
            "https://sepolia.etherscan.io/address/0x51050ec063d393217B436747617aD1C2285Aeeee",
            "https://basescan.io/address/0x51050ec063d393217B436747617aD1C2285Aeeee",
            "https://x.io/0x51050ec063d393217B436747617aD1C2285Aeeee"
        ];
        for (uint256 i; i < bad.length; i++) {
            assertEq(_addr(_one(bad[i]), BlueskyRecords.COIN_ETH), address(0));
            assertEq(_addr(_one(bad[i]), BlueskyRecords.COIN_DEFAULT_EVM), address(0));
        }
    }

    function test_records_bioNotParsed() public pure {
        BlueskyVerifier.Profile memory p;
        p.description = "eth:0x51050ec063d393217B436747617aD1C2285Aeeee";
        assertEq(_addr(p, BlueskyRecords.COIN_ETH), address(0));
    }

    function test_records_text() public pure {
        string[] memory urls = new string[](5);
        urls[0] = "https://etherscan.io/address/0x51050ec063d393217B436747617aD1C2285Aeeee";
        urls[1] = "https://basescan.org/address/0x000000000000000000000000000000000000dEaD#default";
        urls[2] = "https://github.com/adraffy/ens-normalize.js";
        urls[3] = "https://x.com/adraffy?s=1";
        urls[4] = "https://raffy.xyz";
        BlueskyVerifier.Profile memory p = _links(urls);
        assertEq(string(BlueskyRecords.text(p, "com.github")), "adraffy");
        assertEq(string(BlueskyRecords.text(p, "com.twitter")), "adraffy");
        assertEq(string(BlueskyRecords.text(p, "url")), "https://raffy.xyz");
    }

    function test_addrCoin_chains() public view {
        // live fixture: only an etherscan link, no #default, so no fallback either
        bytes memory res = _callback(abi.encodeWithSelector(BlueskyRecords.ADDR_COIN, bytes32(0), BlueskyRecords.COIN_DEFAULT_EVM));
        assertEq(abi.decode(res, (bytes)), "");
        res = _callback(abi.encodeWithSelector(BlueskyRecords.ADDR_COIN, bytes32(0), BlueskyRecords.COIN_BASE));
        assertEq(abi.decode(res, (bytes)), "");
    }

    function test_ignoresTamperedLink() public view {
        BlueskyVerifier.Proof memory p = _proof();
        p.links[0][p.links[0].length - 1] ^= 0x01;
        BlueskyVerifier.Profile memory profile = harness.verify(HANDLE, p);
        assertEq(profile.links.length, 0);
    }
}
