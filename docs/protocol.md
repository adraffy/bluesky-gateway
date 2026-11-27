# Protocol

How `BlueskyResolver` and the gateway resolve an ENS name from a Bluesky profile, what each party is
trusted for, and what isn't supported.

```
ENS client ──resolve(adraffy.<parent>, addr(60))──► BlueskyResolver
           ◄── OffchainLookup(proveProfile("adraffy.bsky.social")) ──
ENS client ──► gateway (untrusted, unsigned): bsky.app PLC log + handle → did → PLC log → repo proofs
ENS client ──► BlueskyResolver.resolveCallback(response)
                 anchor chain → account chain (signed by an anchor key, claims the handle)
                 → commit signature → MST → records
           ◄── 0x51050ec0…5Aeeee
```

## 1. Naming

`{label}.<parent>` maps to the handle `{label}.bsky.social`.

- `<parent>` is the single parent name set at deployment (`parent` is its namehash). Deploy another
  resolver for another parent.
- The handle is derived from the queried name **in the contract**, never taken from the gateway.
- `label` must be 1–63 chars of `[a-z0-9-]`, not starting or ending with `-`. Anything else, the
  parent itself, and names more than one label below a parent revert `UnsupportedName`.

## 2. Records

Users set these in the bsky.app profile editor (links require pressing Save).

| ENS query | Source |
|---|---|
| `addr(node)`, `addr(node, 60)`, `addr(node, 0x80000000)` | first profile link titled exactly `eth` whose URL ends in `/0x` + 40 hex (e.g. `https://etherscan.io/address/0x…`); otherwise an `eth:0x…` token in the bio delimited by whitespace or start/end |
| `addr(node, other)` | empty |
| `text(name)` | `displayName` |
| `text(description)` | `description` (bio) |
| `text(avatar)` | `https://cdn.bsky.app/img/avatar/plain/{did}/{avatarCid}@jpeg` |
| `text(com.github)` | first path segment of the first link to `https://github.com/…` |
| `text(com.twitter)` | first path segment of the first link to `https://x.com/…` or `https://twitter.com/…` |
| `text(url)` | first link that is neither an `eth` link nor one of the above |
| other `text` keys | empty |
| other selectors | revert `UnsupportedResolverProfile` |

### Multicall

`data` may be `multicall(bytes[] calls)` of the calls above. The proof is fetched and verified once,
in one CCIP-Read round trip, and the answer is `abi.encode(bytes[] results)`: each result is the
ABI-encoded answer, or the call's revert data (eg. `UnsupportedResolverProfile`) padded to
`length % 32 == 4`, matching ENS's batch convention. Nested multicalls fail per call.

The resolver advertises this via [ERC-7996](https://eips.ethereum.org/EIPS/eip-7996):
`supportsInterface(0x582de3e7)` and `supportsFeature(0x96b62db8)` (ENS
`ResolverFeatures.RESOLVE_MULTICALL`, `keccak256("eth.ens.resolver.extended.multicall")`), which is
what the ENS UniversalResolver checks before sending `resolve(name, multicall(...))` directly.

Links are considered in profile display order. The mapping lives in
[`BlueskyRecords.sol`](../contracts/BlueskyRecords.sol) and is mirrored in
[`records.ts`](../src/records.ts); tests check both against the same cases.

## 3. Request and response

`resolve(name, data)` reverts:

```solidity
OffchainLookup(
  sender:   resolver,
  urls:     gateways(),
  callData: proveProfile(string handle),
  callback: resolveCallback.selector,
  extra:    abi.encode(bytes handle, bytes data)
)
```

Gateway function ([`gateway.ts`](../src/gateway.ts), served with `@adraffy/ezccip`):

```solidity
function proveProfile(string handle) view returns (
  bytes[] anchor,   // signed PLC ops of the anchor DID (bsky.app), genesis → latest
  bytes[] ops,      // signed PLC ops of the account, genesis → latest, non-nullified
  bytes   commit,   // signed repo commit (DAG-CBOR)
  bytes[] nodes,    // MST nodes on the paths to the records (DAG-CBOR)
  bytes   profile,  // app.bsky.actor.profile/self
  bytes[] links     // app.bsky.actor.link records referenced by the profile
);
```

The gateway fetches, per request (proofs cached 30s, anchor log cached 5 min):

1. `https://plc.directory/did:plc:z72i7hdynmk6r22z27h6tvur/log` → anchor ops (bsky.app)
2. `https://{handle}/.well-known/atproto-did` → `did:plc:…`
3. `https://plc.directory/{did}/log` → ops; checks the latest claims `at://{handle}`
4. `{pds}/xrpc/com.atproto.sync.getRecord` for the profile and each link; all proofs must share one
   commit (refetches up to 3 times if the repo changed in between)

The response is **unsigned** (ezccip `raw` protocol): it is exactly the ABI-encoded return value of
`proveProfile`. Nothing in it is trusted; the resolver verifies all of it.

## 4. Verification

[`BlueskyVerifier.sol`](../contracts/BlueskyVerifier.sol) (mirrored in [`verify.ts`](../src/verify.ts)).
A PLC chain is valid when: every op is a single DAG-CBOR item with `type == "plc_operation"`; `prev`
is null for the genesis op, otherwise the CID string of the previous op; and `sig` (base64url) is a
secp256k1 signature over `sha256(op without sig)` by one of the previous op's `rotationKeys` (the
genesis op's own keys for the genesis op). Its DID is `"did:plc:" + base32(sha256(ops[0]))[:24]`.

1. **Anchor:** `anchor` is a valid chain whose DID equals the resolver's `anchorDid`
   (`did:plc:z72i7hdynmk6r22z27h6tvur`, bsky.app, set at deployment). The rotation keys of its latest
   op are the **trusted PLC signers**.
2. **Account:** `ops` is a valid chain, and its latest op was signed by a trusted PLC signer. This is
   what replaces a gateway signature: Bluesky's PLC key signs every identity operation for
   bsky.social accounts, including handle changes, and Bluesky controls the `bsky.social` namespace.
3. **Identity:** the latest op's `alsoKnownAs` contains `at://{handle}`; its
   `verificationMethods.atproto` is the repo signing key.
4. **Commit:** `did` matches, `version == 3`, and `sig` is a signature over
   `sha256(commit without sig)` by the signing key. `data` is the MST root.
5. **Max-age:** the commit's signed `rev` is a TID (13 chars of base32-sortable: top bit 0, 53 bits
   of microseconds since the epoch, 10-bit clock id). If the resolver's `maxAge` is non-zero, the
   commit must be no older than `maxAge` seconds (`time + maxAge >= block.timestamp`), else
   `StaleCommit(time)`. Commits dated in the future are accepted, since `rev` comes from the PDS clock.
6. **Profile:** the MST maps `app.bsky.actor.profile/self` to `sha256(profile)`.
7. **Links:** for each `{cid, uri}` in `profile.links`, a provided link record must hash to `cid`,
   `uri` must be `at://{did}/app.bsky.actor.link/{rkey}`, and the MST must map
   `app.bsky.actor.link/{rkey}` to the same hash. Links failing any check are skipped, not fatal.
8. **Records:** answered from the verified profile and links (§2).

Signed objects are canonical DAG-CBOR, so the unsigned bytes are rebuilt on-chain by removing the
`sig` entry from the top-level map. Verification costs about 1.0M gas inside `eth_call` (Solar;
about 2.3M with solc via-IR); see [gas.md](gas.md).

## 5. Trust assumptions

There is no gateway signer. The trust root is the **anchor DID** (bsky.app): its rotation keys are
taken to be the keys Bluesky uses to sign bsky.social identity operations. That's an assumption about
how Bluesky operates, observed but not guaranteed (see Appendix). The resolver is immutable: gateway
URLs, parent, anchor and `maxAge` are fixed at deployment, and there is no owner.

| Party | Trusted for | Can | Cannot |
|---|---|---|---|
| **Bluesky PBC** | the anchor keys, and key custody for bsky.social accounts | sign an identity op giving any handle to any DID; sign any commit for accounts it hosts | — |
| **Gateway** (anyone serving responses) | availability only | withhold responses; serve **older valid data** (see below) | point a name at a DID unless a Bluesky key signed an op giving that DID the handle; alter records |
| **PLC directory** | serving op logs | withhold or censor ops | forge ops (they're signed) |
| **Account holder** (and anyone with their password, app password, or an app allowed to edit the profile) | the records | change any record | — |
| **Deployer** | configuration, once | choose gateway URLs, parent, anchor and `maxAge` at deployment | change anything afterwards (there is no owner) |

**Freshness is not verified.** Every piece of the proof is a valid prefix or snapshot, and nothing
on-chain says it's the latest, so any gateway can serve older data that still verifies:

- **Old records:** an older commit, eg. a previous ETH address. With `maxAge` set, an old commit is
  servable for at most `maxAge` after the account's next write; with `maxAge = 0`, indefinitely.
- **Recycled handles:** if alice gives up a handle and bob takes it, alice's log truncated before her
  handle change still claims it, and commits signed by her (unchanged) key still verify.
- **Rotated keys:** if an account's signing key was rotated after a compromise, a log truncated before
  the rotation plus a commit forged with the old key would verify (`maxAge` doesn't help: the forger
  picks the `rev`). The same applies to the anchor's rotation keys.
- **Nullified ops:** an op later overridden during PLC's 72h recovery window still verifies.

An honest gateway (like [`gateway.ts`](../src/gateway.ts)) always serves the latest data, at most
about 30s old (cache). Clients can't tell an honest gateway from a stale one.

Handle changes: if a user changes handle, their latest op stops claiming it and the name stops
resolving (from an honest gateway). If someone else later takes the handle, the name follows them.

## 6. Limitations

- Only `*.bsky.social` handles; custom-domain handles aren't supported.
- With `maxAge` set, an account that hasn't written to its repo (post, like, follow, repost,
  profile edit) within `maxAge` reverts `StaleCommit` until it writes again. Many accounts are set up
  once and rarely touched; `maxAge = 0` disables the check.
- Only `did:plc` with secp256k1 keys. P-256 keys, `did:web`, legacy `create` genesis ops and
  tombstoned DIDs revert.
- Accounts whose latest identity op wasn't signed by one of bsky.app's current rotation keys revert
  `UntrustedPLCSigner`: eg. users who added their own rotation key and used it, or ops signed by a
  retired Bluesky key.
- If Bluesky stops signing user ops with the same keys bsky.app lists, resolution breaks until the
  resolver is redeployed with a new anchor.
- Only an ETH address (coin types 60 and 0x80000000) and the text keys in §2. No contenthash, no
  other coins, no pinned-post records.
- `text(avatar)` depends on Bluesky's CDN URL format.
- About 1.1M gas per `eth_call` (1.0M execution + calldata + intrinsic; [gas.md](gas.md)); fine,
  but RPC providers that cap `eth_call` gas
  lower would fail.
- The end-to-end test uses live Bluesky data and fails if it's unreachable or the profile changes.

## 7. Future work

- **Optional signed freshness:** accept an attestation of the latest op and commit from a TEE or k-of-n
  signers, without making it required.
- **DID-keyed names** (`<did-suffix>.plc.<parent>`): no dependence on Bluesky vouching for handles.
- **Custom-domain handles with DNSSEC:** prove `_atproto.<handle>` TXT via ENS's DNSSEC oracle.
- **More records:** other coins via link titles (`btc`, `sol`, …), pinned-post overflow, or a custom
  `domains.ens.*` collection written through atproto OAuth.
- P-256 keys via the EIP-7951 precompile.
- Gas: see the optimizations listed in [gas.md](gas.md).

Out of scope by decision: anything that requires writes to an L2 (registries, PLC mirrors,
monotonic commitments). The resolver is stateless and immutable.

## Appendix: observed data

Checked 2026-11-27 against `adraffy.bsky.social`:

- `bsky.social` has no DNSSEC; handles resolve only via HTTPS `/.well-known/atproto-did`.
- Signed PLC ops carry no timestamp; `createdAt` and `nullified` exist only in the directory's
  audit log.
- Keys observed are secp256k1 (`did:key:zQ3s…`). Not confirmed that all bsky.social keys are.
- bsky.app (`did:plc:z72i7hdynmk6r22z27h6tvur`) lists rotation keys `zQ3shhCG…` and `zQ3shpKn…`;
  adraffy.bsky.social lists the same two. Every op checked (adraffy's genesis; bsky.app's 4 ops,
  including its handle change from `bluesky-team.bsky.social` to `bsky.app`) was signed by
  `zQ3shpKn…`.
- `adraffy.bsky.social` → `did:plc:umfh5rwytfls3fnsqynp3vqf` (1 PLC op), PDS
  `pholiota.us-west.host.bsky.network`.
- Proof blocks: commit 188 B, MST node 279 B (small repo, single node), profile 370 B, link 239 B.
  `bsky.app`'s profile proof is about 4 KB, with 4 PLC ops.
- Profile `links` (lexicon `app.bsky.actor.profile`) is an array of up to 10 strong refs to
  `app.bsky.actor.link` records `{url, title (≤40 graphemes), icon, createdAt}`; `website` is
  deprecated in favor of it.
