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
import { adminClient } from './lib/client.mjs';

const { env, db } = await adminClient();

// CREASE_BASE lets this run against a deployed instance over loopback,
// where PUBLIC_URL is the public hostname and may not resolve from the box.
const BASE = process.env.CREASE_BASE ?? env.PUBLIC_URL ?? 'http://localhost:8080';

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

// Anchor for run-scoped assertions below.
const runStartedAt = new Date().toISOString();

// An explicit id when you have one, most recent otherwise. Naming the order
// matters now that real bookings land in this table: "most recent" used to mean
// the seeded fixture and today can just as easily mean a customer's live order,
// which this script would rewrite.
const COLUMNS = 'id, short_code, status, cleaner_id, customer_id, delivery_fee_cents, service_tier';
const wanted = process.argv[2];
const { data: order } = wanted
  ? await db.from('orders').select(COLUMNS).eq('id', wanted).single()
  : await db.from('orders').select(COLUMNS).order('created_at', { ascending: false }).limit(1).single();

console.log(`\norder ${order.short_code} (${order.id})\n`);

// --- checkout ------------------------------------------------------------
// Crease charges the delivery fee up front — it is known the moment a tier is
// chosen — so by dispatch time the payment is captured, not held. This stands
// in for a completed PaymentSheet on the device.
console.log('CHECKOUT  pay the delivery fee');
const intent = await post(`/v1/orders/${order.id}/payment-intent`);
check('intent created for the delivery fee', intent.amountCents, order.delivery_fee_cents);
check('client secret returned', Boolean(intent.clientSecret), true);

await db.from('payments').update({ status: 'captured', captured_cents: order.delivery_fee_cents })
  .eq('order_id', order.id).eq('kind', 'primary');

// --- leg 1: customer -> cleaner ------------------------------------------
console.log('\nLEG 1  customer -> cleaner');
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

// The shop marks it ready, which is a fact, not a promise.
await db.from('orders')
  .update({ status: 'ready', ready_at: new Date().toISOString() })
  .eq('id', order.id);

// Only the tiers that bought a second leg get one. On a pickup_only order the
// customer collects at the counter, and asking for a return here would assert a
// courier they never paid for — which the dispatcher now refuses outright.
if (order.service_tier === 'pickup_only') {
  console.log('\nLEG 2  skipped — pickup_only ends at the counter');
  const refused = await fetch(`${BASE}/v1/orders/${order.id}/dispatch-return`, {
    method: 'POST',
    headers: { 'x-crease-key': env.INTERNAL_API_KEY, 'content-type': 'application/json' },
    body: '{}',
  });
  check('return refused for a one-leg order', refused.status >= 400, true);
} else {
  // A return must NOT be dispatchable until the customer has chosen a window —
  // otherwise a courier turns up at whatever moment the shop pressed a button.
  const premature = await fetch(`${BASE}/v1/orders/${order.id}/dispatch-return`, {
    method: 'POST',
    headers: { 'x-crease-key': env.INTERNAL_API_KEY, 'content-type': 'application/json' },
    body: '{}',
  });
  check('return refused before the customer picks a time', premature.status, 409);

  // Customer picks a delivery window.
  const windowStart = new Date(Date.now() + 3600_000);
  await db.from('orders').update({
    return_window_start: windowStart.toISOString(),
    return_window_end: new Date(windowStart.getTime() + 3 * 3600_000).toISOString(),
  }).eq('id', order.id);

  // --- leg 2: cleaner -> customer ----------------------------------------
  console.log('\nLEG 2  cleaner -> customer');
  const ret = await post(`/v1/orders/${order.id}/dispatch-return`);
  check('leg type', ret.leg.leg, 'return');
  check('direction flipped', ret.leg.pickup_address, pickup.leg.dropoff_address);

  check('return dispatched', await waitForOrder(order.id, ['return_dispatched']), 'return_dispatched');
  check('out for delivery', await waitForOrder(order.id, ['in_transit_to_customer']), 'in_transit_to_customer');
  check('delivered', await waitForOrder(order.id, ['delivered']), 'delivered');
}

// --- guard: an unfunded order must not get a courier ----------------------
console.log('\nGUARD  unfunded order');
const { data: unfunded } = await db
  .from('orders')
  .insert({
    customer_id: order.customer_id ?? (await db.from('addresses').select('user_id').limit(1).single()).data.user_id,
    cleaner_id: order.cleaner_id,
    address_id: (await db.from('addresses').select('id').limit(1).single()).data.id,
    status: 'scheduled',
    estimate_subtotal_cents: 2400,
  })
  .select('id')
  .single();

const res = await fetch(`${BASE}/v1/orders/${unfunded.id}/dispatch-pickup`, {
  method: 'POST',
  headers: { 'x-crease-key': env.INTERNAL_API_KEY, 'content-type': 'application/json' },
  body: '{}',
});
check('courier refused without held funds', res.status, 402);
const { count: strayLegs } = await db
  .from('delivery_legs')
  .select('*', { count: 'exact', head: true })
  .eq('order_id', unfunded.id);
check('no leg created', strayLegs, 0);
await db.from('orders').delete().eq('id', unfunded.id);

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

// Scoped to this run, not all time. A rejected forgery is a *success* for
// the system and the row is kept on purpose, so an all-time count means any
// legitimate security probe fails this check forever afterwards.
const { count: bad } = await db
  .from('delivery_events')
  .select('*', { count: 'exact', head: true })
  .eq('signature_valid', false)
  .gte('received_at', runStartedAt);
check('no bad signatures during this run', bad, 0);

console.log(failures === 0 ? '\nALL CHECKS PASSED\n' : `\n${failures} CHECK(S) FAILED\n`);
process.exit(failures === 0 ? 0 : 1);
