import { strict as assert } from 'node:assert';
import { test } from 'node:test';
import { milesBetween, nearestShop, SERVICE_RADIUS_MILES } from './coverage.ts';

const FULTON = { id: 'fulton', name: 'Fulton Cleaners', lat: 40.683389, lng: -73.96713 };
const CLINTON_HILL = { id: 'chdc', name: 'Clinton Hill Dry Cleaning', lat: 40.6941, lng: -73.9686 };

test('a Brooklyn block is a Brooklyn block', () => {
  // 909 Fulton to 400 Myrtle is a walk, and the maths should say so.
  const miles = milesBetween(FULTON, CLINTON_HILL);
  assert.ok(miles > 0.5 && miles < 1.2, `expected under a mile-ish, got ${miles}`);
});

test('the nearest shop is the one reported, not the first in the list', () => {
  // Standing on Fulton's doorstep.
  const cover = nearestShop({ lat: 40.6834, lng: -73.9671 }, [CLINTON_HILL, FULTON]);
  assert.equal(cover.shop?.id, 'fulton');
  assert.equal(cover.covered, true);
});

test('past the courier band is a no, however close it feels', () => {
  // Coney Island is Brooklyn and is not servable from Clinton Hill: the
  // published fee is priced on a flat rate that stops at three miles.
  const cover = nearestShop({ lat: 40.5755, lng: -73.9707 }, [FULTON, CLINTON_HILL]);
  assert.equal(cover.covered, false);
  assert.ok((cover.miles ?? 0) > SERVICE_RADIUS_MILES);
});

test('no partners at all is a no rather than a crash', () => {
  const cover = nearestShop({ lat: 40.68, lng: -73.96 }, []);
  assert.deepEqual(cover, { covered: false, shop: null, miles: null });
});
