import { expect, test } from 'bun:test';
import { addr, COIN_ARBITRUM, COIN_BASE, COIN_DEFAULT_EVM, COIN_ETH, text } from '../src/records.js';

// mirrored by the test_records_* forge tests in test/sol/BlueskyResolver.t.sol

const A = '0x51050ec063d393217B436747617aD1C2285Aeeee';
const B = '0x000000000000000000000000000000000000dEaD';
const C = '0x00000000000000000000000000000000000000cc';

const links = (...urls: string[]) => ({ links: urls.map((url) => ({ url })) });

test('addr: explorer host picks the coin type; title is ignored', () => {
	const p = links(
		`https://etherscan.io/address/${A}`,
		`https://basescan.org/address/${B}`,
		`https://arbiscan.io/address/${C}`
	);
	expect(addr(p, COIN_ETH)).toBe(A);
	expect(addr(p, COIN_BASE)).toBe(B);
	expect(addr(p, COIN_ARBITRUM)).toBe(C);
	expect(addr(p, 0n)).toBeUndefined(); // bitcoin: unsupported
	expect(addr({ links: [{ title: 'whatever', url: `https://etherscan.io/address/${A}` }] }, COIN_ETH)).toBe(A);
});

test('addr: default only from a ?default link, no fallback between coin types', () => {
	expect(addr(links(`https://etherscan.io/address/${A}`), COIN_DEFAULT_EVM)).toBeUndefined();
	expect(addr(links(`https://basescan.org/address/${B}`), COIN_ETH)).toBeUndefined();
	const p = links(`https://etherscan.io/address/${A}?default`, `https://basescan.org/address/${B}`);
	expect(addr(p, COIN_DEFAULT_EVM)).toBe(A);
	expect(addr(p, COIN_ETH)).toBe(A); // a ?default link still counts for its own chain
	expect(addr(p, COIN_BASE)).toBe(B);
	expect(addr(links(`https://basescan.org/address/${B}?default`), COIN_DEFAULT_EVM)).toBe(B);
});

test('addr: first matching link wins', () => {
	const p = links(`https://etherscan.io/address/${A}`, `https://etherscan.io/address/${B}`);
	expect(addr(p, COIN_ETH)).toBe(A);
});

test('addr: strict URL format', () => {
	for (const url of [
		`https://etherscan.io/address/${A}/`,
		`https://etherscan.io/address/${A}?a=1`,
		`https://etherscan.io/address/${A}?defaultx`,
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
		`https://basescan.org/address/${B}?default`,
		'https://github.com/adraffy/ens-normalize.js',
		'https://x.com/adraffy?s=1',
		'https://raffy.xyz'
	);
	expect(text(p, 'did:plc:x', 'com.github')).toBe('adraffy');
	expect(text(p, 'did:plc:x', 'com.twitter')).toBe('adraffy');
	expect(text(p, 'did:plc:x', 'url')).toBe('https://raffy.xyz');
});
