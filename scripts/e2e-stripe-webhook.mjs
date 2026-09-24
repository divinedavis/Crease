#!/usr/bin/env node
/**
 * The recovery path for a phone that dies mid-checkout.
 *
 * confirm-payment is the normal door: the app calls it the moment the sheet
 * closes. But the card is already charged by then, so anything that stops that
 * call from landing — the app killed, the train going into a tunnel — strands a
 * paid order with no courier and nothing to notice. /webhooks/stripe is the
 * backstop, and it is worth testing precisely because it only ever runs when
 * something else has already gone wrong.
 *
 *   CREASE_TEST_PASSWORD=... node scripts/e2e-stripe-webhook.mjs
 *
 * Needs STRIPE_WEBHOOK_SECRET set on the service being tested.
 */
import { createHmac } from 'node:crypto';
import { adminClient, readEnv } from './lib/client.mjs';

const TEST_PASSWORD = process.env.CREASE_TEST_PASSWORD;
if (!TEST_PASSWORD) {
  console.error('set CREASE_TEST_PASSWORD before running this');
  process.exit(1);
}

const { env, db } = await adminClient();
const anon = readEnv('apps/ios/Secrets.xcconfig');
const BASE = process.env.CREASE_BASE ?? env.PUBLIC_URL ?? 'http://localhost:8080';
const SECRET = process.env.STRIPE_WEBHOOK_SECRET ?? env.STRIPE_WEBHOOK_SECRET;
if (!SECRET) {
  console.error('set STRIPE_WEBHOOK_SECRET to whatever the service is running with');
  process.exit(1);
}

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

/** Stripe signs `${timestamp}.${rawBody}`; the header carries both. */
async function postEvent(body, { secret = SECRET, timestamp = Math.floor(Date.now() / 1000) } = {}) {
  const raw = JSON.stringify(body);
  const signature = createHmac('sha256', secret).update(`${timestamp}.${raw}`).digest('hex');
  const res = await fetch(`${BASE}/webhooks/stripe`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', 'stripe-signature': `t=${timestamp},v1=${signature}` },
    body: raw,
  });
  return { status: res.status, json: await res.json().catch(() => ({})) };
}

// Checkout is a manual-capture hold, so the event Stripe actually sends when
// the card clears is amount_capturable_updated; payment_intent.succeeded only
// arrives at intake, once the shop captures.
const succeeded = (intentId) => ({
  id: `evt_${Math.random().toString(36).slice(2)}`,
  type: 'payment_intent.amount_capturable_updated',
  data: { object: { id: intentId, object: 'payment_intent' } },
});

// --- a paid order whose confirm call never landed -------------------------
console.log('\nSIGN IN  testcustomer@crease.local');
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

const { data: address } = await db
  .from('addresses').select('id').eq('user_id', user.id).limit(1).single();
const { data: cleaner } = await db
  .from('cleaners').select('id').eq('slug', 'bedford-cleaners').single();

const now = new Date();
const { data: order } = await db.from('orders').insert({
  customer_id: user.id,
  cleaner_id: cleaner.id,
  address_id: address.id,
  status: 'draft',
  estimate_subtotal_cents: 0,
  delivery_fee_cents: 1695,
  service_tier: 'pickup_only',
  pickup_window_start: now.toISOString(),
  pickup_window_end: new Date(now.getTime() + 2 * 3600_000).toISOString(),
}).select('id, short_code').single();
console.log(`\nDRAFT  ${order.short_code} (${order.id})`);

const intentRes = await fetch(`${BASE}/v1/me/orders/${order.id}/payment-intent`, {
  method: 'POST',
  headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
  body: '{}',
});
const intent = await intentRes.json();
const HELD_CENTS = intent.amountCents;
const intentId = intent.clientSecret.split('_secret_')[0];

// Live keys on the server mean a test card cannot pay this intent, so there is
// no held money for the webhook to recover. The signature checks still run.
const LIVE = intent.publishableKey?.startsWith('pk_live_');

console.log('\nCHARGE  card taken, then the app dies before confirm-payment');
if (!LIVE) await fetch(`https://api.stripe.com/v1/payment_intents/${intentId}/confirm`, {
  method: 'POST',
  headers: {
    authorization: `Bearer ${env.STRIPE_SECRET_KEY}`,
    'content-type': 'application/x-www-form-urlencoded',
  },
  body: new URLSearchParams({ payment_method: 'pm_card_visa', return_url: 'https://usecreaseapp.com/paid' }),
});
const { data: stranded } = await db.from('orders').select('status').eq('id', order.id).single();
check('order is stranded', stranded.status, 'draft');

// --- forgery must not move an order --------------------------------------
console.log('\nSIGNATURE  an unsigned or wrongly-signed event is not a payment');
const unsigned = await fetch(`${BASE}/webhooks/stripe`, {
  method: 'POST',
  headers: { 'content-type': 'application/json' },
  body: JSON.stringify(succeeded(intentId)),
});
check('unsigned rejected', unsigned.status, 401);

const wrongKey = await postEvent(succeeded(intentId), { secret: 'whsec_not_the_real_one' });
check('wrong secret rejected', wrongKey.status, 401);

// A captured payload replayed days later must not still be a valid instruction.
const stale = await postEvent(succeeded(intentId), { timestamp: Math.floor(Date.now() / 1000) - 3600 });
check('stale timestamp rejected', stale.status, 401);

const { data: untouched } = await db.from('orders').select('status').eq('id', order.id).single();
check('nothing moved it', untouched.status, 'draft');

if (LIVE) {
  // A correctly signed 'succeeded' for an intent nobody paid disagrees with
  // Stripe's own record — refused with a 500, and the order must not move.
  console.log('\nLIVE   server is on live Stripe keys — paid-recovery path skipped (needs a real card)');
  const unpaid = await postEvent(succeeded(intentId));
  check('signed event for an unpaid intent refused', unpaid.status, 500);
  const { data: still } = await db.from('orders').select('status').eq('id', order.id).single();
  check('order still not dispatched', still.status, 'draft');
  console.log(`\n${failures === 0 ? 'ALL PASS' : `${failures} FAILURE(S)`}  order ${order.short_code}\n`);
  process.exit(failures === 0 ? 0 : 1);
}

// --- the real event rescues the order ------------------------------------
console.log('\nWEBHOOK  Stripe tells us what the app could not');
const real = await postEvent(succeeded(intentId));
check('accepted', real.status, 200);

check('promoted and dispatched', await waitForOrder(order.id, ['pickup_dispatched']), 'pickup_dispatched');
check('arrived at the cleaner', await waitForOrder(order.id, ['at_cleaner']), 'at_cleaner');

const { data: paid } = await db
  .from('payments').select('status, captured_cents, authorized_cents')
  .eq('order_id', order.id).eq('kind', 'primary').single();
check('payment written back as held', paid.status, 'authorized');
check('held the fee', paid.authorized_cents, HELD_CENTS);
check('nothing captured before intake', paid.captured_cents, 0);

// --- Stripe retries; the customer must not pay for that -------------------
console.log('\nREDELIVERY  Stripe resends events, and does so routinely');
const again = await postEvent(succeeded(intentId));
check('redelivery accepted', again.status, 200);
const { count: legs } = await db
  .from('delivery_legs').select('*', { count: 'exact', head: true })
  .eq('order_id', order.id).eq('leg', 'pickup');
check('still exactly one pickup leg', legs, 1);

// --- an intent we have never seen ----------------------------------------
console.log('\nUNKNOWN  an event for someone else’s intent');
const foreign = await postEvent(succeeded('pi_never_heard_of_this_one'));
check('acknowledged, not retried forever', foreign.status, 200);

console.log(`\n${failures === 0 ? 'ALL PASS' : `${failures} FAILURE(S)`}  order ${order.short_code}\n`);
process.exit(failures === 0 ? 0 : 1);
