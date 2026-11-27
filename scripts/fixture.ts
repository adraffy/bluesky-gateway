// Records a live proof for a handle into test/fixtures/<handle>.json
// usage: bun scripts/fixture.ts adraffy.bsky.social
//
// Also writes `rogueOps`: a self-signed did:plc genesis op claiming the same handle,
// which the resolver must reject (its signer isn't one of the anchor's rotation keys).

import { mkdirSync, writeFileSync } from 'node:fs';
import * as dagCbor from '@ipld/dag-cbor';
import { secp256k1 } from '@noble/curves/secp256k1.js';
import { base58btc } from 'multiformats/bases/base58';
import { bytesToHex } from 'viem';
import { errorMessage, type PlcOp } from '../src/atproto.js';
import { ANCHOR_DID, fetchProof } from '../src/bluesky.js';
import { addr, COIN_ETH, text } from '../src/records.js';
import { verifyProof } from '../src/verify.js';

const hexlify = (x: Uint8Array) => bytesToHex(x);

function rogueGenesis(handle: string): Uint8Array {
	const sk = secp256k1.utils.randomSecretKey();
	const didKey = `did:key:${base58btc.encode(new Uint8Array([0xe7, 0x01, ...secp256k1.getPublicKey(sk, true)]))}`;
	const op: Omit<PlcOp, 'sig'> = {
		type: 'plc_operation',
		rotationKeys: [didKey],
		verificationMethods: { atproto: didKey },
		alsoKnownAs: [`at://${handle}`],
		services: { atproto_pds: { type: 'AtprotoPersonalDataServer', endpoint: 'https://example.com' } },
		prev: null,
	};
	const sig = secp256k1.sign(dagCbor.encode(op), sk, { prehash: true, lowS: true });
	return dagCbor.encode({ ...op, sig: Buffer.from(sig).toString('base64url') });
}

const handle = process.argv[2] ?? 'adraffy.bsky.social';
const proof = await fetchProof(handle);
const v = verifyProof(handle, proof);
console.log({
	did: v.did,
	rev: v.rev,
	time: new Date(v.time * 1000).toISOString(),
	eth: addr(v.profile, COIN_ETH),
	avatar: text(v.profile, v.did, 'avatar'),
	links: v.profile.links,
});

const rogueOps = [rogueGenesis(handle)];
try {
	verifyProof(handle, { ...proof, ops: rogueOps });
	throw new Error('rogue op was accepted');
} catch (err) {
	if (errorMessage(err) !== 'untrusted plc signer') throw err;
}

mkdirSync('test/fixtures', { recursive: true });
writeFileSync(
	`test/fixtures/${handle}.json`,
	JSON.stringify(
		{
			handle,
			did: proof.did,
			anchorDid: ANCHOR_DID,
			anchor: proof.anchor.map(hexlify),
			ops: proof.ops.map(hexlify),
			commit: hexlify(proof.commit),
			nodes: proof.nodes.map(hexlify),
			profile: hexlify(proof.profile),
			links: proof.links.map(hexlify),
			rogueOps: rogueOps.map(hexlify),
			expected: {
				time: v.time,
				eth: addr(v.profile, COIN_ETH) ?? null,
				name: text(v.profile, v.did, 'name') ?? null,
				description: text(v.profile, v.did, 'description') ?? null,
				avatar: text(v.profile, v.did, 'avatar') ?? null,
				url: text(v.profile, v.did, 'url') ?? null,
			},
		},
		null,
		'\t'
	)
);
console.log(`wrote test/fixtures/${handle}.json`);
