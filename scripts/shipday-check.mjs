#!/usr/bin/env node
/**
 * Verify the Shipday adapter against the real API, without booking anything.
 *
 * Shipday has no sandbox: an assigned order is a real courier and a real bill.
 * So this only lists the courier services on the account and prices a Brooklyn
 * leg. The first real booking should be a supervised test order, cancelled
 * from the dashboard if it goes wrong.
 *
 *   SHIPDAY_API_KEY=... node scripts/shipday-check.mjs
 */
import { ShipdayProvider } from '../packages/delivery/dist/index.js';

const apiKey = process.env.SHIPDAY_API_KEY;
if (!apiKey) {
  console.error('need SHIPDAY_API_KEY');
  process.exit(1);
}
const apiBase = process.env.SHIPDAY_API_BASE ?? 'https://api.shipday.com';
const provider = new ShipdayProvider({ apiKey, apiBase });
console.log(`\nShipday at ${apiBase} (quotes only, never books)`);

let failures = 0;
const ok = (label, cond, detail = '') => {
  if (!cond) failures++;
  console.log(`  ${cond ? 'PASS' : 'FAIL'}  ${label}${detail ? ` — ${detail}` : ''}`);
};

console.log('\nSERVICES');
try {
  const res = await fetch(`${apiBase}/on-demand/services`, {
    headers: { authorization: `Basic ${apiKey}`, 'content-type': 'application/json' },
    signal: AbortSignal.timeout(20_000),
  });
  const text = await res.text();
  let list = [];
  try { list = JSON.parse(text); } catch { /* shown below */ }
  ok('the key is accepted', res.ok, `HTTP ${res.status}${res.ok ? '' : ` ${text.slice(0, 200)}`}`);
  if (Array.isArray(list)) {
    for (const s of list) console.log(`        ${s.name}: ${s.status ? 'on' : 'off'}${s.prod === false ? ' (not production)' : ''}`);
    ok('at least one courier service is on', list.some((s) => s.status), `${list.length} listed`);
  }
} catch (err) {
  ok('services call', false, err.message);
}

// A real Brooklyn trip about a mile long, with a 20 lb laundry bag on it.
const pickup = { name: 'Test Customer', phone: '+17185550123', address: '215 Bedford Ave, Brooklyn, NY 11211' };
const dropoff = { name: 'Bedford Cleaners', phone: '+17185550199', address: '404 Bedford Ave, Brooklyn, NY 11249' };
const manifest = { description: 'Laundry bag (wash & fold)', declaredValueCents: 20000, itemCount: 1, weightLbs: 20, requiresCar: true };

console.log('\nQUOTE');
try {
  const quote = await provider.quote({ pickup, dropoff, manifest });
  ok('a courier offered to take it', !quote.unavailableReason, quote.unavailableReason ?? quote.quoteId);
  ok('fee is plausible', quote.feeCents > 0 && quote.feeCents < 10_000, `$${(quote.feeCents / 100).toFixed(2)}`);
  if (quote.estimatedPickupAt) console.log(`        pickup by ${quote.estimatedPickupAt}, dropoff by ${quote.estimatedDropoffAt}`);
} catch (err) {
  ok('quote', false, err.message.slice(0, 400));
}

console.log(failures === 0 ? '\nQUOTE PATH VERIFIED (nothing was booked)\n' : `\n${failures} CHECK(S) FAILED\n`);
process.exit(failures === 0 ? 0 : 1);
