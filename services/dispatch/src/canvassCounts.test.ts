import { test } from 'node:test';
import assert from 'node:assert/strict';
import { parseCanvassCounts } from './canvassCounts.js';

test('canvass_counts() jsonb maps to the seven counters', () => {
  const row = {
    shops: 479, dry_cleaners: 146, laundromats: 333, contacted: 8,
    interested: 2, following_up: 3, declined: 3,
  };
  assert.deepEqual(parseCanvassCounts(row), row);
});

test('missing or odd values read as 0, never NaN', () => {
  const c = parseCanvassCounts({ shops: '12', declined: null, interested: 'x' });
  assert.equal(c.shops, 12);
  assert.equal(c.declined, 0);
  assert.equal(c.interested, 0);
  assert.equal(c.laundromats, 0);
});

test('a null payload is all zeros', () => {
  assert.deepEqual(Object.values(parseCanvassCounts(null)), [0, 0, 0, 0, 0, 0, 0]);
});
