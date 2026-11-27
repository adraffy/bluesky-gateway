// End-to-end: anvil + BlueskyResolver + ezccip gateway + live bsky.social data.
// bun test test/e2e.test.ts   (needs anvil + forge on PATH, and network access)
// blocksmith launches anvil and deploys; all calls and encoding use viem + ezccip's resolverAbi.

import { afterAll, beforeAll, expect, test } from 'bun:test';
import { Foundry } from '@adraffy/blocksmith';
import { COIN_TYPE_ETH, resolverAbi } from '@adraffy/ezccip';
import { serveEZCCIP } from '@adraffy/ezccip/serve';
import {
	createPublicClient,
	decodeFunctionResult,
	encodeFunctionData,
	http,
	parseAbi,
	stringToHex,
	toHex,
	type Address,
	type Hex,
	type PublicClient,
} from 'viem';
import { namehash, packetToBytes } from 'viem/ens';
import { createGateway } from '../src/gateway.js';
import { fetchProof, ANCHOR_DID } from '../src/bluesky.js';
import { verifyProof } from '../src/verify.js';
import { addr, text, COIN_ETH } from '../src/records.js';

const HANDLE = 'adraffy.bsky.social';
const NAME = 'adraffy.bsky.eth';
const NODE = namehash(NAME);

const introspectionAbi = parseAbi([
	'function supportsInterface(bytes4) view returns (bool)',
	'function supportsFeature(bytes4) view returns (bool)',
]);

let foundry: Foundry | undefined;
let ccip: Awaited<ReturnType<typeof serveEZCCIP>> | undefined;
let client: PublicClient;
let resolver: Address;
let expected: { eth?: string; avatar?: string; description?: string; github?: string };

// resolve(name, data) on the resolver, following CCIP-Read (viem handles OffchainLookup)
function resolve(name: string, data: Hex): Promise<Hex> {
	return client.readContract({
		address: resolver,
		abi: resolverAbi,
		functionName: 'resolve',
		args: [toHex(packetToBytes(name)), data],
	});
}

async function resolveText(key: string): Promise<string> {
	const args = [NODE, key] as const;
	const data = await resolve(NAME, encodeFunctionData({ abi: resolverAbi, functionName: 'text', args }));
	return decodeFunctionResult({ abi: resolverAbi, functionName: 'text', args, data });
}

beforeAll(async () => {
	const v = verifyProof(HANDLE, await fetchProof(HANDLE));
	expected = {
		eth: addr(v.profile, COIN_ETH),
		avatar: text(v.profile, v.did, 'avatar'),
		description: text(v.profile, v.did, 'description'),
		github: text(v.profile, v.did, 'com.github'),
	};

	foundry = await Foundry.launch({ infoLog: false });
	client = createPublicClient({ transport: http(`http://127.0.0.1:${foundry.port}`) });
	ccip = await serveEZCCIP(createGateway(), { log: false });
	const contract = await foundry.deploy({
		file: 'BlueskyResolver',
		// maxAge = 0: live data, so don't depend on how recently the account posted (covered by forge tests)
		args: [[ccip.endpoint], namehash('bsky.eth'), stringToHex(ANCHOR_DID), 0n],
	});
	resolver = contract.target as Address; // the only blocksmith object we touch
}, 120_000);

afterAll(async () => {
	await ccip?.shutdown();
	await foundry?.shutdown();
});

test('supports ENSIP-10 and ERC-7996 resolve-multicall', async () => {
	const read = (functionName: 'supportsInterface' | 'supportsFeature', id: Hex) =>
		client.readContract({ address: resolver, abi: introspectionAbi, functionName, args: [id] });
	expect(await read('supportsInterface', '0x9061b923')).toBe(true); // IExtendedResolver
	expect(await read('supportsInterface', '0x582de3e7')).toBe(true); // IERC7996
	expect(await read('supportsFeature', '0x96b62db8')).toBe(true); // RESOLVE_MULTICALL
});

test('resolve() via CCIP-Read', async () => {
	const addrArgs = [NODE] as const;
	const address = decodeFunctionResult({
		abi: resolverAbi,
		functionName: 'addr',
		args: addrArgs,
		data: await resolve(NAME, encodeFunctionData({ abi: resolverAbi, functionName: 'addr', args: addrArgs })),
	});
	expect(address).toBe(expected.eth as Address);

	const coinArgs = [NODE, COIN_TYPE_ETH] as const;
	const coinAddr = decodeFunctionResult({
		abi: resolverAbi,
		functionName: 'addr',
		args: coinArgs,
		data: await resolve(NAME, encodeFunctionData({ abi: resolverAbi, functionName: 'addr', args: coinArgs })),
	});
	expect(coinAddr).toBe(expected.eth!.toLowerCase() as Hex);

	expect(await resolveText('avatar')).toBe(expected.avatar ?? '');
	expect(await resolveText('description')).toBe(expected.description ?? '');
	expect(await resolveText('com.github')).toBe(expected.github ?? '');
	expect(await resolveText('not-a-key')).toBe('');
}, 60_000);

test('resolve(name, multicall([...])) in one CCIP-Read round trip', async () => {
	const addrArgs = [NODE] as const;
	const textArgs = [NODE, 'avatar'] as const;
	const calls = [
		encodeFunctionData({ abi: resolverAbi, functionName: 'addr', args: addrArgs }),
		encodeFunctionData({ abi: resolverAbi, functionName: 'text', args: textArgs }),
	];
	const answer = await resolve(NAME, encodeFunctionData({ abi: resolverAbi, functionName: 'multicall', args: [calls] }));
	const results = decodeFunctionResult({ abi: resolverAbi, functionName: 'multicall', data: answer });
	expect(decodeFunctionResult({ abi: resolverAbi, functionName: 'addr', args: addrArgs, data: results[0] })).toBe(
		expected.eth as Address
	);
	expect(decodeFunctionResult({ abi: resolverAbi, functionName: 'text', args: textArgs, data: results[1] })).toBe(
		expected.avatar ?? ''
	);
}, 60_000);

test('rejects names outside the parent', async () => {
	const data = encodeFunctionData({ abi: resolverAbi, functionName: 'addr', args: [namehash('adraffy.other.eth')] });
	await expect(resolve('adraffy.other.eth', data)).rejects.toThrow();
});
