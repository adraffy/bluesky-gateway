// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BlueskyVerifier} from "./BlueskyVerifier.sol";
import {BlueskyRecords} from "./BlueskyRecords.sol";

interface IExtendedResolver {
    function resolve(bytes calldata name, bytes calldata data) external view returns (bytes memory);
}

/// @notice ABI of the gateway function (served by src/gateway.ts via ezccip, "raw" protocol: unsigned)
interface IBlueskyGateway {
    function proveProfile(string calldata handle)
        external
        view
        returns (
            bytes[] memory anchor,
            bytes[] memory ops,
            bytes memory commit,
            bytes[] memory nodes,
            bytes memory profile,
            bytes[] memory links
        );
}

/// @notice ENSIP-10 wildcard resolver: {label}.<parent> => {label}.bsky.social
/// Records are proven from the account's signed atproto repo. The gateway is untrusted: handle -> did
/// is accepted when the account's latest PLC op claims the handle and was signed by one of the
/// anchor DID's rotation keys (Bluesky's PLC signers).
contract BlueskyResolver is IExtendedResolver {
    error OffchainLookup(address sender, string[] urls, bytes callData, bytes4 callbackFunction, bytes extraData);
    error UnsupportedName(bytes name);
    error Unauthorized();

    event GatewayChanged(string[] urls);
    event ParentChanged(bytes32 node, bool enabled);

    bytes constant HANDLE_SUFFIX = ".bsky.social";

    address public owner;
    bytes public anchorDid;
    uint256 public immutable maxAge;
    string[] _urls;
    mapping(bytes32 => bool) public parents;

    /// @param anchor DID whose latest rotation keys are trusted to sign PLC ops (bsky.app: did:plc:z72i7hdynmk6r22z27h6tvur)
    /// @param _maxAge reject commits older than this many seconds (0 = no limit). Accounts that haven't
    /// written to their repo (post, like, follow, profile edit) within this window stop resolving.
    constructor(string[] memory urls, bytes32 parent, bytes memory anchor, uint256 _maxAge) {
        owner = msg.sender;
        _urls = urls;
        parents[parent] = true;
        anchorDid = anchor;
        maxAge = _maxAge;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    function setGateway(string[] calldata urls) external onlyOwner {
        _urls = urls;
        emit GatewayChanged(urls);
    }

    function setParent(bytes32 node, bool enabled) external onlyOwner {
        parents[node] = enabled;
        emit ParentChanged(node, enabled);
    }

    function gatewayURLs() external view returns (string[] memory) {
        return _urls;
    }

    function supportsInterface(bytes4 x) external pure returns (bool) {
        return x == 0x01ffc9a7 // ERC-165
            || x == 0x9061b923; // IExtendedResolver
    }

    /// @notice "{label}.<parent>" -> "{label}.bsky.social"
    function handleFromName(bytes memory name) public view returns (bytes memory handle) {
        uint256 len = uint8(name[0]);
        if (len == 0 || len > 63 || !parents[_namehash(name, 1 + len)]) revert UnsupportedName(name);
        handle = new bytes(len);
        for (uint256 i; i < len; i++) {
            bytes1 c = name[1 + i];
            bool ok = (c >= "a" && c <= "z") || (c >= "0" && c <= "9") || (c == "-" && i > 0 && i < len - 1);
            if (!ok) revert UnsupportedName(name);
            handle[i] = c;
        }
        handle = bytes.concat(handle, HANDLE_SUFFIX);
    }

    function resolve(bytes calldata name, bytes calldata data) external view returns (bytes memory) {
        bytes memory handle = handleFromName(name);
        revert OffchainLookup(
            address(this),
            _urls,
            abi.encodeCall(IBlueskyGateway.proveProfile, (string(handle))),
            this.resolveCallback.selector,
            abi.encode(handle, data)
        );
    }

    /// @param response ABI-encoded return value of proveProfile() (ezccip "raw" protocol)
    function resolveCallback(bytes calldata response, bytes calldata extraData) external view returns (bytes memory) {
        (bytes memory handle, bytes memory data) = abi.decode(extraData, (bytes, bytes));
        BlueskyVerifier.Proof memory proof;
        (proof.anchor, proof.ops, proof.commit, proof.nodes, proof.profile, proof.links) =
            abi.decode(response, (bytes[], bytes[], bytes, bytes[], bytes, bytes[]));
        BlueskyVerifier.Profile memory profile = BlueskyVerifier.verify(handle, anchorDid, maxAge, proof);
        return BlueskyRecords.answer(profile, data);
    }

    function _namehash(bytes memory name, uint256 offset) internal pure returns (bytes32) {
        uint256 len = uint8(name[offset]);
        if (len == 0) return bytes32(0);
        bytes32 label;
        assembly {
            label := keccak256(add(add(name, 33), offset), len)
        }
        return keccak256(abi.encode(_namehash(name, offset + 1 + len), label));
    }
}
