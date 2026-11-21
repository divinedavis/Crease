import { strict as assert } from 'node:assert';
import { test } from 'node:test';
import { webhookProbe } from './webhookProbe.js';

test('a GET to a known courier webhook says the address is ready', () => {
  const r = webhookProbe({ name: 'shipday' });
  assert.equal(r.code, 200);
  assert.equal(r.body.ok, true);
  assert.equal(r.body.provider, 'shipday');
});

test('a GET to an unknown courier is still a 404, and nothing about config leaks', () => {
  assert.equal(webhookProbe(undefined).code, 404);
  const body = JSON.stringify(webhookProbe({ name: 'shipday' }).body);
  assert.doesNotMatch(body, /token|secret|key|configured/i);
});
