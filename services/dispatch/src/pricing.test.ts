import { strict as assert } from 'node:assert';
import test from 'node:test';

import {
  cancellationRetainCents,
  cardFeeCents,
  deliveryFeeCents,
  feeForCourierCost,
  FLAT_RATE_LEG_COST_CENTS,
  legsForTier,
  MIN_CANCELLATION_FEE_CENTS,
} from './pricing.js';

// The measured Brooklyn numbers this pricing was built on: $12.99 a leg flat
// under ~3 miles, $15.99 at 6 miles (live Uber Direct quotes, 2026-08-01).
const FLAT_LEG = 1299;
const SIX_MILE_LEG = 1599;

test('a flat-rate route still prices at the published fee', () => {
  // The whole point of deriving TARGET_MARGIN_CENTS from the published price:
  // nothing changes for the common case.
  assert.equal(feeForCourierCost('round_trip', FLAT_LEG), 2995);
  assert.equal(feeForCourierCost('pickup_only', FLAT_LEG), 1995);
  assert.equal(feeForCourierCost('return_only', FLAT_LEG), 1995);
});

test('a six-mile round trip prices above the published fee instead of at a loss', () => {
  const fee = feeForCourierCost('round_trip', SIX_MILE_LEG);
  assert.ok(fee > 2995, `expected a repriced round trip, got ${fee}`);

  // The bug this exists to kill: $29.95 against $31.98 of courier.
  const courier = SIX_MILE_LEG * 2;
  assert.ok(2995 - courier - cardFeeCents(2995) < 0, 'published price should have been a loss here');
  assert.ok(fee - courier - cardFeeCents(fee) > 0, 'repriced fee must clear the courier and the card');
});

test('every priced fee clears courier plus card across the distance range', () => {
  for (const tier of ['round_trip', 'pickup_only', 'return_only']) {
    for (let perLeg = 500; perLeg <= 4000; perLeg += 25) {
      const fee = feeForCourierCost(tier, perLeg);
      const net = fee - perLeg * legsForTier(tier) - cardFeeCents(fee);
      assert.ok(net >= 0, `${tier} @ ${perLeg}/leg netted ${net}`);
    }
  }
});

test('a cheap route is never priced below the published fee', () => {
  assert.equal(feeForCourierCost('round_trip', 100), 2995);
  assert.equal(feeForCourierCost('pickup_only', 1), 1995);
});

test('an unusable quote falls back to the published fee rather than refusing', () => {
  // A carrier outage must not stop a customer booking.
  for (const bad of [null, undefined, 0, -1, Number.NaN]) {
    assert.equal(feeForCourierCost('round_trip', bad as any), 2995);
  }
});

test('a forged low route cost cannot price a delivery below the floor', () => {
  // quoted_leg_cost_cents is customer-insertable; the floor is what makes that
  // safe. See supabase/migrations/0034_order_route_quote.sql.
  assert.equal(feeForCourierCost('round_trip', 1), deliveryFeeCents('round_trip'));
});

test('an unknown tier throws rather than being priced at a guess', () => {
  assert.throws(() => feeForCourierCost('gold_plated', FLAT_LEG), /unknown service tier/);
  assert.throws(() => legsForTier(null), /unknown service tier/);
});

test('prices read like prices', () => {
  for (let perLeg = 500; perLeg <= 4000; perLeg += 25) {
    assert.equal(feeForCourierCost('round_trip', perLeg) % 100, 95);
  }
});

test('cancellation keeps what the engaged couriers actually cost', () => {
  const retained = cancellationRetainCents({
    legs: [{ provider: 'uber', provider_delivery_id: 'del_1', fee_cents: 1299 }],
    capturedCents: 2995,
  });
  assert.equal(retained, 1299 + cardFeeCents(2995));
  assert.ok(retained > MIN_CANCELLATION_FEE_CENTS, 'the old flat $6 under-recovered this');
});

test('both legs engaged retains both fees', () => {
  const retained = cancellationRetainCents({
    legs: [
      { provider: 'uber', provider_delivery_id: 'del_1', fee_cents: 1299 },
      { provider: 'uber', provider_delivery_id: 'del_2', fee_cents: 1299 },
    ],
    capturedCents: 2995,
  });
  assert.equal(retained, 2598 + cardFeeCents(2995));
});

test('a leg that never reached a carrier is not billed to the customer', () => {
  // 'pending' is the claim placeholder and 'none' a refusal recorded before any
  // claim — neither engaged anybody.
  assert.equal(
    cancellationRetainCents({
      legs: [{ provider: 'pending', fee_cents: 1299 }, { provider: 'none' }],
      capturedCents: 2995,
    }),
    0,
  );
});

test('an engaged leg with no recorded fee still costs the flat rate, not nothing', () => {
  // A create whose response was lost may have put a courier on the road.
  const retained = cancellationRetainCents({
    legs: [{ provider: 'uber', provider_delivery_id: 'del_1', fee_cents: null }],
    capturedCents: 2995,
  });
  assert.equal(retained, FLAT_RATE_LEG_COST_CENTS + cardFeeCents(2995));
});

test('a provider-named leg with no delivery id still counts as engaged', () => {
  assert.ok(
    cancellationRetainCents({
      legs: [{ provider: 'uber', fee_cents: 1299 }],
      capturedCents: 2995,
    }) > 0,
  );
});

test('retention never dips under the floor', () => {
  const retained = cancellationRetainCents({
    legs: [{ provider: 'uber', provider_delivery_id: 'del_1', fee_cents: 100 }],
    capturedCents: 0,
  });
  assert.equal(retained, MIN_CANCELLATION_FEE_CENTS);
});

test('card fee matches Stripe US pricing', () => {
  assert.equal(cardFeeCents(2995), 117); // 2.9% + 30c
  assert.equal(cardFeeCents(1995), 88);
  assert.equal(cardFeeCents(0), 0);
});
