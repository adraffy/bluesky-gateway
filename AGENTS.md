# AGENTS.md

Guidance for coding agents working in this repo.

## What this is

An ENS resolver (`contracts/`) and CCIP-Read gateway (`src/`) that resolve `{label}.<parent>` to
records proven from the Bluesky account `{label}.bsky.social`. The gateway is untrusted and unsigned;
the contract verifies everything on-chain. Read [docs/protocol.md](docs/protocol.md) before changing
behavior: it is the spec, including trust assumptions and limitations.

## Commands

```bash
bun install && forge build
bunx tsc -p .                          # type check
bun run lint                           # biome: lint + format check (bun run format to fix)
forge test                             # Solidity tests (offline, uses test/fixtures)
bun test                               # TS unit tests + e2e (anvil + gateway + live Bluesky data)
bun scripts/fixture.ts adraffy.bsky.social   # re-record a live fixture
bun scripts/serve.ts                   # run the gateway on :8016
bun scripts/prove.ts adraffy           # fetch + verify a profile, print its ENS records
```

Run all four checks (tsc, lint, forge test, bun test) before finishing a change. The e2e test needs network
access and fails if Bluesky is unreachable or the fixture account changes.

## Layout

- `contracts/BlueskyResolver.sol`: ENSIP-10 resolver, `OffchainLookup`, callback.
- `contracts/BlueskyVerifier.sol`: anchor PLC chain, account PLC chain, commit, max-age, MST, records.
- `contracts/BlueskyRecords.sol`: maps a verified profile to `addr` / `text` answers.
- `contracts/CBOR.sol`, `Encoding.sol`, `Secp256k1.sol`: DAG-CBOR reader, base32/base64url/TID/CID,
  `did:key` → address and ECDSA.
- `src/bluesky.ts`: fetches proofs. `src/verify.ts`: TS reference verifier. `src/records.ts`: record
  mapping. `src/gateway.ts`: gateway (`@adraffy/ezccip`).
  `src/` is library code with no side effects; entry points go in `scripts/`.
- `scripts/serve.ts`: runs the gateway. `scripts/prove.ts`: CLI to fetch + verify one account. `scripts/fixture.ts`: records live proofs (plus a rogue self-signed DID) into `test/fixtures/`.
- `test/sol/`: forge tests. `test/*.test.ts`: bun tests.

## Rules

- **Keep TS and Solidity in sync.** `src/verify.ts` mirrors `BlueskyVerifier.sol`, and
  `src/records.ts` mirrors `BlueskyRecords.sol`. Change both together and add test cases on both
  sides (see the `test_records_*` forge tests and `test/records.test.ts`).
- **No gateway signer.** The gateway uses ezccip's `raw` protocol. handle → DID is anchored on the
  bsky.app DID's PLC rotation keys. Don't reintroduce a required signature.
- **No L2 writes, no owner.** The resolver is stateless and immutable: all config (gateways, parent,
  anchor, maxAge) is set in the constructor. Don't add admin setters, on-chain registries, mirrors or
  commitments.
- **Bluesky only.** `*.bsky.social` handles, `did:plc`, secp256k1 keys.
- **Use `@adraffy/ezccip`**, not `@resolverworks/ezccip`.
- **Use viem, not ethers.** Don't import or depend on ethers directly. Tests may use
  `@adraffy/blocksmith` (currently ethers-based internally) to launch anvil and deploy; do calls and
  encoding with viem and ezccip's `resolverAbi`.
- Treat everything the gateway returns as hostile input: bounded parsing, explicit reverts, no
  trust in ordering beyond what hashes and signatures prove.
- Watch gas: verification is about 0.9M gas in `eth_call` (`forge test --match-contract Gas -vv`,
  see `docs/gas.md`). Avoid per-byte loops over `bytes memory`
  where fixed-width arithmetic works (see `Secp256k1.didKeyToAddress`).
- Update `docs/protocol.md` when behavior, trust assumptions or limitations change.

## Style

- Solidity: `^0.8.28`, compiled with Solar (`solc = "solar:0.3.1"` in foundry.toml; no via-IR needed), custom errors, NatSpec on public surface. It also builds with solc 0.8.30, but only with `via_ir = true` (stack too deep otherwise).
- TypeScript: ESM, strict, run with bun, formatted and linted by Biome (`biome.json`: tabs, single quotes,
  120 columns, recommended rules). Type decoded atproto data with `src/atproto.ts` instead of `any`.
