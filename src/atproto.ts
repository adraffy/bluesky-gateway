// Shapes of the atproto objects this project reads. Decoded data is untrusted: these types describe
// what well-formed objects look like, and every value is still checked by the verifiers.

import type { CID } from 'multiformats/cid';

/** did:plc operation (JSON from plc.directory, DAG-CBOR when hashed or signed) */
export type PlcOp = {
	type: string;
	rotationKeys: string[];
	verificationMethods: Record<string, string>;
	alsoKnownAs: string[];
	services: Record<string, { type: string; endpoint: string }>;
	prev: string | null;
	sig: string;
};

/** signed repo commit (v3) */
export type Commit = {
	did: string;
	version: number;
	data: CID; // MST root
	rev: string; // TID
	prev: CID | null;
	sig: Uint8Array;
};

/** MST node: `l` is the leftmost subtree; each entry's key is `prefix(prev, p) + k` */
export type MstNode = {
	l: CID | null;
	e: { p: number; k: Uint8Array; v: CID; t: CID | null }[];
};

/** com.atproto.repo.strongRef */
export type StrongRef = { uri: string; cid: string };

/** app.bsky.actor.profile */
export type ProfileRecord = {
	$type: string;
	displayName?: string;
	description?: string;
	avatar?: { ref: CID };
	links?: StrongRef[];
};

/** app.bsky.actor.link */
export type LinkRecord = { url: string; title?: string };

/** message of a thrown value, for CLI output */
export function errorMessage(err: unknown): string {
	return err instanceof Error ? err.message : String(err);
}
