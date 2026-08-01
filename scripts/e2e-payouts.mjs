#!/usr/bin/env node
/**
 * Payouts to partner shops, end to end against a running dispatch service.
 *
 * The case that matters most is the unglamorous one: a shop that has not
 * finished Connect onboarding. That is the normal state for days after signing
 * a partner, and it must not fail the customer's order, must not lose the
 * money owed, and must settle automatically once they finish.
 *
 *   node scripts/e2e-payouts.mjs
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

async function post(path, body = {}) {
  const res = await fetch(`${BASE}${path}`, {
    method: 'POST',
    headers: { 'x-crease-key': env.INTERNAL_API_KEY, 'content-type': 'application/json' },
    body: JSON.stringify(body),
  });
  const json = await res.json().catch(() => ({}));
  return { status: res.status, json };
}

const { data: cleaner } = await db
  .from('cleaners')
  .select('*')
  .eq('slug', 'bedford-cleaners')
  .single();
const { data: address } = await db.from('addresses').select('id, user_id').limit(1).single();
const { data: services } = await db.from('service_items').select('*').eq('cleaner_id', cleaner.id);
const shirt = services.find((s) => s.code === 'shirt');

async function orderReadyToSettle(qty) {
  const { data: order } = await db
    .from('orders')
    .insert({
      customer_id: address.user_id,
      cleaner_id: cleaner.id,
      address_id: address.id,
      status: 'at_cleaner',
      estimate_subtotal_cents: 5000,
      approval_threshold_cents: 1500,
    })
    .select()
    .single();

  await post(`/v1/orders/${order.id}/authorize`);
  await db.from('order_items').insert({
    order_id: order.id,
    service_item_id: shirt.id,
    label: shirt.label,
    quantity: qty,
    unit_price_cents: shirt.unit_price_cents,
  });
  const subtotal = shirt.unit_price_cents * qty;
  await db.from('orders').update({ subtotal_cents: subtotal }).eq('id', order.id);
  return { order, subtotal };
}

// --- reset onboarding state so the run is repeatable ------------------------
await db
  .from('cleaners')
  .update({ stripe_account_id: null, payouts_enabled: false, connect_requirements: [] })
  .eq('id', cleaner.id);

console.log('\nCASE 1  shop has not onboarded — money is owed, not lost');
const a = await orderReadyToSettle(4);
const settleA = await post(`/v1/orders/${a.order.id}/settle`);
check('customer still charged', settleA.json.captured, a.subtotal);

const { data: payoutA } = await db.from('payouts').select('*').eq('order_id', a.order.id).single();
check('payout recorded as pending', payoutA.status, 'pending');
check('amount owed is calculated', payoutA.amount_cents > 0, true);
console.log(`  subtotal ${money(a.subtotal)} · commission ${payoutA.commission_bps / 100}% · owed ${money(payoutA.amount_cents)}`);
check(
  'commission is on the cleaning subtotal only',
  payoutA.amount_cents,
  a.subtotal - Math.round((a.subtotal * cleaner.commission_bps) / 10_000),
);
check('nothing transferred yet', payoutA.provider_transfer_ref, null);

// --- onboarding -------------------------------------------------------------
console.log('\nCASE 2  onboarding produces an account and a link');
const onboard = await post(`/v1/cleaners/${cleaner.id}/connect-onboarding`);
check('onboarding started', onboard.status, 200);
check('account created', Boolean(onboard.json.accountRef), true);
check('link returned', Boolean(onboard.json.url), true);

const { data: afterOnboard } = await db
  .from('cleaners')
  .select('stripe_account_id, payouts_enabled')
  .eq('id', cleaner.id)
  .single();
check('account saved on the shop', afterOnboard.stripe_account_id, onboard.json.accountRef);
check('but payouts still disabled until they finish', afterOnboard.payouts_enabled, false);

// Simulate the shop completing Stripe's hosted onboarding.
//
// Deliberately NOT a direct database update: setting payouts_enabled by hand
// produces a shop the database believes is payable while the provider still
// refuses it, which is exactly the disagreement this test exists to catch.
// The route flips the provider and re-reads its view back into the database.
const completed = await post(`/v1/cleaners/${cleaner.id}/connect-complete-mock`);
check('onboarding completed', completed.status, 200);
check('provider now allows payouts', completed.json.account?.payoutsEnabled, true);

const { data: nowEnabled } = await db
  .from('cleaners')
  .select('payouts_enabled')
  .eq('id', cleaner.id)
  .single();
check('and the database agrees', nowEnabled.payouts_enabled, true);

console.log('\nCASE 3  the sweep settles what was owed');
const sweep = await post('/v1/payouts/sweep');
check('sweep ran', sweep.status, 200);
console.log(`  attempted ${sweep.json.attempted}, paid ${sweep.json.paid}, still owed ${sweep.json.stillOwed}`);

const { data: payoutAfter } = await db.from('payouts').select('*').eq('order_id', a.order.id).single();
check('the held payout is now paid', payoutAfter.status, 'paid');
check('transfer recorded', Boolean(payoutAfter.provider_transfer_ref), true);
check('amount unchanged from what was owed', payoutAfter.amount_cents, payoutA.amount_cents);

console.log('\nCASE 4  an onboarded shop is paid on settle');
const b = await orderReadyToSettle(6);
await post(`/v1/orders/${b.order.id}/settle`);
const { data: payoutB } = await db.from('payouts').select('*').eq('order_id', b.order.id).single();
check('paid immediately', payoutB.status, 'paid');
check('shop keeps 80% of the cleaning', payoutB.amount_cents, Math.round(b.subtotal * 0.8));
console.log(`  customer paid ${money(b.subtotal)} → shop received ${money(payoutB.amount_cents)}`);

console.log('\nCASE 5  a shop is never paid twice for one bag');
const before = payoutB.provider_transfer_ref;
await post(`/v1/orders/${b.order.id}/settle`);
const { data: payoutB2 } = await db.from('payouts').select('*').eq('order_id', b.order.id);
check('still exactly one payout row', payoutB2.length, 1);
check('same transfer, not a second one', payoutB2[0].provider_transfer_ref, before);

console.log('\nCASE 6  no payout without captured funds');
const { data: unpaid } = await db
  .from('orders')
  .insert({
    customer_id: address.user_id,
    cleaner_id: cleaner.id,
    address_id: address.id,
    status: 'at_cleaner',
    estimate_subtotal_cents: 2000,
    subtotal_cents: 2000,
  })
  .select()
  .single();
const res = await post(`/v1/payouts/sweep`);
const { data: strayPayout } = await db
  .from('payouts')
  .select('id')
  .eq('order_id', unpaid.id)
  .maybeSingle();
check('no payout created for an uncaptured order', strayPayout, null);
await db.from('orders').delete().eq('id', unpaid.id);

console.log(failures === 0 ? '\nALL CHECKS PASSED\n' : `\n${failures} CHECK(S) FAILED\n`);
process.exit(failures === 0 ? 0 : 1);
