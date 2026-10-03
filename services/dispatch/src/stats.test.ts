import { test } from 'node:test';
import assert from 'node:assert/strict';
import { sinceFor } from './stats.js';

test('"this month" starts at midnight on the 1st in New York, not 30 days back', () => {
  // 7pm EDT on 3 Oct 2026 — the dashboard header reads "Oct 1 → now".
  const now = new Date('2026-10-03T23:04:00Z');
  assert.equal(sinceFor('month', now), '2026-10-01T04:00:00.000Z');
});

test('"today" is New York midnight, also across the UTC date line', () => {
  // 9pm EDT on 3 Oct is already 4 Oct in UTC.
  assert.equal(sinceFor('today', new Date('2026-10-04T01:00:00Z')), '2026-10-03T04:00:00.000Z');
});

test('winter months use EST', () => {
  assert.equal(sinceFor('month', new Date('2026-12-15T12:00:00Z')), '2026-12-01T05:00:00.000Z');
});

test('all time has no lower bound', () => {
  assert.equal(sinceFor('all'), null);
  assert.equal(sinceFor(undefined), null);
});

test('3 and 6 months are rolling windows', () => {
  const now = new Date('2026-10-03T12:00:00Z');
  assert.equal(sinceFor('3m', now), new Date(now.getTime() - 91 * 864e5).toISOString());
  assert.equal(sinceFor('6m', now), new Date(now.getTime() - 182 * 864e5).toISOString());
});
