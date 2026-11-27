import { expect, test } from 'bun:test';
import { addr, text, COIN_ETH, COIN_DEFAULT_EVM } from '../src/records.js';

const A = '0x51050ec063d393217B436747617aD1C2285Aeeee';
const B = '0x000000000000000000000000000000000000dEaD';

test('addr: link titled eth wins over bio', () => {
	const p = { description: `eth:${B}`, links: [{ title: 'eth', url: `https://etherscan.io/address/${A}` }] };
	expect(addr(p, COIN_ETH)).toBe(A);
	expect(addr(p, COIN_DEFAULT_EVM)).toBe(A);
	expect(addr(p, 0n)).toBeUndefined();
});

test('addr: bio token must be delimited', () => {
	expect(addr({ description: `hi eth:${A}\nbye`, links: [] }, COIN_ETH)).toBe(A);
	expect(addr({ description: `xeth:${A}`, links: [] }, COIN_ETH)).toBeUndefined();
	expect(addr({ description: `eth:${A}x`, links: [] }, COIN_ETH)).toBeUndefined();
});

test('addr: link must end in /0x..40', () => {
	expect(addr({ links: [{ title: 'eth', url: `https://x.io/${A}/` }] }, COIN_ETH)).toBeUndefined();
	expect(addr({ links: [{ title: 'ETH', url: `https://x.io/${A}` }] }, COIN_ETH)).toBeUndefined();
});

test('text: socials and url', () => {
	const p = {
		links: [
			{ title: 'eth', url: `https://etherscan.io/address/${A}` },
			{ url: 'https://github.com/adraffy/ens-normalize.js' },
			{ url: 'https://x.com/adraffy?s=1' },
			{ url: 'https://raffy.xyz' },
		],
	};
	expect(text(p, 'did:plc:x', 'com.github')).toBe('adraffy');
	expect(text(p, 'did:plc:x', 'com.twitter')).toBe('adraffy');
	expect(text(p, 'did:plc:x', 'url')).toBe('https://raffy.xyz');
});
