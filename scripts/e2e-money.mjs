#!/usr/bin/env node
/**
 * Money path, end to end against a running dispatch service.
 *
 * Covers the two outcomes that actually differ:
 *
 *   1. counted UNDER the hold  -> captured silently, balance released
 *   2. counted OVER  the hold  -> nothing taken, order held for approval,
 *                                 then the hold captured and the remainder
 *                                 charged separately once the customer agrees
 *
 * Case 2 is the one worth guarding. Card networks refuse a capture above the
 * authorization, so a bug here does not throw — it quietly undercharges every
 * order where a customer underestimated their laundry.
 *
 *   node scripts/e2e-money.mjs
 */
import { adminClient } from './lib/client.mjs';

const { env, db } = await adminClient();
const BASE = process.env.CREASE_BASE ?? env.PUBLIC_URL ?? 'http://localhost:8080';

let failures = 0;
const check = (label, actual, expected) => {
  const ok = actual === expected;
  if (!ok) failures++;
  console.log(`  ${ok ? 'PASS' : 'FAIL'}  ${label}: ${actual}${ok ? '' : ` (expected ${expected})`}`);
};
const money = (c) => `$${((c ?? 0) / 100).toFixed(2)}`;

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

const { data: cleaner } = await db.from('cleaners').select('id').eq('slug', 'bedford-cleaners').single();
const { data: address } = await db.from('addresses').select('id, user_id').limit(1).single();
const { data: services } = await db.from('service_items').select('*').eq('cleaner_id', cleaner.id);
const shirt = services.find((s) => s.code === 'shirt');
const coat = services.find((s) => s.code === 'coat');

async function newOrder(estimateCents) {
  const { data } = await db
    .from('orders')
    .insert({
      customer_id: address.user_id,
      cleaner_id: cleaner.id,
      address_id: address.id,
      status: 'at_cleaner',
      estimate_subtotal_cents: estimateCents,
      approval_threshold_cents: 1500,
    })
    .select()
    .single();
  return data;
}

async function count(orderId, item, qty) {
  await db.from('order_items').insert({
    order_id: orderId,
    service_item_id: item.id,
    label: item.label,
    quantity: qty,
    unit_price_cents: item.unit_price_cents,
  });
  const subtotal = item.unit_price_cents * qty;
  await db.from('orders').update({ subtotal_cents: subtotal }).eq('id', orderId);
  return subtotal;
}

// ---------------------------------------------------------------------------
console.log('\nCASE 1  counted under the hold');
{
  const order = await newOrder(2400);
  const authRes = await post(`/v1/orders/${order.id}/authorize`);
  const held = authRes.payment.authorized_cents;
  console.log(`  estimate ${money(2400)}, held ${money(held)}`);
  check('hold covers the estimate', held >= 2400, true);
  check('hold stays within estimate + threshold', held <= 2400 + 1500, true);

  const subtotal = await count(order.id, shirt, 4); // 4 x $3.49 = $13.96
  const res = await post(`/v1/orders/${order.id}/settle`);
  console.log(`  counted ${money(subtotal)}, captured ${money(res.captured)}`);

  check('no approval needed', res.needsApproval, false);
  check('captured the counted total', res.captured, subtotal);

  const { data: pay } = await db.from('payments').select('*').eq('order_id', order.id).single();
  check('payment marked captured', pay.status, 'captured');
  check('captured is not the hold', pay.captured_cents === held, false);
}

// ---------------------------------------------------------------------------
console.log('\nCASE 2  counted over the hold');
{
  const order = await newOrder(2400);
  const authRes = await post(`/v1/orders/${order.id}/authorize`);
  const held = authRes.payment.authorized_cents;

  // Three overcoats against a four-shirt estimate — the realistic disaster.
  const subtotal = await count(order.id, coat, 3); // 3 x $24.99 = $74.97
  console.log(`  held ${money(held)}, counted ${money(subtotal)}`);

  const res = await post(`/v1/orders/${order.id}/settle`);
  check('flagged for approval', res.needsApproval, true);
  check('nothing captured yet', res.captured, 0);

  const { data: order2 } = await db.from('orders').select('status, total_cents').eq('id', order.id).single();
  check('order held for the customer', order2.status, 'awaiting_approval');

  const { data: pay } = await db
    .from('payments')
    .select('*')
    .eq('order_id', order.id)
    .eq('kind', 'primary')
    .single();
  check('hold not captured', pay.status, 'authorized');
  check('no money taken', pay.captured_cents, 0);

  // Customer says yes.
  const approved = await post(`/v1/orders/${order.id}/approve`);
  console.log(`  approved: total ${money(approved.total)}, remainder ${money(approved.remainder)}`);

  const { data: after } = await db.from('payments').select('*').eq('order_id', order.id).order('kind');
  const primary = after.find((p) => p.kind === 'primary');
  const diff = after.find((p) => p.kind === 'difference');

  check('hold now captured', primary.status, 'captured');
  check('hold captured in full', primary.captured_cents, held);
  check('a difference charge exists', Boolean(diff), true);
  check('difference covers the gap', primary.captured_cents + diff.captured_cents, subtotal);
  check('total charged equals the count', primary.captured_cents + diff.captured_cents, order2.total_cents);

  const { data: order3 } = await db.from('orders').select('status, approved_at').eq('id', order.id).single();
  check('order resumes cleaning', order3.status, 'cleaning');
  check('approval recorded', Boolean(order3.approved_at), true);
}

// ---------------------------------------------------------------------------
console.log('\nCASE 3  cancelled before capture releases the hold');
{
  const order = await newOrder(2400);
  await post(`/v1/orders/${order.id}/authorize`);
  await post(`/v1/orders/${order.id}/cancel`);

  const { data: pay } = await db.from('payments').select('*').eq('order_id', order.id).single();
  check('hold released', pay.status, 'cancelled');
  check('nothing taken', pay.captured_cents, 0);
}

console.log(failures === 0 ? '\nALL CHECKS PASSED\n' : `\n${failures} CHECK(S) FAILED\n`);
process.exit(failures === 0 ? 0 : 1);
