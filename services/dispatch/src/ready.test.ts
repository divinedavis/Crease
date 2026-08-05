import { strict as assert } from 'node:assert';
import { test } from 'node:test';
import {
  DEFAULT_TURNAROUND_HOURS,
  longestTurnaroundHours,
  readyAtFrom,
  readyWindow,
} from './ready.js';

test('a null override inherits the shop rather than dropping out', () => {
  // The failure this guards: one uncatalogued line item in a dry cleaning bag
  // reading as zero hours and telling the customer their suit is ready now.
  assert.equal(longestTurnaroundHours([{ turnaround_hours: null }, null], 48), 48);
  assert.equal(longestTurnaroundHours([], 24), 24);
  assert.equal(longestTurnaroundHours([{}], null), DEFAULT_TURNAROUND_HOURS);
});

test('the slowest service in the bag decides when the bag is done', () => {
  const hours = longestTurnaroundHours(
    [{ turnaround_hours: 2 }, { turnaround_hours: 24 }, { turnaround_hours: 4 }],
    48,
  );
  assert.equal(hours, 24);
});

test('wash & fold snaps a 48 hour shop default down to two', () => {
  assert.equal(longestTurnaroundHours([{ turnaround_hours: 2 }], 48), 2);
});

test('the estimate runs from arrival, not from when it was computed', () => {
  const arrived = '2026-08-05T17:00:00.000Z';
  assert.equal(readyAtFrom(arrived, 2), '2026-08-05T19:00:00.000Z');
  // A webhook replayed a day late must not move a finish time the shop has
  // been working towards since the handoff.
  assert.equal(readyAtFrom(new Date(arrived), 48), '2026-08-07T17:00:00.000Z');
});

test('the customer is shown half an hour either side', () => {
  const { start, end } = readyWindow('2026-08-05T19:00:00.000Z');
  assert.equal(start, '2026-08-05T18:30:00.000Z');
  assert.equal(end, '2026-08-05T19:30:00.000Z');
});
