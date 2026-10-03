import { strict as assert } from 'node:assert';
import { test } from 'node:test';
import { looksLikeSpam, looksLikeStreetAddress } from './spam.ts';

test('the two bot submissions are spam', () => {
  assert.ok(looksLikeSpam('', '📁 +2.84567053 BITCOIN. GET ->> graph.org/Mining-08-27-2?hs=3c60 📁'));
  assert.ok(looksLikeSpam('', '💶 1 MESSAGE for you #N6914 OPEN -> graph.org/Cloud-Mining-08-27?hs=3c 💶'));
});

test('a filled bot trap is spam whatever the name', () => {
  assert.ok(looksLikeSpam('Acme LLC', 'Maria Lopez'));
});

test('real names are not spam', () => {
  for (const name of ['Maria Lopez', "D'Angelo O'Neil", 'Dr. J. Smith', 'Jean-Luc', 'José']) {
    assert.equal(looksLikeSpam('', name), false, name);
  }
});

test('street addresses pass and random tokens do not', () => {
  assert.ok(looksLikeStreetAddress('400 Myrtle Ave'));
  assert.ok(looksLikeStreetAddress('909 Fulton St, Brooklyn, NY 11238'));
  assert.equal(looksLikeStreetAddress('8p1wlm'), false);
  assert.equal(looksLikeStreetAddress('xn1e15'), false);
  assert.equal(looksLikeStreetAddress('  '), false);
});
