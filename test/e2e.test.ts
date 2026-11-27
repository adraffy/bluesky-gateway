// End-to-end: anvil + BlueskyResolver + ezccip gateway + live bsky.social data.
// bun test test/e2e.test.ts

import { afterAll, beforeAll, expect, test } from 'bun:test';
import { Foundry } from '@adraffy/blocksmith';
import { serveEZCCIP } from '@adraffy/ezccip/serve';
import { EnsResolver, Interface, dnsEncode, namehash, toUtf8Bytes } from 'ethers';
import { createGateway } from '../src/gateway.js';
import { fetchProof, ANCHOR_DID } from '../src/bluesky.js';
import { verifyProof } from '../src/verify.js';
import { addr, text, COIN_ETH } from '../src/records.js';

const HANDLE = 'adraffy.bsky.social';
const NAME = 'adraffy.bsky.eth';

let foundry: Foundry;
let ccip: Awaited<ReturnType<typeof serveEZCCIP>>;
let resolver: any;
let expected: { eth?: string; avatar?: string; description?: string; github?: string };

beforeAll(async () => {
	const v = verifyProof(HANDLE, await fetchProof(HANDLE));
	expected = {
		eth: addr(v.profile, COIN_ETH),
		avatar: text(v.profile, v.did, 'avatar'),
		description: text(v.profile, v.did, 'description'),
		github: text(v.profile, v.did, 'com.github'),
	};
	foundry = await Foundry.launch({ infoLog: false });
	ccip = await serveEZCCIP(createGateway(), { log: false });
	resolver = await foundry.deploy({
		file: 'BlueskyResolver',
		// maxAge = 0: live data, so don't depend on how recently the account posted (covered by forge tests)
		args: [[ccip.endpoint], namehash('bsky.eth'), toUtf8Bytes(ANCHOR_DID), 0],
	});
}, 60_000);

afterAll(async () => {
	await ccip?.shutdown();
	await foundry?.shutdown();
});

test('resolve() via CCIP-Read', async () => {
	const ens = new EnsResolver(foundry.provider, resolver.target, NAME);
	expect(await ens.supportsWildcard()).toBe(true);
	expect(await ens.getAddress()).toBe(expected.eth!);
	expect(await ens.getText('avatar')).toBe(expected.avatar ?? '');
	expect(await ens.getText('description')).toBe(expected.description ?? '');
	expect(await ens.getText('com.github')).toBe(expected.github ?? '');
	expect(await ens.getText('not-a-key')).toBe('');
}, 60_000);

test('resolve(name, multicall([...])) in one CCIP-Read round trip', async () => {
	const abi = new Interface([
		'function addr(bytes32) view returns (address)',
		'function text(bytes32, string) view returns (string)',
		'function multicall(bytes[]) view returns (bytes[])',
	]);
	const node = namehash(NAME);
	const calls = [abi.encodeFunctionData('addr', [node]), abi.encodeFunctionData('text', [node, 'avatar'])];
	const answer = await resolver.resolve(dnsEncode(NAME), abi.encodeFunctionData('multicall', [calls]), {
		enableCcipRead: true,
	});
	const [results] = abi.decodeFunctionResult('multicall', answer);
	expect(abi.decodeFunctionResult('addr', results[0])[0]).toBe(expected.eth!);
	expect(abi.decodeFunctionResult('text', results[1])[0]).toBe(expected.avatar ?? '');
}, 60_000);

test('rejects names outside the parent', async () => {
	const call = resolver.resolve(dnsEncode('adraffy.other.eth'), '0x3b3b57de' + '00'.repeat(32), { enableCcipRead: true });
	await expect(call).rejects.toThrow();
});
