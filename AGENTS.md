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
forge test                             # Solidity tests (offline, uses test/fixtures)
bun test                               # TS unit tests + e2e (anvil + gateway + live Bluesky data)
bun scripts/fixture.ts adraffy.bsky.social   # re-record a live fixture
bun src/serve.ts                       # run the gateway on :8016
```

Run all three checks (tsc, forge test, bun test) before finishing a change. The e2e test needs network
access and fails if Bluesky is unreachable or the fixture account changes.

## Layout

- `contracts/BlueskyResolver.sol`: ENSIP-10 resolver, `OffchainLookup`, callback.
- `contracts/BlueskyVerifier.sol`: anchor PLC chain, account PLC chain, commit, max-age, MST, records.
- `contracts/BlueskyRecords.sol`: maps a verified profile to `addr` / `text` answers.
- `contracts/CBOR.sol`, `Encoding.sol`, `Secp256k1.sol`: DAG-CBOR reader, base32/base64url/TID/CID,
  `did:key` → address and ECDSA.
- `src/bluesky.ts`: fetches proofs. `src/verify.ts`: TS reference verifier. `src/records.ts`: record
  mapping. `src/gateway.ts` / `src/serve.ts`: gateway (`@adraffy/ezccip`).
- `scripts/fixture.ts`: records live proofs (plus a rogue self-signed DID) into `test/fixtures/`.
- `test/sol/`: forge tests. `test/*.test.ts`: bun tests.

## Rules

- **Keep TS and Solidity in sync.** `src/verify.ts` mirrors `BlueskyVerifier.sol`, and
  `src/records.ts` mirrors `BlueskyRecords.sol`. Change both together and add test cases on both
  sides (see the `test_records_*` forge tests and `test/records.test.ts`).
- **No gateway signer.** The gateway uses ezccip's `raw` protocol. handle → DID is anchored on the
  bsky.app DID's PLC rotation keys. Don't reintroduce a required signature.
- **No L2 writes.** The resolver stays stateless apart from owner configuration (URLs, parents). Don't
  add on-chain registries, mirrors or commitments as mitigations.
- **Bluesky only.** `*.bsky.social` handles, `did:plc`, secp256k1 keys.
- **Use `@adraffy/ezccip`**, not `@resolverworks/ezccip`.
- Treat everything the gateway returns as hostile input: bounded parsing, explicit reverts, no
  trust in ordering beyond what hashes and signatures prove.
- Watch gas: verification is about 3.1M gas in `eth_call`. Avoid per-byte loops over `bytes memory`
  where fixed-width arithmetic works (see `Secp256k1.didKeyToAddress`).
- Update `docs/protocol.md` when behavior, trust assumptions or limitations change.

## Style

- Solidity: `^0.8.28`, compiled with via-IR (stack depth), custom errors, NatSpec on public surface.
- TypeScript: ESM, strict, tabs, single quotes, run with bun.
