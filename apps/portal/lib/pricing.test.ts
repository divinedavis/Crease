import { strict as assert } from 'node:assert';
import { test } from 'node:test';
import { billableUnits, lineTotalCents, subtotalCents } from './pricing.ts';

const WASH = { unit_price_cents: 225, unit: 'pound' as const, minimum_units: 15 };
const SHIRT = { unit_price_cents: 349, unit: 'piece' as const, minimum_units: 0 };

test('a scale reading is billed to the pound, not rounded down', () => {
  // The whole reason quantity became numeric. 17.4 lb truncated to 17 loses
  // ninety cents an order, every order, invisibly.
  assert.equal(lineTotalCents(WASH, 17.4), 3915);
  assert.notEqual(lineTotalCents(WASH, 17.4), lineTotalCents(WASH, 17));
});

test('under the minimum bills the minimum', () => {
  assert.equal(billableUnits(WASH, 12), 15);
  assert.equal(lineTotalCents(WASH, 12), 3375);
});

test('over the minimum bills the real weight', () => {
  assert.equal(billableUnits(WASH, 22.5), 22.5);
  assert.equal(lineTotalCents(WASH, 22.5), 5063);
});

test('a blank line stays blank rather than becoming a minimum charge', () => {
  // Lifting zero to the floor would invent a fifteen pound order the customer
  // never handed over.
  assert.equal(billableUnits(WASH, 0), 0);
  assert.equal(lineTotalCents(WASH, 0), 0);
});

test('per-piece services are unaffected by the minimum machinery', () => {
  assert.equal(lineTotalCents(SHIRT, 3), 1047);
  assert.equal(lineTotalCents(SHIRT, 0), 0);
});

test('the total equals the visible lines added up', () => {
  // Rounding once at the end would give 5484 here. The customer can see both
  // lines, so the sum has to match what they can check by hand.
  const lines = [
    { item: WASH, entered: 17.4 },
    { item: SHIRT, entered: 4.5 },
  ];
  const byHand = lines.reduce((n, l) => n + lineTotalCents(l.item, l.entered), 0);
  assert.equal(subtotalCents(lines), byHand);
  assert.equal(subtotalCents(lines), 3915 + 1571);
});

test('garbage input cannot become a charge', () => {
  assert.equal(billableUnits(WASH, NaN), 0);
  assert.equal(billableUnits(WASH, -5), 0);
  assert.equal(billableUnits(WASH, Infinity), 0);
});

test('a missing minimum is treated as no minimum, not as NaN', () => {
  // PostgREST sends numeric as a number, but a null column and an absent
  // field both reach this code, and Number(null) is 0 while Number(undefined)
  // is NaN — which would silently zero every line if it leaked through.
  assert.equal(billableUnits({ unit_price_cents: 225 }, 8), 8);
  assert.equal(billableUnits({ unit_price_cents: 225, minimum_units: null }, 8), 8);
});
