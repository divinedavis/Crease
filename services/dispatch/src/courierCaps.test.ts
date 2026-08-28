import { strict as assert } from 'node:assert';
import { test } from 'node:test';
import { courierCapDecision, reachedCarrier, type DispatchedLeg } from './courierCaps.js';

const LIMITS = { maxLegsPerDay: 3, maxCentsPerDay: 5_000 };

/** n legs that each reached a real carrier at the given price. */
function dispatched(n: number, feeCents = 1_299): DispatchedLeg[] {
  return Array.from({ length: n }, (_, i) => ({
    provider: 'uber_direct',
    provider_delivery_id: `del_${i}`,
    fee_cents: feeCents,
  }));
}

test('the simulator never spends the budget', () => {
  // Otherwise an App Review session — which is routed to the mock precisely so
  // that it costs nothing — could hit a limit that exists to bound real money.
  const decision = courierCapDecision({
    leg: 'pickup',
    simulated: true,
    feeCents: 1_299,
    recentLegs: dispatched(99),
    limits: LIMITS,
  });
  assert.equal(decision.refusal, null);
  assert.equal(decision.exceeded, false);
});

test('an ordinary day is invisible', () => {
  const decision = courierCapDecision({
    leg: 'pickup',
    simulated: false,
    feeCents: 1_299,
    recentLegs: dispatched(1),
    limits: LIMITS,
  });
  assert.equal(decision.refusal, null);
  assert.equal(decision.legsToday, 2);
  assert.equal(decision.centsToday, 2_598);
});

test('the leg count catches a runaway that surge pricing would hide', () => {
  // Many cheap legs never trip a cents-only cap, which is exactly the shape a
  // retry loop has: same short route, over and over.
  const decision = courierCapDecision({
    leg: 'pickup',
    simulated: false,
    feeCents: 100,
    recentLegs: dispatched(3, 100),
    limits: LIMITS,
  });
  assert.match(decision.refusal ?? '', /daily courier limit reached/);
  assert.equal(decision.legsToday, 4);
});

test('the cents cap catches a surge that the leg count would hide', () => {
  const decision = courierCapDecision({
    leg: 'pickup',
    simulated: false,
    feeCents: 4_000,
    recentLegs: dispatched(1, 4_000),
    limits: LIMITS,
  });
  assert.match(decision.refusal ?? '', /daily courier limit reached/);
  assert.equal(decision.centsToday, 8_000);
});

test('a return leg is never refused, however far over the cap it is', () => {
  // The shop is holding this customer's clothes. Stranding a bag on a counter
  // to save thirteen dollars is the worse outcome, so the cap reports and
  // stands aside — the caller still logs it loudly.
  const decision = courierCapDecision({
    leg: 'return',
    simulated: false,
    feeCents: 9_999,
    recentLegs: dispatched(50),
    limits: LIMITS,
  });
  assert.equal(decision.refusal, null);
  assert.equal(decision.exceeded, true, 'it still has to be reported');
});

test('legs that never reached a carrier do not spend the budget', () => {
  // A claim row sits at provider 'pending' until something quotes it, and a
  // leg that failed before dispatch is marked 'none'. Counting either would
  // let a bad afternoon of failures block a good evening of orders.
  const decision = courierCapDecision({
    leg: 'pickup',
    simulated: false,
    feeCents: 1_299,
    recentLegs: [
      { provider: 'pending', fee_cents: 1_299 },
      { provider: 'none', fee_cents: 1_299 },
      { provider: null, fee_cents: 1_299 },
      { provider: 'mock', provider_delivery_id: 'mock_1', fee_cents: 900 },
    ],
    limits: LIMITS,
  });
  assert.equal(decision.refusal, null);
  assert.equal(decision.legsToday, 1, 'only the leg being dispatched now');
  assert.equal(decision.centsToday, 1_299);
});

test('a create whose response was lost still counts', () => {
  // The carrier may well have put a courier on the road; a row that names a
  // provider but carries no delivery id is the trace that leaves.
  assert.equal(reachedCarrier({ provider: 'uber_direct' }), true);
  assert.equal(reachedCarrier({ provider_delivery_id: 'del_1' }), true);
  assert.equal(reachedCarrier({ provider: 'pending' }), false);
  assert.equal(reachedCarrier({ provider: 'none' }), false);
  assert.equal(reachedCarrier({}), false);
});

test('caps set to zero switch the whole thing off', () => {
  const decision = courierCapDecision({
    leg: 'pickup',
    simulated: false,
    feeCents: 99_999,
    recentLegs: dispatched(500),
    limits: { maxLegsPerDay: 0, maxCentsPerDay: 0 },
  });
  assert.equal(decision.refusal, null);
});
