import { expect, test } from 'bun:test';
import { normalizeHandle } from '../src/bluesky.js';

test('normalizeHandle: accepts username forms', () => {
	for (const input of ['adraffy', '@adraffy', 'Adraffy', 'adraffy.bsky.social', '@ADRAFFY.bsky.social', ' adraffy ']) {
		expect(normalizeHandle(input)).toBe('adraffy.bsky.social');
	}
	expect(normalizeHandle('a-b')).toBe('a-b.bsky.social');
});

test('normalizeHandle: rejects invalid labels', () => {
	for (const input of ['', '@', 'bad_name', '-ab', 'ab-', 'a.b', 'raffy.dev', 'x'.repeat(64), 'adraffy.bsky.social.']) {
		expect(() => normalizeHandle(input)).toThrow();
	}
});
