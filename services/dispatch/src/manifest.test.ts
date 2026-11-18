import { strict as assert } from 'node:assert';
import { test } from 'node:test';
import { bagManifest } from './manifest.js';

const lb = (quantity: number | string) => ({ quantity, service_item: { unit: 'pound' } });
const pc = (quantity: number | string) => ({ quantity, service_item: { unit: 'piece' } });

test('a wash & fold bag goes out as one heavy item with its weight', () => {
  const m = bagManifest({ short_code: 'CR7', order_items: [lb(18.5)] });
  assert.equal(m.description, 'Laundry bag (wash & fold) — order CR7');
  assert.equal(m.itemCount, 1);
  assert.equal(m.weightLbs, 19);
});

test('dry cleaning counts pieces and claims no weight it does not know', () => {
  const m = bagManifest({ short_code: 'CR8', order_items: [pc(3), pc(2)] });
  assert.equal(m.description, 'Dry cleaning — order CR8');
  assert.equal(m.itemCount, 5);
  assert.equal(m.weightLbs, undefined);
});

test('a mixed order is the bag plus the pieces', () => {
  const m = bagManifest({ order_items: [lb('12'), pc(4)] });
  assert.equal(m.description, 'Laundry bag + dry cleaning');
  assert.equal(m.itemCount, 5);
  assert.equal(m.weightLbs, 12);
});

test("the customer's photo estimate counts before the shop has weighed it", () => {
  const m = bagManifest({ weight_estimate_lb: '22.4', order_items: [] });
  assert.equal(m.weightLbs, 23);
  assert.equal(m.itemCount, 1);
  // ...and the heavier of estimate and weigh-in wins, so a courier is never
  // sent for less than the bag might be.
  assert.equal(bagManifest({ weight_estimate_lb: 10, order_items: [lb(14)] }).weightLbs, 14);
});

test('an order with nothing on it is still one item to carry', () => {
  const m = bagManifest({ order_items: null });
  assert.equal(m.itemCount, 1);
  assert.equal(m.description, 'Dry cleaning');
});

test('lines with no known unit are treated as pieces, not pounds', () => {
  const m = bagManifest({ order_items: [{ quantity: 2, service_item: null }, { quantity: 'x' }] as any });
  assert.equal(m.itemCount, 2);
  assert.equal(m.weightLbs, undefined);
});
