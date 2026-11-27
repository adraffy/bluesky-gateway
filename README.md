# bluesky-gateway

[![CI](https://github.com/adraffy/bluesky-gateway/actions/workflows/ci.yml/badge.svg)](https://github.com/adraffy/bluesky-gateway/actions/workflows/ci.yml)

ENS resolver + CCIP-Read gateway that proves records from Bluesky profiles. Protocol, trust
assumptions and limitations: [docs/protocol.md](docs/protocol.md). Gas: [docs/gas.md](docs/gas.md).

## How it works

`{label}.<parent>` resolves to records proven from `{label}.bsky.social`'s signed atproto repo:
bsky.app PLC chain (anchor) → account PLC chain signed by an anchor key and claiming the handle →
signing key → signed commit → MST → profile + link records, all verified on-chain. The gateway is
unsigned (ezccip `raw` protocol) and untrusted.

Records (users edit these in the bsky.app profile editor):

| ENS                                     | Source                                                                                                                                          |
| --------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| `addr(60)`                              | profile link to `https://etherscan.io/address/0x…`                                                                                              |
| `addr(0x80002105)`, `addr(0x8000a4b1)`  | profile link to `https://basescan.org/address/0x…` (Base) / `https://arbiscan.io/address/0x…` (Arbitrum One)                                    |
| `addr(0x80000000)` (default EVM)        | an explorer link ending in `#default`, eg. `https://etherscan.io/address/0x…#default`; also the fallback for any EVM chain without its own link |
| `text(name)` / `text(description)`      | display name / bio                                                                                                                              |
| `text(avatar)`                          | avatar blob → `cdn.bsky.app` URL                                                                                                                |
| `text(com.github)`, `text(com.twitter)` | profile links to github.com / x.com / twitter.com                                                                                               |
| `text(url)`                             | first other profile link                                                                                                                        |

All of these can be requested together with `resolve(name, multicall([...]))` (ERC-7996 feature
`eth.ens.resolver.extended.multicall`): one gateway round trip, one verification.

### Layout

- `contracts/` — `BlueskyResolver` (ENSIP-10 + OffchainLookup), `BlueskyVerifier` (PLC, commit, MST),
  `BlueskyRecords` (record mapping), `CBOR`, `Encoding`, `Secp256k1`
- `src/bluesky.ts` — fetches proofs; `src/verify.ts` — TS reference verifier; `src/records.ts` —
  record mapping (mirrors `BlueskyRecords.sol`); `src/gateway.ts` — ezccip gateway
- `scripts/serve.ts` — runs the gateway; `scripts/prove.ts` — CLI that fetches and verifies a
  profile; `scripts/fixture.ts` — records a live proof into
  `test/fixtures/`

### Commands

Contracts compile with [Solar](https://github.com/paradigmxyz/solar) (`solc = "solar:0.3.1"` in `foundry.toml`).

```bash
bun install && forge build
bun run lint                           # biome lint + format check (bun run format to fix)
bun test                               # TS unit + e2e (anvil + gateway + live bsky data)
forge test                             # Solidity tests against test/fixtures
bun scripts/fixture.ts adraffy.bsky.social
bun scripts/serve.ts                   # gateway on :8016
bun scripts/prove.ts adraffy           # fetch + verify a profile, show its ENS records (--json, --max-age)
```

### Deploying

`BlueskyResolver(gateways, parent, anchorDid, maxAge)`. The resolver is immutable (no owner); to
change any of these, deploy a new one.

- `gateways`: CCIP-Read gateway URLs
- `parent`: namehash of the parent name
- `anchorDid`: `did:plc:z72i7hdynmk6r22z27h6tvur` (bsky.app); its rotation keys are the trusted PLC
  signers
- `maxAge`: reject commits older than this many seconds, or 0 for no limit. Bounds stale-record
  replay, but accounts that haven't posted, liked, followed or edited their profile within the window
  stop resolving.

### Trust and limits

See [docs/protocol.md](docs/protocol.md) §5 (trust assumptions) and §6 (limitations). In short: the
trust root is Bluesky's PLC key (via the bsky.app anchor); the gateway can withhold or serve older
valid data, but can't forge records.
