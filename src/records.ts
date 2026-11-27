// Record semantics shared by the TS reference verifier and BlueskyResolver.sol.
// Keep these two in sync.

export const AVATAR_CDN = 'https://cdn.bsky.app/img/avatar/plain/';
export const COIN_ETH = 60n;
export const COIN_DEFAULT_EVM = 0x80000000n; // ENSIP-19 default EVM address
export const COIN_BASE = 0x80000000n | 8453n; // ENSIP-11: 0x80000000 | chainId
export const COIN_ARBITRUM = 0x80000000n | 42161n;

// block explorers whose address pages map to a coin type: {prefix}0x<40 hex>[?default]
export const EXPLORERS: [prefix: string, coinType: bigint][] = [
	['https://etherscan.io/address/', COIN_ETH],
	['https://basescan.org/address/', COIN_BASE],
	['https://arbiscan.io/address/', COIN_ARBITRUM],
];
const DEFAULT_SUFFIX = '?default';

export type Link = { url: string; title?: string };
export type Profile = { description?: string; displayName?: string; avatarCid?: string; links: Link[] };

const SOCIAL: [prefix: string, key: string][] = [
	['https://github.com/', 'com.github'],
	['https://x.com/', 'com.twitter'],
	['https://twitter.com/', 'com.twitter'],
];

const ADDR_HEX = /^0x[0-9a-fA-F]{40}$/;

export type AddressLink = { coinType: bigint; address: string; isDefault: boolean };

// "{explorer}/address/0x<40 hex>" with an optional "?default" suffix
export function addressLink(url: string): AddressLink | undefined {
	for (const [prefix, coinType] of EXPLORERS) {
		if (!url.startsWith(prefix)) continue;
		const rest = url.slice(prefix.length);
		const isDefault = rest.endsWith(DEFAULT_SUFFIX);
		const address = isDefault ? rest.slice(0, -DEFAULT_SUFFIX.length) : rest;
		if (ADDR_HEX.test(address)) return { coinType, address, isDefault };
	}
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

// first matching explorer link, in profile order; the default address only comes from a "?default" link
export function addr(profile: Profile, coinType: bigint): string | undefined {
	for (const link of profile.links) {
		const a = addressLink(link.url);
		if (a && (coinType === COIN_DEFAULT_EVM ? a.isDefault : a.coinType === coinType)) return a.address;
	}
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
			return profile.links.find((x) => !addressLink(x.url) && !social(x.url))?.url;
	}
	for (const link of profile.links) {
		const s = social(link.url);
		if (s && s[0] === key) return s[1];
	}
}
