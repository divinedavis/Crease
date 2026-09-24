import { test } from 'node:test';
import assert from 'node:assert/strict';
import { milesBetween, withinServiceArea, SERVICE_RADIUS_MILES } from './serviceArea.js';

// Fulton Cleaners, 909 Fulton St — the live partner.
const fulton = { lat: 40.683389, lng: -73.96713 };

test('the radius is three miles', () => {
  assert.equal(SERVICE_RADIUS_MILES, 3);
});

test('a Clinton Hill door is inside', () => {
  const clintonAve = { lat: 40.6936, lng: -73.9688 }; // 100 Clinton Ave
  assert.ok(milesBetween(fulton, clintonAve) < 1);
  assert.equal(withinServiceArea(clintonAve, fulton), true);
});

test('a Manhattan door is outside', () => {
  const unionSquare = { lat: 40.7359, lng: -73.9911 };
  assert.ok(milesBetween(fulton, unionSquare) > 3);
  assert.equal(withinServiceArea(unionSquare, fulton), false);
});

test('missing coordinates are outside, not waved through', () => {
  assert.equal(withinServiceArea({ lat: null as any, lng: -73.9 }, fulton), false);
  assert.equal(withinServiceArea({ lat: 40.69, lng: -73.97 }, null), false);
});
