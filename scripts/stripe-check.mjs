#!/usr/bin/env node
/**
 * Validate the Stripe adapter against the real Stripe API in test mode.
 *
 * The mock enforces "you cannot capture above the hold" because it was written
 * to. This script exists to confirm two separate things:
 *
 *   1. Stripe genuinely rejects an over-capture — checked with a raw API call,
 *      not through our own precheck, so the assumption the whole approval flow
 *      rests on is verified against the network and not against our own code.
 *   2. Our adapter maps Stripe's real responses onto our vocabulary correctly.
 *
 *   STRIPE_SECRET_KEY=sk_test_... node scripts/stripe-check.mjs
 */
import { StripeProvider, OverAuthorizationError, PaymentProviderError }
  from '../packages/payments/dist/index.js';

const KEY = process.env.STRIPE_SECRET_KEY;
if (!KEY?.startsWith('sk_test_')) {
  console.error('refusing to run without a sk_test_ key');
  process.exit(1);
}

const provider = new StripeProvider({ secretKey: KEY });
let failures = 0;

/**
 * Equality assertion.
 *
 * The first version of this harness took (label, ok, detail) but was called as
 * (label, actual, expected) throughout, so every non-empty string counted as a
 * pass and most of the output was meaningless. An assertion that cannot fail is
 * worse than no assertion, because it reads as evidence.
 */
const check = (label, actual, expected) => {
  const ok = actual === expected;
  if (!ok) failures++;
  console.log(`  ${ok ? 'PASS' : 'FAIL'}  ${label}: ${actual}${ok ? '' : ` (expected ${expected})`}`);
};

/** For conditions rather than values. */
const checkTrue = (label, cond, detail = '') => {
  if (!cond) failures++;
  console.log(`  ${cond ? 'PASS' : 'FAIL'}  ${label}${detail ? ` — ${detail}` : ''}`);
};
const money = (c) => `$${((c ?? 0) / 100).toFixed(2)}`;
const uniq = () => Math.random().toString(36).slice(2, 12);

async function raw(path, body, method = 'POST') {
  const res = await fetch(`https://api.stripe.com/v1${path}`, {
    method,
    headers: {
      authorization: `Bearer ${KEY}`,
      'content-type': 'application/x-www-form-urlencoded',
    },
    body: body ? new URLSearchParams(body).toString() : undefined,
  });
  return { ok: res.ok, status: res.status, json: await res.json() };
}

// --- a customer with a saved card, as a real order would have ---------------
console.log('\nSETUP');
const { json: customer } = await raw('/customers', {
  description: 'Crease adapter check',
  'metadata[purpose]': 'automated-test',
});
checkTrue('created a test customer', Boolean(customer.id), customer.id);

// pm_card_visa is Stripe's canonical test payment method.
const { json: attached } = await raw(`/payment_methods/pm_card_visa/attach`, {
  customer: customer.id,
});
checkTrue('attached a test card', Boolean(attached.id), attached.id);

const common = {
  orderId: 'order_check',
  currency: 'usd',
  customerRef: customer.id,
  paymentMethodRef: attached.id,
  description: 'Crease adapter check',
};

// --- 1. hold, then capture less --------------------------------------------
console.log('\nCASE 1  authorize then capture under the hold');
const held = await provider.authorize({ ...common, externalId: `chk_${uniq()}`, amountCents: 3000 });
check('status maps to authorized', held.status, 'authorized');
check('hold amount recorded', held.authorizedCents, 3000);

const captured = await provider.capture({
  paymentIntentRef: held.paymentIntentRef,
  amountCents: 1396,
});
check('status maps to captured', captured.status, 'captured');
check('captured the lesser amount', captured.capturedCents, 1396);
console.log(`  held ${money(3000)} → captured ${money(1396)}`);

// --- 2. does STRIPE itself refuse an over-capture? --------------------------
console.log('\nCASE 2  Stripe rejects capturing above the hold');
const hold2 = await provider.authorize({ ...common, externalId: `chk_${uniq()}`, amountCents: 3000 });

// Deliberately bypass our adapter's precheck and ask Stripe directly. If this
// ever starts succeeding, the entire approval flow is built on a false premise
// and we would be silently undercharging instead of asking the customer.
const overCapture = await raw(`/payment_intents/${hold2.paymentIntentRef}/capture`, {
  amount_to_capture: '7497',
});
checkTrue('Stripe itself refuses the over-capture', overCapture.ok === false,
  `HTTP ${overCapture.status}`);
checkTrue(
  'and explains why',
  Boolean(overCapture.json.error?.message),
  overCapture.json.error?.message?.slice(0, 90),
);

// Now the same thing through the adapter — should be a typed error.
let typed = null;
try {
  await provider.capture({ paymentIntentRef: hold2.paymentIntentRef, amountCents: 7497 });
} catch (err) {
  typed = err;
}
checkTrue('adapter raises OverAuthorizationError', typed instanceof OverAuthorizationError, typed?.name);
check('error carries the hold amount', typed?.authorizedCents, 3000);
check('error carries the requested amount', typed?.requestedCents, 7497);

const untouched = await provider.get(hold2.paymentIntentRef);
check('nothing captured on the refused attempt', untouched.capturedCents, 0);
check('hold still live', untouched.status, 'authorized');

// --- 3. approval path: capture the hold, charge the remainder ---------------
console.log('\nCASE 3  customer approves — capture hold, charge the difference');
const first = await provider.capture({ paymentIntentRef: hold2.paymentIntentRef, amountCents: 3000 });
check('hold captured in full', first.capturedCents, 3000);

const diff = await provider.chargeDifference({
  ...common,
  externalId: `chk_${uniq()}`,
  amountCents: 7497 - 3000,
});
check('difference charged', diff.status, 'captured');
check('difference amount', diff.capturedCents, 4497);
check('total equals the counted price', first.capturedCents + diff.capturedCents, 7497);

// --- 4. refunds -------------------------------------------------------------
console.log('\nCASE 4  refunds');
const partial = await provider.refund(diff.paymentIntentRef, 1000);
check('partial refund recorded', partial.status, 'partially_refunded');
check('refunded amount', partial.refundedCents, 1000);

const full = await provider.refund(diff.paymentIntentRef, 3497);
check('full refund recorded', full.status, 'refunded');
check('total refunded', full.refundedCents, 4497);

// --- 5. releasing an uncaptured hold ----------------------------------------
console.log('\nCASE 5  cancel an uncaptured hold');
const hold3 = await provider.authorize({ ...common, externalId: `chk_${uniq()}`, amountCents: 2400 });
const cancelled = await provider.cancel(hold3.paymentIntentRef);
check('hold released', cancelled.status, 'cancelled');
check('nothing taken', cancelled.capturedCents, 0);

// --- 6. declines ------------------------------------------------------------
console.log('\nCASE 6  a declined card is non-retryable');
// pm_card_chargeDeclined is refused at *attach* time, so it cannot be saved to
// a customer first. Passed straight to the intent it declines at confirmation,
// which is the path a real expired or frozen card takes.
let declineErr = null;
try {
  await provider.authorize({
    orderId: 'order_check',
    currency: 'usd',
    description: 'Crease decline check',
    paymentMethodRef: 'pm_card_chargeDeclined',
    externalId: `chk_${uniq()}`,
    amountCents: 2400,
  });
} catch (err) {
  declineErr = err;
}
checkTrue('decline surfaces as a payment error', declineErr instanceof PaymentProviderError,
  declineErr ? declineErr.name : 'no error was thrown');
check('and is not retried', declineErr?.opts?.retryable, false);
checkTrue('with a decline code', Boolean(declineErr?.opts?.declineCode), declineErr?.opts?.declineCode);

console.log(failures === 0 ? '\nALL CHECKS PASSED\n' : `\n${failures} CHECK(S) FAILED\n`);
process.exit(failures === 0 ? 0 : 1);
