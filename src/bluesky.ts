// Fetches everything needed to prove a bsky.social profile (and its links) on-chain.
// The gateway is untrusted: every byte returned here is checked by the contract against
// hashes and signatures. handle -> did is accepted on-chain when the account's latest PLC op
// claims the handle and was signed by a rotation key of the anchor DID (bsky.app).

import * as dagCbor from '@ipld/dag-cbor';
import { CarReader } from '@ipld/car';
import { CID } from 'multiformats/cid';

export const HANDLE_SUFFIX = '.bsky.social';
export const PROFILE_KEY = 'app.bsky.actor.profile/self';
export const LINK_COLLECTION = 'app.bsky.actor.link';
export const MAX_LINKS = 10;
export const ANCHOR_DID = 'did:plc:z72i7hdynmk6r22z27h6tvur'; // bsky.app

export type Proof = {
	did: string;
	anchor: Uint8Array[]; // signed PLC ops of ANCHOR_DID (DAG-CBOR), genesis -> latest
	ops: Uint8Array[]; // signed PLC ops (DAG-CBOR), genesis -> latest
	commit: Uint8Array; // signed repo commit (DAG-CBOR)
	nodes: Uint8Array[]; // MST nodes (DAG-CBOR), deduplicated, any order
	profile: Uint8Array; // app.bsky.actor.profile/self (DAG-CBOR)
	links: Uint8Array[]; // app.bsky.actor.link records, in profile order
};

const HANDLE_LABEL = /^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$/;

/** "adraffy", "@adraffy", "adraffy.bsky.social" or "@Adraffy.bsky.social" -> "adraffy.bsky.social" */
export function normalizeHandle(input: string): string {
	let s = input.trim().toLowerCase();
	if (s.startsWith('@')) s = s.slice(1);
	const label = s.endsWith(HANDLE_SUFFIX) ? s.slice(0, -HANDLE_SUFFIX.length) : s;
	if (!HANDLE_LABEL.test(label)) throw new Error(`invalid bsky.social username: ${input}`);
	return label + HANDLE_SUFFIX;
}
const DID_PLC = /^did:plc:[a-z2-7]{24}$/;

async function fetchOk(url: string): Promise<Response> {
	const res = await fetch(url);
	if (!res.ok) throw new Error(`${res.status} ${url}`);
	return res;
}

export async function resolveHandle(handle: string): Promise<string> {
	const did = (await (await fetchOk(`https://${handle}/.well-known/atproto-did`)).text()).trim();
	if (!DID_PLC.test(did)) throw new Error(`unsupported did: ${did}`);
	return did;
}

export async function fetchPlcOps(did: string): Promise<any[]> {
	// /log returns the current valid (non-nullified) chain, genesis first
	const ops: any[] = await (await fetchOk(`https://plc.directory/${did}/log`)).json();
	if (!ops.length) throw new Error(`empty plc log: ${did}`);
	return ops;
}

function pdsFromOp(op: any): string {
	const url = op?.services?.atproto_pds?.endpoint;
	if (typeof url !== 'string' || !url.startsWith('https://')) throw new Error('missing pds');
	return url;
}

type RecordCar = { root: CID; blocks: Map<string, Uint8Array>; record: Uint8Array };

async function fetchRecordCar(pds: string, did: string, collection: string, rkey: string): Promise<RecordCar> {
	const url = `${pds}/xrpc/com.atproto.sync.getRecord?did=${did}&collection=${collection}&rkey=${rkey}`;
	const car = await CarReader.fromBytes(new Uint8Array(await (await fetchOk(url)).arrayBuffer()));
	const [root] = await car.getRoots();
	const blocks = new Map<string, Uint8Array>();
	let record: Uint8Array | undefined;
	for await (const { cid, bytes } of car.blocks()) {
		blocks.set(cid.toString(), bytes);
		const v: any = dagCbor.decode(bytes);
		if (typeof v?.$type === 'string') record = bytes;
	}
	if (!root || !record) throw new Error(`bad record car: ${collection}/${rkey}`);
	return { root, blocks, record };
}

export async function fetchAnchor(did = ANCHOR_DID): Promise<Uint8Array[]> {
	return (await fetchPlcOps(did)).map((op) => dagCbor.encode(op));
}

export async function fetchProof(
	handle: string,
	{ retries = 3, anchor }: { retries?: number; anchor?: Promise<Uint8Array[]> } = {}
): Promise<Proof> {
	const anchorOps = anchor ?? fetchAnchor();
	anchorOps.catch(() => {}); // awaited below; avoid an unhandled rejection if we throw first
	if (!handle.endsWith(HANDLE_SUFFIX)) throw new Error(`expected *${HANDLE_SUFFIX}`);
	if (!HANDLE_LABEL.test(handle.slice(0, -HANDLE_SUFFIX.length))) throw new Error(`invalid handle: ${handle}`);
	const did = await resolveHandle(handle);
	const opsJson = await fetchPlcOps(did);
	const latest = opsJson[opsJson.length - 1];
	if (!latest.alsoKnownAs?.includes(`at://${handle}`)) throw new Error(`did does not claim handle`);
	const pds = pdsFromOp(latest);
	const ops = opsJson.map((op) => dagCbor.encode(op));

	// the profile and link proofs are fetched separately and must share one commit
	for (let attempt = 0; attempt < retries; attempt++) {
		const profile = await fetchRecordCar(pds, did, 'app.bsky.actor.profile', 'self');
		const refs: { uri: string; cid: string }[] = (dagCbor.decode(profile.record) as any).links ?? [];
		const prefix = `at://${did}/${LINK_COLLECTION}/`;
		const linkCars = await Promise.all(
			refs
				.slice(0, MAX_LINKS)
				.filter((ref) => ref.uri.startsWith(prefix))
				.map((ref) => fetchRecordCar(pds, did, LINK_COLLECTION, ref.uri.slice(prefix.length)))
		);
		if (linkCars.some((x) => !x.root.equals(profile.root))) continue; // repo changed mid-fetch
		const commitKey = profile.root.toString();
		const records = new Set([profile.record, ...linkCars.map((x) => x.record)]);
		const nodes = new Map<string, Uint8Array>();
		for (const car of [profile, ...linkCars]) {
			for (const [cid, bytes] of car.blocks) {
				if (cid !== commitKey && !records.has(bytes)) nodes.set(cid, bytes);
			}
		}
		return {
			did,
			anchor: await anchorOps,
			ops,
			commit: profile.blocks.get(commitKey)!,
			nodes: [...nodes.values()],
			profile: profile.record,
			links: linkCars.map((x) => x.record),
		};
	}
	throw new Error('repo kept changing, try again');
}
