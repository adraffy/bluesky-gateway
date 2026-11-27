// TypeScript reference implementation of the on-chain verification in
// contracts/BlueskyResolver.sol. Useful for debugging fixtures; the contract is authoritative.

import * as dagCbor from '@ipld/dag-cbor';
import { CID } from 'multiformats/cid';
import * as Digest from 'multiformats/hashes/digest';
import { base32 } from 'multiformats/bases/base32';
import { base58btc } from 'multiformats/bases/base58';
import { sha256 } from '@noble/hashes/sha2.js';
import { secp256k1 } from '@noble/curves/secp256k1.js';
import { PROFILE_KEY, LINK_COLLECTION, HANDLE_SUFFIX, ANCHOR_DID, type Proof } from './bluesky.js';
import type { Profile, Link } from './records.js';

const SECP256K1_PREFIX = [0xe7, 0x01]; // multicodec secp256k1-pub (varint)

export function cidOf(bytes: Uint8Array): string {
	return CID.createV1(0x71, Digest.create(0x12, sha256(bytes))).toString();
}

function didKeyToPub(didKey: string): Uint8Array {
	if (!didKey.startsWith('did:key:z')) throw new Error(`bad did:key: ${didKey}`);
	const raw = base58btc.decode(didKey.slice(8));
	if (raw[0] !== SECP256K1_PREFIX[0] || raw[1] !== SECP256K1_PREFIX[1]) throw new Error('only secp256k1 did:key');
	return raw.slice(2); // 33-byte compressed point
}

// DAG-CBOR is canonical, so dropping `sig` and re-encoding yields the signed bytes
function unsigned(obj: any): Uint8Array {
	const { sig, ...rest } = obj;
	return dagCbor.encode(rest);
}

function findSigner(msg: Uint8Array, sig: Uint8Array, pubs: Uint8Array[]): Uint8Array | undefined {
	return pubs.find((pub) => secp256k1.verify(sig, msg, pub, { prehash: true, lowS: false }));
}

function verifySig(msg: Uint8Array, sig: Uint8Array, pubs: Uint8Array[]): boolean {
	return !!findSigner(msg, sig, pubs);
}

// verifies an op chain from genesis; returns did, latest op, its rotation keys, and who signed it
function verifyPlc(encoded: Uint8Array[]) {
	if (!encoded.length) throw new Error('empty plc chain');
	const ops = encoded.map((b) => dagCbor.decode(b) as any);
	const did = 'did:plc:' + base32.baseEncode(sha256(encoded[0])).slice(0, 24);
	let rotation: Uint8Array[] = ops[0].rotationKeys.map(didKeyToPub);
	let lastSigner: Uint8Array | undefined;
	ops.forEach((op, i) => {
		if (op.type !== 'plc_operation') throw new Error(`unsupported op type: ${op.type}`);
		if (i === 0 ? op.prev !== null : op.prev !== cidOf(encoded[i - 1])) throw new Error(`broken prev at op ${i}`);
		lastSigner = findSigner(unsigned(op), base64url(op.sig), rotation);
		if (!lastSigner) throw new Error(`bad op sig at ${i}`);
		rotation = op.rotationKeys.map(didKeyToPub);
	});
	return { did, latest: ops[ops.length - 1], rotation, lastSigner: lastSigner! };
}

const sameKey = (a: Uint8Array, b: Uint8Array) => Buffer.from(a).equals(Buffer.from(b));

function base64url(s: string): Uint8Array {
	return new Uint8Array(Buffer.from(s, 'base64url'));
}

// MST lookup: returns the value CID string at `key`, or undefined if provably absent
function mstGet(rootCid: string, nodes: Map<string, any>, key: string): string | undefined {
	const target = new TextEncoder().encode(key);
	let cid: string | null = rootCid;
	while (cid) {
		const node = nodes.get(cid);
		if (!node) throw new Error(`missing mst node: ${cid}`);
		let prev = new Uint8Array();
		// descend into the subtree left of the first entry greater than key
		let next: string | null = node.l ? node.l.toString() : null;
		for (const e of node.e) {
			const k = new Uint8Array([...prev.slice(0, e.p), ...e.k]);
			prev = k;
			const c = Buffer.compare(Buffer.from(k), Buffer.from(target));
			if (c === 0) return e.v.toString();
			if (c > 0) break;
			next = e.t ? e.t.toString() : null;
		}
		cid = next;
	}
}

export type Verified = { did: string; handle: string; profile: Profile; rev: string; time: number };

const TID_ALPHABET = '234567abcdefghijklmnopqrstuvwxyz';

// atproto TID -> microseconds since the unix epoch (mirrors Encoding.tidMicros)
export function tidMicros(tid: string): bigint {
	if (tid.length !== 13) throw new Error(`bad tid: ${tid}`);
	let n = 0n;
	for (const c of tid) {
		const v = TID_ALPHABET.indexOf(c);
		if (v < 0) throw new Error(`bad tid: ${tid}`);
		n = (n << 5n) | BigInt(v);
	}
	if (n >> 63n) throw new Error(`bad tid: ${tid}`);
	return n >> 10n;
}

export type VerifyOptions = {
	anchorDid?: string;
	maxAge?: number; // seconds, 0 = no limit
	now?: number; // seconds
};

export function verifyProof(
	handle: string,
	proof: Proof,
	{ anchorDid = ANCHOR_DID, maxAge = 0, now = Math.floor(Date.now() / 1000) }: VerifyOptions = {}
): Verified {
	if (!handle.endsWith(HANDLE_SUFFIX)) throw new Error('bad handle');

	// 1. anchor: its latest rotation keys are the trusted PLC signers
	const anchor = verifyPlc(proof.anchor);
	if (anchor.did !== anchorDid) throw new Error('wrong anchor');

	// 2. account: latest op signed by a trusted signer and claims the handle
	const { did, latest, lastSigner } = verifyPlc(proof.ops);
	if (!anchor.rotation.some((k) => sameKey(k, lastSigner))) throw new Error('untrusted plc signer');
	if (!latest.alsoKnownAs.includes(`at://${handle}`)) throw new Error('handle not claimed');
	const signingKey = didKeyToPub(latest.verificationMethods.atproto);

	// 3. commit
	const commit = dagCbor.decode(proof.commit) as any;
	if (commit.did !== did) throw new Error('commit did mismatch');
	if (commit.version !== 3) throw new Error('unsupported commit version');
	const time = Number(tidMicros(commit.rev) / 1_000_000n);
	if (maxAge && time + maxAge < now) throw new Error(`stale commit: ${time}`);
	if (!verifySig(unsigned(commit), commit.sig, [signingKey])) throw new Error('bad commit sig');

	// 4. MST + records
	const nodes = new Map(proof.nodes.map((b) => [cidOf(b), dagCbor.decode(b)]));
	const root = commit.data.toString();
	if (mstGet(root, nodes, PROFILE_KEY) !== cidOf(proof.profile)) throw new Error('profile not in commit');
	const profile = dagCbor.decode(proof.profile) as any;

	const linkBlocks = new Map(proof.links.map((b) => [cidOf(b), b]));
	const links: Link[] = [];
	for (const ref of profile.links ?? []) {
		const bytes = linkBlocks.get(ref.cid);
		if (!bytes) continue;
		const prefix = `at://${did}/${LINK_COLLECTION}/`;
		if (!ref.uri.startsWith(prefix)) continue;
		if (mstGet(root, nodes, `${LINK_COLLECTION}/${ref.uri.slice(prefix.length)}`) !== ref.cid) continue; // stale ref
		const link = dagCbor.decode(bytes) as any;
		links.push({ url: link.url, title: link.title });
	}

	return {
		did,
		handle,
		rev: commit.rev,
		time,
		profile: {
			description: profile.description,
			displayName: profile.displayName,
			avatarCid: profile.avatar?.ref?.toString(),
			links,
		},
	};
}
