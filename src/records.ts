// Record semantics shared by the TS reference verifier and BlueskyResolver.sol.
// Keep these two in sync.

export const AVATAR_CDN = 'https://cdn.bsky.app/img/avatar/plain/';
export const COIN_ETH = 60n;
export const COIN_DEFAULT_EVM = 0x80000000n; // ENSIP-19 default EVM address

export type Link = { url: string; title?: string };
export type Profile = { description?: string; displayName?: string; avatarCid?: string; links: Link[] };

const SOCIAL: [prefix: string, key: string][] = [
	['https://github.com/', 'com.github'],
	['https://x.com/', 'com.twitter'],
	['https://twitter.com/', 'com.twitter'],
];

const ADDR_HEX = /^0x[0-9a-fA-F]{40}$/;

// link titled "eth" whose URL ends in "/0x<40 hex>"
function linkAddr(link: Link): string | undefined {
	if (link.title !== 'eth') return;
	const tail = link.url.slice(-42);
	if (link.url.length > 42 && link.url[link.url.length - 43] === '/' && ADDR_HEX.test(tail)) return tail;
}

// "eth:0x<40 hex>" token in the bio, delimited by start/end or ASCII whitespace
function bioAddr(bio: string): string | undefined {
	const m = bio.match(/(?:^|[ \t\r\n])eth:(0x[0-9a-fA-F]{40})(?=$|[ \t\r\n])/);
	return m?.[1];
}

function social(url: string): [key: string, value: string] | undefined {
	for (const [prefix, key] of SOCIAL) {
		if (url.startsWith(prefix)) {
			const rest = url.slice(prefix.length);
			const end = rest.search(/[/?#]/);
			const value = end < 0 ? rest : rest.slice(0, end);
			if (value) return [key, value];
		}
	}
}

export function addr(profile: Profile, coinType: bigint): string | undefined {
	if (coinType !== COIN_ETH && coinType !== COIN_DEFAULT_EVM) return;
	for (const link of profile.links) {
		const a = linkAddr(link);
		if (a) return a;
	}
	if (profile.description) return bioAddr(profile.description);
}

export function text(profile: Profile, did: string, key: string): string | undefined {
	switch (key) {
		case 'name':
			return profile.displayName;
		case 'description':
			return profile.description;
		case 'avatar':
			return profile.avatarCid ? `${AVATAR_CDN}${did}/${profile.avatarCid}@jpeg` : undefined;
		case 'url':
			return profile.links.find((x) => !linkAddr(x) && !social(x.url))?.url;
	}
	for (const link of profile.links) {
		const s = social(link.url);
		if (s && s[0] === key) return s[1];
	}
}
