# Gas

Measured 2026-11-27 with [`test/sol/Gas.t.sol`](../test/sol/Gas.t.sol) against the
`adraffy.bsky.social` fixture (1 PLC op, 1 MST node, 1 link; anchor bsky.app with 4 PLC ops):

```bash
forge test --match-contract Gas -vv                                            # Solar (default)
FOUNDRY_SOLC=0.8.30 FOUNDRY_VIA_IR=true forge test --match-contract Gas -vv    # solc for comparison
```

All resolution happens in `eth_call`, so nobody pays this gas. It matters because RPC providers cap
`eth_call` gas, and because it's a proxy for latency.

## Summary

|                                                                  | Solar 0.3.1 | solc 0.8.30 (via-IR) |
| ---------------------------------------------------------------- | ----------- | -------------------- |
| verification (execution)                                         | **884k**    | 1,998k               |
| `resolveCallback` for one record (execution)                     | **899k**    | 2,034k               |
| `eth_call` total for one record (+ 21k intrinsic + 63k calldata) | **~0.98M**  | ~2.12M               |
| proof size                                                       | 4,480 bytes | 4,480 bytes          |

Solar is about 2.3× cheaper across the board, and doesn't need via-IR. Earlier figures in this repo
(~1.8M / ~3.15M) included the test's own cost of ABI-encoding the proof for an external call; the
numbers here are measured inside the contract.

## Where verification gas goes (Solar)

| Stage                                                  | Gas         | Share |
| ------------------------------------------------------ | ----------- | ----- |
| anchor PLC chain (bsky.app, 4 ops)                     | 508,038     | 57%   |
| account PLC chain (1 op)                               | 126,578     | 14%   |
| identity (handle check + signing key)                  | 40,605      | 5%    |
| commit (signature + `rev`)                             | 34,844      | 4%    |
| MST lookup of the profile (1 node)                     | 40,516      | 5%    |
| profile + links (1 link: CID check, MST lookup, parse) | 133,726     | 15%   |
| **total**                                              | **884,307** |       |

The PLC chains dominate (71%). Each op verifies a signature against the previous op's rotation keys,
and every `did:key` has to be base58-decoded and its point decompressed (one `modexp`) to get an
address: **~23k gas per key**. bsky.app's ops list 2 rotation keys each, so the anchor decodes 8 keys
(~187k).

The anchor is the same for every name, but the resolver is stateless, so it's re-verified on every
resolution.

## Answering records (after verification)

| Record             | Gas   |
| ------------------ | ----- |
| `addr(node)`       | 8,516 |
| `addr(node, 60)`   | 9,120 |
| `text(avatar)`     | 1,845 |
| `text(com.github)` | 3,516 |

Records are cheap; verification is everything. `addr` checks each link against 6 explorers.

## Multicall

`resolve(name, multicall([...]))` verifies the proof once and answers every call, in one CCIP-Read
round trip. `resolveCallback` execution gas (Solar):

| Records (k) | k separate resolutions | one multicall | saving |
| ----------- | ---------------------- | ------------- | ------ |
| 1           | 899,853                | 902,397       | —      |
| 2           | 1,802,245              | 913,917       | 49%    |
| 4           | 3,595,840              | 921,652       | 74%    |
| 6           | 5,410,213              | 940,718       | 83%    |
| 8           | 7,234,097              | 955,463       | 87%    |

Each extra record in a multicall costs roughly 5–10k gas. Separate resolutions also cost k gateway
round trips and k × (21k intrinsic + ~63k calldata). The ENS UniversalResolver uses the multicall
path when the resolver reports ERC-7996 feature `0x96b62db8` (`eth.ens.resolver.extended.multicall`),
which `BlueskyResolver` does.

## Optimizations

Done:

- **Decode the genesis op's rotation keys once** in `verifyPLC` (they were decoded before the loop and
  again after verifying op 0): −57k per chain, verification 999k → 884k (−11.5%).

Not implemented:

- **Signer hints:** the gateway could say which rotation key signed each op, so the contract decodes
  one key per op instead of all of them. For the anchor that's 4 decodes instead of 8 (~90k).
- **Compare keys, not addresses:** decompressing a point (`modexp`) and hashing it to an address is
  only needed because `ecrecover` returns an address. Recovering the full public key would need a
  different approach and probably isn't cheaper.
- **Shorter anchor:** bsky.app's chain only grows (4 ops today). A different anchor DID with a shorter
  history and the same rotation keys would be cheaper, but changes the trust assumption.
