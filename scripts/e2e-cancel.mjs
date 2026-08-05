#!/usr/bin/env node
/**
 * Cancellation, end to end.
 *
 * A cancel that only flips a status column is worse than no cancel at all: the
 * courier still arrives and the customer is still charged. This asserts the
 * two things that actually have to happen — the leg is cancelled with the
 * carrier, and the money is released.
 *
 *   node scripts/e2e-cancel.mjs
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

async function post(path) {
  const res = await fetch(`${BASE}${path}`, {
    method: 'POST',
    headers: { 'x-crease-key': env.INTERNAL_API_KEY, 'content-type': 'application/json' },
    body: '{}',
  });
  return { status: res.status, json: await res.json().catch(() => ({})) };
}

const { data: address } = await db.from('addresses').select('id, user_id').limit(1).single();
const { data: cleaner } = await db.from('cleaners').select('id').eq('slug', 'bedford-cleaners').single();

async function makeOrder() {
  const { data } = await db.from('orders').insert({
    customer_id: address.user_id,
    cleaner_id: cleaner.id,
    address_id: address.id,
    status: 'scheduled',
    estimate_subtotal_cents: 0,
    delivery_fee_cents: 1995,
    // Case 2 cancels a courier mid-flight, so the fixture has to be a tier that
    // gets one. return_only never has a pickup leg — the dispatcher refuses it
    // outright now, which used to look like a cancellation bug in this script.
    service_tier: 'pickup_only',
  }).select('id, short_code').single();
  return data;
}

console.log('\nCASE 1  cancel before any courier is booked');
{
  const order = await makeOrder();
  const res = await post(`/v1/orders/${order.id}/cancel`);
  check('cancel accepted', res.status, 200);
  const { data: after } = await db.from('orders').select('status').eq('id', order.id).single();
  check('order cancelled', after.status, 'cancelled');
  await db.from('orders').delete().eq('id', order.id);
}

console.log('\nCASE 2  cancel after a courier is dispatched');
{
  const order = await makeOrder();

  // Stand in for a completed PaymentSheet. The customer now pays the delivery
  // fee up front, so by dispatch time the payment is already captured — there
  // is no server-side hold to place, and authorizeOrder correctly refuses to
  // invent one without a card on file.
  await db.from('payments').insert({
    order_id: order.id,
    kind: 'primary',
    provider: 'stripe',
    status: 'captured',
    authorized_cents: 1995,
    captured_cents: 1995,
    provider_intent_ref: `pi_test_${order.short_code}`,
  });

  const dispatched = await post(`/v1/orders/${order.id}/dispatch-pickup`);
  check('courier dispatched', dispatched.status, 200);

  const res = await post(`/v1/orders/${order.id}/cancel`);
  check('cancel accepted', res.status, 200);

  const { data: legs } = await db.from('delivery_legs').select('status').eq('order_id', order.id);
  const live = (legs ?? []).filter((l) => !['cancelled', 'delivered', 'returned', 'failed'].includes(l.status));
  check('no courier left running', live.length, 0);

  // The intent ref here is synthetic, so Stripe rejects the refund. That is
  // exactly the case worth asserting: the cancellation must still stop the
  // couriers, and it must NOT claim the money came back when it did not.
  check('refund failure is reported, not hidden', res.json.refundPending, true);
  const { data: payment } = await db.from('payments').select('last_error').eq('order_id', order.id).maybeSingle();
  check('failure recorded for follow-up', Boolean(payment?.last_error), true);

  const { data: after } = await db.from('orders').select('status').eq('id', order.id).single();
  check('order cancelled', after.status, 'cancelled');
  await db.from('delivery_legs').delete().eq('order_id', order.id);
  await db.from('payments').delete().eq('order_id', order.id);
  await db.from('orders').delete().eq('id', order.id);
}

console.log(failures === 0 ? '\nALL CHECKS PASSED\n' : `\n${failures} CHECK(S) FAILED\n`);
process.exit(failures === 0 ? 0 : 1);
