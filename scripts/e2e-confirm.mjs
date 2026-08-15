#!/usr/bin/env node
/**
 * The booking path as the phone actually walks it.
 *
 * e2e.mjs drives the internal /v1/ routes with the shared secret and fakes the
 * payment by writing 'captured' onto the row. That covers the state machine but
 * skips the part that was broken for three days: the customer-token surface,
 * a real Stripe intent, and the confirm-payment call that is now the only thing
 * that promotes an order and dispatches leg 1. So this script signs in as the
 * test customer, creates a draft the way BookPickupView does, pays the intent
 * with a Stripe test card the way PaymentSheet does, and then asserts the
 * courier moves — with no shared secret anywhere in the flow.
 *
 *   CREASE_TEST_PASSWORD=... node scripts/e2e-confirm.mjs [round_trip|pickup_only|return_only]
 */
import { adminClient, readEnv } from './lib/client.mjs';

const TIER = process.argv[2] ?? 'pickup_only';
const FEE_CENTS = TIER === 'round_trip' ? 2995 : 1995;

const TEST_PASSWORD = process.env.CREASE_TEST_PASSWORD;
if (!TEST_PASSWORD) {
  console.error('set CREASE_TEST_PASSWORD before running this');
  process.exit(1);
}

const { env, db } = await adminClient();

// This script does not simulate a payment — it mints a PaymentIntent and
// confirms it against Stripe with the account's own secret key. On a live key
// that is a real charge on a real card, made by a test run, and pm_card_visa
// below is not even accepted there. Test keys only.
if (!(env.STRIPE_SECRET_KEY ?? '').startsWith('sk_test_')) {
  console.error(
    'refusing to run: STRIPE_SECRET_KEY is not a test key. This mints and confirms ' +
      'real PaymentIntents, so it only runs against sk_test_… .',
  );
  process.exit(1);
}

const anon = readEnv('apps/ios/Secrets.xcconfig');
const BASE = process.env.CREASE_BASE ?? env.PUBLIC_URL ?? 'http://localhost:8080';

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let failures = 0;

function check(label, actual, expected) {
  const ok = actual === expected;
  if (!ok) failures++;
  console.log(`${ok ? '  PASS' : '  FAIL'}  ${label}: ${actual}${ok ? '' : ` (expected ${expected})`}`);
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

/** The customer surface. No internal key — this is what an IPA can reach. */
async function asCustomer(path, token, body) {
  const res = await fetch(`${BASE}${path}`, {
    method: 'POST',
    headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
    body: JSON.stringify(body ?? {}),
  });
  return { status: res.status, json: await res.json().catch(() => ({})) };
}

// --- sign in as the customer ---------------------------------------------
console.log(`\nSIGN IN  testcustomer@crease.local  (tier: ${TIER})`);
const auth = await fetch(`${env.SUPABASE_URL}/auth/v1/token?grant_type=password`, {
  method: 'POST',
  headers: { apikey: anon.SUPABASE_ANON_KEY, 'content-type': 'application/json' },
  body: JSON.stringify({ email: 'testcustomer@crease.local', password: TEST_PASSWORD }),
});
if (!auth.ok) {
  console.error(`sign-in failed: ${auth.status} ${await auth.text()}`);
  process.exit(1);
}
const { access_token: token, user } = await auth.json();
console.log(`  user ${user.id}`);

// --- create the draft, exactly as the booking screen does ------------------
const { data: address } = await db
  .from('addresses').select('id').eq('user_id', user.id).limit(1).single();
const { data: cleaner } = await db
  .from('cleaners').select('id, name').eq('slug', 'bedford-cleaners').single();

const now = new Date();
const { data: order, error: orderErr } = await db
  .from('orders')
  .insert({
    customer_id: user.id,
    cleaner_id: cleaner.id,
    address_id: address.id,
    status: 'draft',
    estimate_subtotal_cents: 0,
    delivery_fee_cents: FEE_CENTS,
    service_tier: TIER,
    pickup_window_start: now.toISOString(),
    pickup_window_end: new Date(now.getTime() + 2 * 3600_000).toISOString(),
  })
  .select('id, short_code')
  .single();
if (orderErr) {
  console.error(`could not create the draft: ${orderErr.message}`);
  process.exit(1);
}
console.log(`\nDRAFT  ${order.short_code} (${order.id}) at ${cleaner.name}`);

// --- the guards that used to be the whole problem --------------------------
// An unpaid draft must not buy a courier, and the two ways of being unpaid are
// worth telling apart: nothing was ever started (409, nothing to retry) versus
// an intent the customer walked away from (402, tapping Book again fixes it).
console.log('\nGUARD  confirm before any intent exists');
const early = await asCustomer(`/v1/me/orders/${order.id}/confirm-payment`, token);
check('refused, nothing started', early.status, 409);
const { count: earlyLegs } = await db
  .from('delivery_legs').select('*', { count: 'exact', head: true }).eq('order_id', order.id);
check('no leg created', earlyLegs, 0);

// --- mint the intent, then pay it the way the sheet does ------------------
console.log('\nCHECKOUT  intent + Stripe test card');
const intent = await asCustomer(`/v1/me/orders/${order.id}/payment-intent`, token);
check('intent minted', intent.status, 200);
check('amount is the delivery fee', intent.json.amountCents, FEE_CENTS);
check('client secret returned', Boolean(intent.json.clientSecret), true);
check('publishable key returned', intent.json.publishableKey?.startsWith('pk_'), true);

console.log('\nGUARD  confirm with the sheet abandoned');
const abandoned = await asCustomer(`/v1/me/orders/${order.id}/confirm-payment`, token);
check('refused, intent unpaid', abandoned.status, 402);
const { count: abandonedLegs } = await db
  .from('delivery_legs').select('*', { count: 'exact', head: true }).eq('order_id', order.id);
check('still no leg', abandonedLegs, 0);

// PaymentSheet confirms the intent from the device with the card the customer
// typed. Same call, same result — pm_card_visa is Stripe's 4242 test card.
const intentId = intent.json.clientSecret.split('_secret_')[0];
const confirmed = await fetch(`https://api.stripe.com/v1/payment_intents/${intentId}/confirm`, {
  method: 'POST',
  headers: {
    authorization: `Bearer ${env.STRIPE_SECRET_KEY}`,
    'content-type': 'application/x-www-form-urlencoded',
  },
  body: new URLSearchParams({ payment_method: 'pm_card_visa', return_url: 'https://usecreaseapp.com/paid' }),
});
const pi = await confirmed.json();
check('stripe intent succeeded', pi.status, 'succeeded');
check('stripe took the fee', pi.amount_received, FEE_CENTS);

// --- confirm-payment: the new single door ---------------------------------
console.log('\nCONFIRM  the call the app makes when the sheet closes');
const done = await asCustomer(`/v1/me/orders/${order.id}/confirm-payment`, token);
check('confirm accepted', done.status, 200);
check('payment recorded', done.json.paymentStatus, 'captured');
check('dispatched a courier', done.json.dispatched, TIER !== 'return_only');

const { data: paid } = await db
  .from('payments').select('status, captured_cents')
  .eq('order_id', order.id).eq('kind', 'primary').single();
check('payments row written back', paid.status, 'captured');
check('captured the fee', paid.captured_cents, FEE_CENTS);

if (TIER === 'return_only') {
  // Nobody is collecting this bag — the customer carries it in, and the shop's
  // intake is what proves it arrived. Claiming 'at_cleaner' here would be a lie.
  check('waits for the drop-off', await waitForOrder(order.id, ['scheduled']), 'scheduled');
  const { count: legs } = await db
    .from('delivery_legs').select('*', { count: 'exact', head: true }).eq('order_id', order.id);
  check('no courier dispatched', legs, 0);
} else {
  check('courier is the mock', done.json.leg.provider, 'mock');
  check('leg is the pickup', done.json.leg.leg, 'pickup');
  console.log(`  courier: ${done.json.leg.courier_name} (${done.json.leg.courier_vehicle})`);

  console.log('\nCOURIER  the simulated driver runs');
  check('dispatched', await waitForOrder(order.id, ['pickup_dispatched']), 'pickup_dispatched');
  check('bag collected', await waitForOrder(order.id, ['in_transit_to_cleaner']), 'in_transit_to_cleaner');
  check('arrived at the cleaner', await waitForOrder(order.id, ['at_cleaner']), 'at_cleaner');

  // The phone retries on a dropped response, and the Stripe webhook races it.
  // Neither may buy a second courier — that is $12.99 a time once Uber is live.
  console.log('\nIDEMPOTENCY  a retry must not send a second driver');
  const again = await asCustomer(`/v1/me/orders/${order.id}/confirm-payment`, token);
  check('retry accepted', again.status, 200);
  check('no second dispatch', again.json.dispatched, false);
  const { count: legCount } = await db
    .from('delivery_legs').select('*', { count: 'exact', head: true })
    .eq('order_id', order.id).eq('leg', 'pickup');
  check('still exactly one pickup leg', legCount, 1);
}

// --- the tier guard -------------------------------------------------------
// A one-leg order must not be able to talk its way into a second courier.
if (TIER === 'pickup_only') {
  console.log('\nTIER  pickup_only cannot buy a return leg');
  await db.from('orders').update({
    status: 'ready',
    ready_at: new Date().toISOString(),
    return_window_start: new Date(Date.now() + 3600_000).toISOString(),
    return_window_end: new Date(Date.now() + 4 * 3600_000).toISOString(),
  }).eq('id', order.id);
  const sneaky = await asCustomer(`/v1/me/orders/${order.id}/dispatch-return`, token);
  check('return refused', sneaky.status >= 400, true);
  const { count: returnLegs } = await db
    .from('delivery_legs').select('*', { count: 'exact', head: true })
    .eq('order_id', order.id).eq('leg', 'return');
  check('no return leg exists', returnLegs, 0);
}

console.log(`\n${failures === 0 ? 'ALL PASS' : `${failures} FAILURE(S)`}  order ${order.short_code}\n`);
process.exit(failures === 0 ? 0 : 1);
