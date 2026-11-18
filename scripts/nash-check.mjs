#!/usr/bin/env node
/**
 * Verify the Nash adapter against the real API.
 *
 * Defaults to the SANDBOX (fake couriers, free). Quotes only unless --create,
 * which books a delivery and then cancels it. With production keys and
 * NASH_API_BASE=https://api.usenash.com, --create sends a real courier.
 *
 *   NASH_API_KEY=... NASH_ORG_ID=... node scripts/nash-check.mjs
 *   NASH_API_KEY=... NASH_ORG_ID=... node scripts/nash-check.mjs --create
 */
import { NashProvider } from '../packages/delivery/dist/index.js';

const apiKey = process.env.NASH_API_KEY;
if (!apiKey) {
  console.error('need NASH_API_KEY (and NASH_ORG_ID if the key sees more than one org)');
  process.exit(1);
}
const apiBase = process.env.NASH_API_BASE ?? 'https://api.sandbox.usenash.com';
const CREATE = process.argv.includes('--create');
const provider = new NashProvider({ apiKey, orgId: process.env.NASH_ORG_ID, apiBase });
console.log(`\nNash at ${apiBase}${apiBase.includes('sandbox') ? ' (sandbox)' : '  *** PRODUCTION ***'}`);

let failures = 0;
const ok = (label, cond, detail = '') => {
  if (!cond) failures++;
  console.log(`  ${cond ? 'PASS' : 'FAIL'}  ${label}${detail ? ` — ${detail}` : ''}`);
};

// A real Brooklyn trip about a mile long, with a 20 lb laundry bag on it.
const pickup = {
  name: 'Test Customer',
  phone: '+17185550123',
  address: '215 Bedford Ave, Brooklyn, NY 11211',
  lat: 40.7178,
  lng: -73.9569,
  notes: 'Buzzer 3R',
  verification: 'signature',
};
const dropoff = {
  name: 'Bedford Cleaners',
  phone: '+17185550199',
  address: '404 Bedford Ave, Brooklyn, NY 11249',
  lat: 40.7141,
  lng: -73.9613,
  verification: 'signature',
};
const manifest = {
  description: 'Laundry bag (wash & fold) — Crease check',
  declaredValueCents: 20000,
  itemCount: 1,
  weightLbs: 20,
  requiresCar: true,
};

console.log('\nQUOTE');
let quote;
try {
  quote = await provider.quote({ pickup, dropoff, manifest });
} catch (err) {
  console.log(`  FAIL  quote threw: ${err.message.slice(0, 400)}\n`);
  process.exit(1);
}
ok('a courier offered to take it', !quote.unavailableReason, quote.unavailableReason ?? quote.quoteId);
ok('fee is plausible', quote.feeCents > 0 && quote.feeCents < 10_000, `$${(quote.feeCents / 100).toFixed(2)}`);
ok('quote expires in the future', Date.parse(quote.expiresAt) > Date.now(), quote.expiresAt);

if (!CREATE) {
  console.log('\nSKIPPED  booking (re-run with --create)');
  console.log(failures === 0 ? '\nQUOTE PATH VERIFIED\n' : `\n${failures} CHECK(S) FAILED\n`);
  process.exit(failures === 0 ? 0 : 1);
}

console.log('\nBOOK');
const externalId = `crease-check-${Date.now()}`;
const state = await provider.createDelivery({ pickup, dropoff, manifest, externalId, orderReference: 'CHECK01' });
ok('job created', Boolean(state.providerDeliveryId), state.providerDeliveryId);
ok('status mapped', Boolean(state.status), `${state.status} (raw: ${state.providerStatus})`);
ok('tracking link', Boolean(state.trackingUrl), state.trackingUrl);

const again = await provider.createDelivery({ pickup, dropoff, manifest, externalId });
ok('replaying the same leg books nothing new', again.providerDeliveryId === state.providerDeliveryId, again.providerDeliveryId);

const read = await provider.getDelivery(state.providerDeliveryId);
ok('re-read returns the same job', read.providerDeliveryId === state.providerDeliveryId);

console.log('\nCANCEL');
const cancelled = await provider.cancelDelivery(state.providerDeliveryId);
ok('cancelled', cancelled.status === 'cancelled', `${cancelled.status} (raw: ${cancelled.providerStatus})`);

console.log(failures === 0 ? '\nALL CHECKS PASSED\n' : `\n${failures} CHECK(S) FAILED\n`);
process.exit(failures === 0 ? 0 : 1);
