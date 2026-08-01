#!/usr/bin/env node
/**
 * Verify the Uber Direct adapter against the real API.
 *
 * Quotes only by default. This account has billing configured, so a created
 * delivery can dispatch an actual courier to an actual address and bill for
 * it — that is not something to do as a side effect of running a check script.
 *
 *   node scripts/uber-check.mjs              # quote only, free, safe
 *   node scripts/uber-check.mjs --create     # ALSO creates a test delivery
 *
 * --create sends Uber's robo-courier test specification, which simulates the
 * courier rather than dispatching a person. Verify in the dashboard that no
 * real delivery appeared before trusting it on a billable account.
 */
import { UberDirectProvider } from '../packages/delivery/dist/index.js';

const clientId = process.env.UBER_CLIENT_ID;
const clientSecret = process.env.UBER_CLIENT_SECRET;
const customerId = process.env.UBER_CUSTOMER_ID;

if (!clientId || !clientSecret || !customerId) {
  console.error('need UBER_CLIENT_ID, UBER_CLIENT_SECRET, UBER_CUSTOMER_ID');
  process.exit(1);
}

const CREATE = process.argv.includes('--create');
const provider = new UberDirectProvider({ clientId, clientSecret, customerId });

let failures = 0;
const check = (label, actual, expected) => {
  const ok = actual === expected;
  if (!ok) failures++;
  console.log(`  ${ok ? 'PASS' : 'FAIL'}  ${label}: ${actual}${ok ? '' : ` (expected ${expected})`}`);
};
const checkTrue = (label, cond, detail = '') => {
  if (!cond) failures++;
  console.log(`  ${cond ? 'PASS' : 'FAIL'}  ${label}${detail ? ` — ${detail}` : ''}`);
};

// Real Brooklyn addresses about a mile apart — inside any plausible courier
// radius, so an "unavailable" answer means something real rather than
// "nobody serves this route".
const pickup = {
  name: 'Test Customer',
  phone: '+15555550123',
  address: '215 Bedford Ave, Brooklyn, NY 11211',
  lat: 40.7178,
  lng: -73.9569,
  notes: 'Buzzer 3R',
  verification: 'signature',
};
const dropoff = {
  name: 'Bedford Cleaners',
  phone: '+15555550199',
  address: '404 Bedford Ave, Brooklyn, NY 11249',
  lat: 40.7141,
  lng: -73.9613,
  notes: 'Crease test',
  verification: 'signature',
};
const manifest = {
  description: 'Dry cleaning — 4 garments',
  declaredValueCents: 20000,
  itemCount: 4,
  requiresCar: true,
};

console.log('\nCONFIG');
checkTrue('provider reports configured', provider.isConfigured());

console.log('\nQUOTE  (free — no courier dispatched)');
let quote;
try {
  quote = await provider.quote({ pickup, dropoff, manifest });
} catch (err) {
  console.log(`  FAIL  quote threw: ${err.message.slice(0, 300)}`);
  console.log(`\n  This is where field-name drift shows up. The adapter was`);
  console.log(`  written against the published v1 shapes; if Uber has renamed`);
  console.log(`  something, the message above names it.\n`);
  process.exit(1);
}

checkTrue('quote returned an id', Boolean(quote.quoteId), quote.quoteId);
checkTrue('fee is a number', Number.isFinite(quote.feeCents), `${quote.feeCents} cents`);
checkTrue('fee is plausible', quote.feeCents > 0 && quote.feeCents < 10_000, `$${(quote.feeCents / 100).toFixed(2)}`);
checkTrue('quote expires', Boolean(quote.expiresAt), quote.expiresAt);
check('currency', quote.currency, 'usd');
if (quote.estimatedDropoffAt) console.log(`  ETA: ${quote.estimatedDropoffAt}`);
if (quote.unavailableReason) console.log(`  unavailable: ${quote.unavailableReason}`);

if (!CREATE) {
  console.log('\nSKIPPED  delivery creation');
  console.log('  Creating a delivery on a billable account can dispatch a real');
  console.log('  courier. Re-run with --create once you have decided to.');
  console.log(failures === 0 ? '\nQUOTE PATH VERIFIED\n' : `\n${failures} CHECK(S) FAILED\n`);
  process.exit(failures === 0 ? 0 : 1);
}

console.log('\nCREATE  (robo-courier test specification)');
const state = await provider.createDelivery({
  pickup,
  dropoff,
  manifest,
  externalId: `crease_check_${Date.now()}`,
  quoteId: quote.quoteId,
  orderReference: 'CHECK01',
});

checkTrue('delivery created', Boolean(state.providerDeliveryId), state.providerDeliveryId);
checkTrue('status mapped, not defaulted', state.status !== undefined, `${state.status} (raw: ${state.providerStatus})`);
checkTrue('tracking url present', Boolean(state.trackingUrl), state.trackingUrl);

const fetched = await provider.getDelivery(state.providerDeliveryId);
check('re-read returns the same delivery', fetched.providerDeliveryId, state.providerDeliveryId);

console.log('\nCANCEL');
const cancelled = await provider.cancelDelivery(state.providerDeliveryId);
check('cancelled', cancelled.status, 'cancelled');

console.log(failures === 0 ? '\nALL CHECKS PASSED\n' : `\n${failures} CHECK(S) FAILED\n`);
process.exit(failures === 0 ? 0 : 1);
