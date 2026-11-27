// Record semantics shared by the TS reference verifier and BlueskyResolver.sol.
// Keep these two in sync.

export const AVATAR_CDN = 'https://cdn.bsky.app/img/avatar/plain/';
export const COIN_ETH = 60n;
export const COIN_DEFAULT_EVM = 0x80000000n; // ENSIP-19 default EVM address
export const COIN_BASE = 0x80000000n | 8453n; // ENSIP-11: 0x80000000 | chainId
export const COIN_ARBITRUM = 0x80000000n | 42161n;
export const COIN_LINEA = 0x80000000n | 59144n;
export const COIN_CELO = 0x80000000n | 42220n;
export const COIN_OPTIMISM = 0x80000000n | 10n;

// block explorers whose address pages map to a coin type: {prefix}0x<40 hex>[#default]
export const EXPLORERS: [prefix: string, coinType: bigint][] = [
	['https://etherscan.io/address/', COIN_ETH],
	['https://basescan.org/address/', COIN_BASE],
	['https://arbiscan.io/address/', COIN_ARBITRUM],
	['https://lineascan.build/address/', COIN_LINEA],
	['https://celoscan.io/address/', COIN_CELO],
	['https://optimistic.etherscan.io/address/', COIN_OPTIMISM],
];
const DEFAULT_SUFFIX = '#default'; // a URL fragment, so the explorer never sees it

export type Link = { url: string; title?: string };
export type Profile = { description?: string; displayName?: string; avatarCid?: string; links: Link[] };

const SOCIAL: [prefix: string, key: string][] = [
	['https://github.com/', 'com.github'],
	['https://x.com/', 'com.twitter'],
	['https://twitter.com/', 'com.twitter'],
];

const ADDR_HEX = /^0x[0-9a-fA-F]{40}$/;

export type AddressLink = { coinType: bigint; address: string; isDefault: boolean };

// "{explorer}/address/0x<40 hex>" with an optional "#default" suffix
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

// ENSIP-19 chainFromCoinType: 1 for coin type 60, the chain id for 0x80000000 | chainId, else 0
// (non-EVM, or the default coin type itself)
export function chainFromCoinType(coinType: bigint): bigint {
	if (coinType === COIN_ETH) return 1n;
	const x = coinType ^ COIN_DEFAULT_EVM;
	return x < COIN_DEFAULT_EVM ? x : 0n;
}

// like ENS's AddrResolver: the first explorer link for that chain (in profile order), else, for any EVM
// coin type, the first link marked #default. COIN_DEFAULT_EVM itself comes only from a #default link.
export function addr(profile: Profile, coinType: bigint): string | undefined {
	const links = profile.links.map((x) => addressLink(x.url)).filter((x) => x !== undefined);
	if (coinType !== COIN_DEFAULT_EVM) {
		const a = links.find((x) => x.coinType === coinType);
		if (a) return a.address;
		if (!chainFromCoinType(coinType)) return; // non-EVM: no default
	}
	return links.find((x) => x.isDefault)?.address;
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
