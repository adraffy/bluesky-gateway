// Fetch and verify the proof for a bsky.social account, and show the ENS records it yields.
//
// usage: bun scripts/prove.ts <username> [--json] [--max-age <seconds>]
//   <username>   adraffy | @adraffy | adraffy.bsky.social
//   --json       print machine-readable output, including the ABI-encoded gateway response
//   --max-age    also enforce the resolver's max-age check (seconds, 0 = off)

import { parseArgs } from 'node:util';
import { bytesToHex, encodeFunctionResult, parseAbi } from 'viem';
import { fetchProof, normalizeHandle, ANCHOR_DID, type Proof } from '../src/bluesky.js';
import { verifyProof, type Verified } from '../src/verify.js';
import { addr, text, COIN_ETH } from '../src/records.js';
import { PROVE_PROFILE } from '../src/gateway.js';

const TEXT_KEYS = ['name', 'description', 'avatar', 'url', 'com.github', 'com.twitter'];

const { values, positionals } = parseArgs({
	allowPositionals: true,
	options: {
		json: { type: 'boolean', default: false },
		'max-age': { type: 'string', default: '0' },
		help: { type: 'boolean', short: 'h', default: false },
	},
});

if (values.help || positionals.length !== 1) {
	console.error('usage: bun scripts/prove.ts <username> [--json] [--max-age <seconds>]');
	process.exit(values.help ? 0 : 2);
}

const maxAge = Number(values['max-age']);
if (!Number.isSafeInteger(maxAge) || maxAge < 0) {
	console.error(`invalid --max-age: ${values['max-age']}`);
	process.exit(2);
}

function encodeResponse(p: Proof): `0x${string}` {
	const hex = (v: Uint8Array[]) => v.map((x) => bytesToHex(x));
	return encodeFunctionResult({
		abi: parseAbi([PROVE_PROFILE]),
		functionName: 'proveProfile',
		result: [hex(p.anchor), hex(p.ops), bytesToHex(p.commit), hex(p.nodes), bytesToHex(p.profile), hex(p.links)],
	});
}

function records(v: Verified) {
	const out: Record<string, string | null> = { 'addr(60)': addr(v.profile, COIN_ETH) ?? null };
	for (const key of TEXT_KEYS) out[key] = text(v.profile, v.did, key) ?? null;
	return out;
}

const plural = (n: number, word: string) => `${n} ${word}${n === 1 ? '' : 's'}`;

function ago(sec: number): string {
	const d = Math.floor(Date.now() / 1000) - sec;
	if (d < 0) return 'in the future';
	if (d < 3600) return `${Math.floor(d / 60)}m ago`;
	if (d < 86400) return `${Math.floor(d / 3600)}h ago`;
	return `${Math.floor(d / 86400)}d ago`;
}

let handle: string;
try {
	handle = normalizeHandle(positionals[0]);
} catch (err: any) {
	console.error(err.message);
	process.exit(2);
}

try {
	const proof = await fetchProof(handle);
	const v = verifyProof(handle, proof, { maxAge });
	const response = encodeResponse(proof);
	const recs = records(v);

	if (values.json) {
		console.log(
			JSON.stringify(
				{
					handle,
					did: v.did,
					anchorDid: ANCHOR_DID,
					plcSigner: v.plcSigner,
					rev: v.rev,
					time: v.time,
					records: recs,
					links: v.profile.links,
					response,
				},
				null,
				'\t'
			)
		);
	} else {
		const row = (k: string, val: string) => console.log(`${k.padEnd(15)} ${val}`);
		row('handle', handle);
		row('did', v.did);
		row('plc', `${plural(proof.ops.length, 'op')}, latest signed by ${v.plcSigner}`);
		row('anchor', `${ANCHOR_DID} (bsky.app, ${plural(proof.anchor.length, 'op')})`);
		row('commit', `${v.rev}  ${new Date(v.time * 1000).toISOString()}  (${ago(v.time)})`);
		row('proof', `${(response.length - 2) / 2} bytes (${plural(proof.nodes.length, 'MST node')}, ${plural(proof.links.length, 'link')})`);
		console.log('\nrecords');
		for (const [k, val] of Object.entries(recs)) row(`  ${k}`, val ?? '—');
		if (v.profile.links.length) {
			console.log('\nlinks');
			for (const link of v.profile.links) row(`  ${link.title || '(untitled)'}`, link.url);
		}
		console.log(`\n✓ verified${maxAge ? ` (max-age ${maxAge}s)` : ''}`);
	}
} catch (err: any) {
	console.error(`✗ ${handle}: ${err.message}`);
	process.exit(1);
}
