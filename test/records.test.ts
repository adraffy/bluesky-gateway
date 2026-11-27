import { expect, test } from 'bun:test';
import {
	addr,
	COIN_ARBITRUM,
	COIN_BASE,
	COIN_CELO,
	COIN_DEFAULT_EVM,
	COIN_ETH,
	COIN_LINEA,
	COIN_OPTIMISM,
	chainFromCoinType,
	text,
} from '../src/records.js';

// mirrored by the test_records_* forge tests in test/sol/BlueskyResolver.t.sol

const A = '0x51050ec063d393217B436747617aD1C2285Aeeee';
const B = '0x000000000000000000000000000000000000dEaD';
const C = '0x00000000000000000000000000000000000000cc';
const COIN_POLYGON = 0x80000000n | 137n; // no explorer support: only reachable via #default
const COIN_BTC = 0n;

const links = (...urls: string[]) => ({ links: urls.map((url) => ({ url })) });

test('chainFromCoinType (ENSIP-19)', () => {
	expect(chainFromCoinType(COIN_ETH)).toBe(1n);
	expect(chainFromCoinType(COIN_BASE)).toBe(8453n);
	expect(chainFromCoinType(COIN_POLYGON)).toBe(137n);
	expect(chainFromCoinType(COIN_DEFAULT_EVM)).toBe(0n);
	expect(chainFromCoinType(COIN_BTC)).toBe(0n);
	expect(chainFromCoinType(0x100000000n)).toBe(0n);
});

test('addr: explorer host picks the coin type; title is ignored', () => {
	const p = links(
		`https://etherscan.io/address/${A}`,
		`https://basescan.org/address/${B}`,
		`https://arbiscan.io/address/${C}`,
		`https://lineascan.build/address/${B}`,
		`https://celoscan.io/address/${C}`,
		`https://optimistic.etherscan.io/address/${A}`
	);
	expect(addr(p, COIN_ETH)).toBe(A);
	expect(addr(p, COIN_BASE)).toBe(B);
	expect(addr(p, COIN_ARBITRUM)).toBe(C);
	expect(addr(p, COIN_LINEA)).toBe(B);
	expect(addr(p, COIN_CELO)).toBe(C);
	expect(addr(p, COIN_OPTIMISM)).toBe(A);
	expect(chainFromCoinType(COIN_LINEA)).toBe(59144n);
	expect(chainFromCoinType(COIN_CELO)).toBe(42220n);
	expect(addr(p, COIN_POLYGON)).toBeUndefined(); // no #default
	expect(addr(p, COIN_DEFAULT_EVM)).toBeUndefined();
	expect(addr({ links: [{ title: 'whatever', url: `https://etherscan.io/address/${A}` }] }, COIN_ETH)).toBe(A);
});

test('addr: #default is the default address and the EVM fallback', () => {
	const p = links(`https://etherscan.io/address/${A}#default`, `https://basescan.org/address/${B}`);
	expect(addr(p, COIN_DEFAULT_EVM)).toBe(A);
	expect(addr(p, COIN_ETH)).toBe(A); // its own chain
	expect(addr(p, COIN_BASE)).toBe(B); // chain-specific link wins over the default
	expect(addr(p, COIN_ARBITRUM)).toBe(A); // known chain without a link: default
	expect(addr(p, COIN_POLYGON)).toBe(A); // unsupported EVM chain: default
	expect(addr(p, COIN_BTC)).toBeUndefined(); // non-EVM: no default
	// any explorer can carry it; mainnet falls back too
	const q = links(`https://basescan.org/address/${B}#default`);
	expect(addr(q, COIN_DEFAULT_EVM)).toBe(B);
	expect(addr(q, COIN_ETH)).toBe(B);
});

test('addr: first matching link wins, including #default', () => {
	expect(addr(links(`https://etherscan.io/address/${A}`, `https://etherscan.io/address/${B}`), COIN_ETH)).toBe(A);
	const p = links(`https://basescan.org/address/${B}#default`, `https://etherscan.io/address/${A}#default`);
	expect(addr(p, COIN_DEFAULT_EVM)).toBe(B);
	expect(addr(p, COIN_ETH)).toBe(A); // chain-specific still wins
});

test('addr: strict URL format', () => {
	for (const url of [
		`https://etherscan.io/address/${A}/`,
		`https://etherscan.io/address/${A}?a=1`,
		`https://etherscan.io/address/${A}?default`,
		`https://etherscan.io/address/${A}#defaultx`,
		`https://etherscan.io/address/${A}#`,
		`https://etherscan.io/address/${A.slice(0, -1)}`,
		`https://etherscan.io/token/${A}`,
		`http://etherscan.io/address/${A}`,
		`https://sepolia.etherscan.io/address/${A}`,
		`https://basescan.io/address/${A}`,
		`https://x.io/${A}`,
	]) {
		expect(addr(links(url), COIN_ETH)).toBeUndefined();
		expect(addr(links(url), COIN_DEFAULT_EVM)).toBeUndefined();
	}
});

test('addr: bio is not parsed', () => {
	expect(addr({ description: `eth:${A}`, links: [] }, COIN_ETH)).toBeUndefined();
});

test('text: socials and url', () => {
	const p = links(
		`https://etherscan.io/address/${A}`,
		`https://basescan.org/address/${B}#default`,
		'https://github.com/adraffy/ens-normalize.js',
		'https://x.com/adraffy?s=1',
		'https://raffy.xyz'
	);
	expect(text(p, 'did:plc:x', 'com.github')).toBe('adraffy');
	expect(text(p, 'did:plc:x', 'com.twitter')).toBe('adraffy');
	expect(text(p, 'did:plc:x', 'url')).toBe('https://raffy.xyz');
});
