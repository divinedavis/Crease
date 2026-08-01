#!/usr/bin/env node
/**
 * End-to-end two-leg smoke test against a running dispatch service.
 *
 * Drives a real order all the way through: pickup courier -> cleaner intake
 * and pricing -> return courier -> delivered. Asserts the order status at
 * every hop so a regression in the state machine fails loudly.
 *
 *   node scripts/seed.mjs && node scripts/e2e.mjs
 */
import { createClient } from '@supabase/supabase-js';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const env = Object.fromEntries(
  readFileSync(join(root, 'services/dispatch/.env'), 'utf8')
    .split('\n')
    .filter((l) => l.includes('=') && !l.startsWith('#'))
    .map((l) => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1)]),
);

const BASE = env.PUBLIC_URL ?? 'http://localhost:8080';
const db = createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY, {
  auth: { persistSession: false },
});

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let failures = 0;

function check(label, actual, expected) {
  const ok = actual === expected;
  if (!ok) failures++;
  console.log(`${ok ? '  PASS' : '  FAIL'}  ${label}: ${actual}${ok ? '' : ` (expected ${expected})`}`);
}

async function post(path) {
  const res = await fetch(`${BASE}${path}`, {
    method: 'POST',
    headers: { 'x-crease-key': env.INTERNAL_API_KEY, 'content-type': 'application/json' },
    body: '{}',
  });
  const json = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(`${path} -> ${res.status} ${JSON.stringify(json)}`);
  return json;
}

async function waitForOrder(orderId, wanted, timeoutMs = 30_000) {
  const deadline = Date.now() + timeoutMs;
  let last;
  while (Date.now() < deadline) {
    const { data } = await db.from('orders').select('status').eq('id', orderId).single();
    last = data?.status;
    if (wanted.includes(last)) return last;
    await sleep(400);
  }
  return last;
}

// Most recent seeded order.
const { data: order } = await db
  .from('orders')
  .select('id, short_code, status, cleaner_id')
  .order('created_at', { ascending: false })
  .limit(1)
  .single();

console.log(`\norder ${order.short_code} (${order.id})\n`);

// --- leg 1: customer -> cleaner ------------------------------------------
console.log('LEG 1  customer -> cleaner');
const pickup = await post(`/v1/orders/${order.id}/dispatch-pickup`);
check('provider', pickup.leg.provider, 'mock');
check('leg type', pickup.leg.leg, 'pickup');
console.log(`  courier: ${pickup.leg.courier_name} (${pickup.leg.courier_vehicle})`);

check('order after dispatch', await waitForOrder(order.id, ['pickup_dispatched']), 'pickup_dispatched');
check('bag collected', await waitForOrder(order.id, ['in_transit_to_cleaner']), 'in_transit_to_cleaner');
check('arrived at cleaner', await waitForOrder(order.id, ['at_cleaner']), 'at_cleaner');

// Idempotency: a duplicate dispatch must not send a second courier.
const dupe = await post(`/v1/orders/${order.id}/dispatch-pickup`);
check('duplicate dispatch reuses leg', dupe.leg.id, pickup.leg.id);

// --- cleaner intake -------------------------------------------------------
console.log('\nINTAKE  cleaner counts and prices the bag');
const { data: items } = await db
  .from('service_items')
  .select('*')
  .eq('cleaner_id', order.cleaner_id);
const shirt = items.find((i) => i.code === 'shirt');
const pants = items.find((i) => i.code === 'pants');

await db.from('order_items').insert([
  { order_id: order.id, service_item_id: shirt.id, label: shirt.label, quantity: 3, unit_price_cents: shirt.unit_price_cents },
  { order_id: order.id, service_item_id: pants.id, label: pants.label, quantity: 1, unit_price_cents: pants.unit_price_cents },
]);
const subtotal = shirt.unit_price_cents * 3 + pants.unit_price_cents;
await db.from('orders').update({ subtotal_cents: subtotal, status: 'cleaning' }).eq('id', order.id);
console.log(`  counted 4 garments, subtotal $${(subtotal / 100).toFixed(2)}`);

await db.from('orders').update({ status: 'ready' }).eq('id', order.id);

// --- leg 2: cleaner -> customer ------------------------------------------
console.log('\nLEG 2  cleaner -> customer');
const ret = await post(`/v1/orders/${order.id}/dispatch-return`);
check('leg type', ret.leg.leg, 'return');
check('direction flipped', ret.leg.pickup_address, pickup.leg.dropoff_address);

check('return dispatched', await waitForOrder(order.id, ['return_dispatched']), 'return_dispatched');
check('out for delivery', await waitForOrder(order.id, ['in_transit_to_customer']), 'in_transit_to_customer');
check('delivered', await waitForOrder(order.id, ['delivered']), 'delivered');

// --- audit trail ----------------------------------------------------------
console.log('\nAUDIT');
const { data: legs } = await db
  .from('delivery_legs')
  .select('leg, status, provider, fee_cents')
  .eq('order_id', order.id)
  .order('created_at');
legs.forEach((l) => console.log(`  ${l.leg.padEnd(7)} ${l.status.padEnd(10)} ${l.provider}  $${(l.fee_cents / 100).toFixed(2)}`));
check('two legs recorded', legs.length, 2);

const { count } = await db
  .from('delivery_events')
  .select('*', { count: 'exact', head: true })
  .not('processed_at', 'is', null);
console.log(`  ${count} webhook events processed`);

const { count: bad } = await db
  .from('delivery_events')
  .select('*', { count: 'exact', head: true })
  .eq('signature_valid', false);
check('no bad signatures', bad, 0);

console.log(failures === 0 ? '\nALL CHECKS PASSED\n' : `\n${failures} CHECK(S) FAILED\n`);
process.exit(failures === 0 ? 0 : 1);
