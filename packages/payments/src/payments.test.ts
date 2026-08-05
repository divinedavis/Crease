import { strict as assert } from 'node:assert';
import { createHmac } from 'node:crypto';
import { test } from 'node:test';
import { MockPaymentProvider } from './mock.js';
import { StripeProvider, verifyStripeSignature } from './stripe.js';
import { authorizationAmount, OverAuthorizationError, PaymentProviderError } from './types.js';

const auth = (over: Partial<Parameters<MockPaymentProvider['authorize']>[0]> = {}) => ({
  orderId: 'order_1',
  externalId: `key_${Math.random()}`,
  amountCents: 2400,
  currency: 'usd',
  description: 'Dry cleaning',
  ...over,
});

test('capturing less than authorized releases the balance', async () => {
  const p = new MockPaymentProvider();
  const held = await p.authorize(auth({ amountCents: 3000 }));
  const state = await p.capture({ paymentIntentRef: held.paymentIntentRef, amountCents: 1846 });

  assert.equal(state.status, 'captured');
  assert.equal(state.capturedCents, 1846);
  assert.equal(state.authorizedCents, 3000);
});

test('capturing above the authorization is refused, not silently clamped', async () => {
  // The failure mode this guards: a shop counts more garments than the
  // customer estimated, and a clamped capture would quietly undercharge on
  // every one of those orders forever.
  const p = new MockPaymentProvider();
  const held = await p.authorize(auth({ amountCents: 2400 }));

  await assert.rejects(
    () => p.capture({ paymentIntentRef: held.paymentIntentRef, amountCents: 4200 }),
    (err: unknown) => {
      assert.ok(err instanceof OverAuthorizationError);
      assert.equal(err.authorizedCents, 2400);
      assert.equal(err.requestedCents, 4200);
      return true;
    },
  );

  const after = await p.get(held.paymentIntentRef);
  assert.equal(after.capturedCents, 0, 'nothing may be taken on a refused capture');
  assert.equal(after.status, 'authorized');
});

test('the difference is charged separately once approved', async () => {
  const p = new MockPaymentProvider();
  const held = await p.authorize(auth({ amountCents: 2400 }));
  await p.capture({ paymentIntentRef: held.paymentIntentRef, amountCents: 2400 });

  const extra = await p.chargeDifference(auth({ externalId: 'diff_1', amountCents: 1800 }));
  assert.equal(extra.status, 'captured');
  assert.equal(extra.capturedCents, 1800);
  assert.notEqual(extra.paymentIntentRef, held.paymentIntentRef);
});

test('double capture is refused', async () => {
  const p = new MockPaymentProvider();
  const held = await p.authorize(auth());
  await p.capture({ paymentIntentRef: held.paymentIntentRef, amountCents: 2400 });
  await assert.rejects(() => p.capture({ paymentIntentRef: held.paymentIntentRef, amountCents: 2400 }));
});

test('a cancelled hold cannot be captured', async () => {
  const p = new MockPaymentProvider();
  const held = await p.authorize(auth());
  await p.cancel(held.paymentIntentRef);
  await assert.rejects(() => p.capture({ paymentIntentRef: held.paymentIntentRef, amountCents: 2400 }));
});

test('a captured payment cannot be cancelled, only refunded', async () => {
  const p = new MockPaymentProvider();
  const held = await p.authorize(auth());
  await p.capture({ paymentIntentRef: held.paymentIntentRef, amountCents: 2400 });
  await assert.rejects(() => p.cancel(held.paymentIntentRef));

  const refunded = await p.refund(held.paymentIntentRef);
  assert.equal(refunded.status, 'refunded');
  assert.equal(refunded.refundedCents, 2400);
});

test('partial refunds accumulate and cannot exceed the capture', async () => {
  const p = new MockPaymentProvider();
  const held = await p.authorize(auth({ amountCents: 5000 }));
  await p.capture({ paymentIntentRef: held.paymentIntentRef, amountCents: 5000 });

  const once = await p.refund(held.paymentIntentRef, 2000);
  assert.equal(once.status, 'partially_refunded');
  assert.equal(once.refundedCents, 2000);

  await assert.rejects(() => p.refund(held.paymentIntentRef, 4000), PaymentProviderError);

  const twice = await p.refund(held.paymentIntentRef, 3000);
  assert.equal(twice.status, 'refunded');
  assert.equal(twice.refundedCents, 5000);
});

test('replaying an authorization returns the original hold', async () => {
  // Without this a network timeout on checkout puts two holds on the card.
  const p = new MockPaymentProvider();
  const first = await p.authorize(auth({ externalId: 'stable_key' }));
  const second = await p.authorize(auth({ externalId: 'stable_key' }));
  assert.equal(first.paymentIntentRef, second.paymentIntentRef);
});

test('an uncaptured payment cannot be refunded', async () => {
  const p = new MockPaymentProvider();
  const held = await p.authorize(auth());
  await assert.rejects(() => p.refund(held.paymentIntentRef));
});

test('declines surface as non-retryable with a decline code', async () => {
  const p = new MockPaymentProvider({ declineOnCents: 9999 });
  await assert.rejects(
    () => p.authorize(auth({ amountCents: 9999 })),
    (err: unknown) => {
      assert.ok(err instanceof PaymentProviderError);
      assert.equal(err.opts.retryable, false);
      assert.equal(err.opts.declineCode, 'generic_decline');
      return true;
    },
  );
});

test('the hold never exceeds what we would charge without asking', async () => {
  // The buffer absorbs small overages so the common case stays one tap, but
  // it must never exceed the approval threshold — otherwise we would be
  // holding money we have already decided we would stop and ask about.
  const threshold = 1500;
  for (const estimate of [500, 2400, 6000, 20000]) {
    const amount = authorizationAmount(estimate, threshold);
    assert.ok(amount >= estimate, `${estimate}: hold must cover the estimate`);
    assert.ok(
      amount <= estimate + threshold,
      `${estimate}: hold ${amount} exceeds estimate + threshold`,
    );
  }
});

const SECRET = 'whsec_test';
const body = Buffer.from('{"type":"payment_intent.succeeded"}');
const sign = (ts: number, b: Buffer, secret = SECRET) =>
  createHmac('sha256', secret).update(`${ts}.`).update(b).digest('hex');
const now = () => Math.floor(Date.now() / 1000);

test('a webhook signed for these exact bytes is accepted', () => {
  const t = now();
  assert.equal(verifyStripeSignature(body, `t=${t},v1=${sign(t, body)}`, SECRET), true);
});

test('a signature from a different body is rejected', () => {
  // What this stops: an attacker replaying a genuine succeeded event with the
  // intent id swapped for someone else's order, which would dispatch a courier
  // nobody paid for.
  const t = now();
  const header = `t=${t},v1=${sign(t, body)}`;
  assert.equal(verifyStripeSignature(Buffer.from('{"type":"tampered"}'), header, SECRET), false);
  assert.equal(verifyStripeSignature(body, `t=${t},v1=${sign(t, body, 'whsec_other')}`, SECRET), false);
});

test('an old signature is rejected however valid it once was', () => {
  const stale = now() - 4000;
  assert.equal(verifyStripeSignature(body, `t=${stale},v1=${sign(stale, body)}`, SECRET), false);
});

test('any v1 entry matching is enough, so a rotating secret does not drop events', () => {
  const t = now();
  assert.equal(verifyStripeSignature(body, `t=${t},v1=beef,v1=${sign(t, body)}`, SECRET), true);
  assert.equal(verifyStripeSignature(body, `t=${t},v0=${sign(t, body)}`, SECRET), false);
  assert.equal(verifyStripeSignature(body, '', SECRET), false);
});

test('an intent still settling is not reported as one that never started', async () => {
  // Our status enum has no in-flight value, so both collapse to
  // 'requires_payment_method'. Acting on that alone turns a customer whose card
  // WAS charged away with "try again" — and the retry re-presents a live
  // intent, which the payment sheet refuses. The raw status is the only thing
  // that separates them, so it has to survive the mapping.
  const stripe = new StripeProvider({
    secretKey: 'sk_test',
    fetchImpl: async () =>
      new Response(JSON.stringify({ id: 'pi_1', status: 'processing', amount: 1995 }), {
        headers: { 'content-type': 'application/json' },
      }),
  });

  const state = await stripe.get('pi_1');
  assert.equal(state.status, 'requires_payment_method');
  assert.equal(state.providerStatus, 'processing');
});

test('a small overage captures without a second customer decision', async () => {
  const p = new MockPaymentProvider();
  const estimate = 2400;
  const threshold = 1500;
  const held = await p.authorize(auth({ amountCents: authorizationAmount(estimate, threshold) }));

  // Counted slightly over the estimate but inside the threshold.
  const actual = 2900;
  const state = await p.capture({ paymentIntentRef: held.paymentIntentRef, amountCents: actual });
  assert.equal(state.capturedCents, actual);
});
