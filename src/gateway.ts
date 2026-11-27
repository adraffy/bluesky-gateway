// CCIP-Read gateway: serves proveProfile(handle) for BlueskyResolver using @adraffy/ezccip.
// Unsigned ("raw" protocol): the resolver verifies everything, including handle -> did.

import { CCIPReadError, EZCCIP } from '@adraffy/ezccip';
import { bytesToHex } from 'viem';
import { fetchAnchor, fetchProof, HANDLE_SUFFIX, type Proof } from './bluesky.js';

export const PROVE_PROFILE =
	'function proveProfile(string handle) view returns (bytes[] anchor, bytes[] ops, bytes commit, bytes[] nodes, bytes profile, bytes[] links)';

type Cached<T> = { exp: number; value: Promise<T> };

function cached<T>(map: Map<string, Cached<T>>, key: string, ms: number, fn: () => Promise<T>): Promise<T> {
	const now = Date.now();
	let hit = map.get(key);
	if (!hit || hit.exp < now) {
		hit = { exp: now + ms, value: fn() };
		hit.value.catch(() => map.delete(key));
		map.set(key, hit);
	}
	return hit.value;
}

export function createGateway({
	cacheMs = 30_000,
	anchorCacheMs = 300_000,
	fetcher = fetchProof,
}: {
	cacheMs?: number;
	anchorCacheMs?: number;
	fetcher?: typeof fetchProof;
} = {}) {
	const proofs = new Map<string, Cached<Proof>>();
	const anchors = new Map<string, Cached<Uint8Array[]>>();
	const ezccip = new EZCCIP({ protocol: 'raw' });
	ezccip.addFunctionHandler(PROVE_PROFILE, async ([handle]) => {
		if (!handle.endsWith(HANDLE_SUFFIX)) throw new CCIPReadError('expected *.bsky.social', { status: 400 });
		const p = await cached(proofs, handle, cacheMs, () =>
			fetcher(handle, { anchor: cached(anchors, '', anchorCacheMs, () => fetchAnchor()) })
		);
		const hex = (v: Uint8Array[]) => v.map((x) => bytesToHex(x));
		return [hex(p.anchor), hex(p.ops), bytesToHex(p.commit), hex(p.nodes), bytesToHex(p.profile), hex(p.links)];
	});
	return ezccip;
}
