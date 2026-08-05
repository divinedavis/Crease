import { strict as assert } from 'node:assert';
import { test } from 'node:test';
import { isPastDue, readyHoursFor, readyRangeLabel } from './ready.ts';

const WASH = { turnaround_hours: 2 };
const SUIT = { turnaround_hours: null };
const COMFORTER = { turnaround_hours: 96 };

test('the slowest thing in the bag decides', () => {
  // Quoting the fast half of a mixed bag promises clothes still in the machine.
  assert.equal(readyHoursFor([WASH, COMFORTER], 48), 96);
  assert.equal(readyHoursFor([WASH], 48), 2);
});

test('a service with no turnaround of its own inherits the shop default', () => {
  assert.equal(readyHoursFor([SUIT], 48), 48);
  assert.equal(readyHoursFor([SUIT], 24), 24);
  // Inherited per item, not once at the end: the override still wins.
  assert.equal(readyHoursFor([SUIT, WASH], 24), 24);
});

test('nothing counted falls back to the shop, not to zero', () => {
  // A zero here would tell the customer their clothes are ready on the spot.
  assert.equal(readyHoursFor([], 24), 24);
  assert.equal(readyHoursFor([], null), 48);
  assert.equal(readyHoursFor([], 0), 48);
  assert.equal(readyHoursFor([{}], undefined), 48);
});

test('the estimate is said as an hour-wide window', () => {
  const label = readyRangeLabel('2026-08-05T22:20:00Z');
  assert.equal(label, 'Aug 5, 2026 at 5:50 PM – 6:50 PM');
});

test('a window that crosses midnight says both days', () => {
  const label = readyRangeLabel('2026-08-06T04:10:00Z');
  assert.equal(label, 'Aug 5, 2026 at 11:40 PM – Aug 6, 2026 at 12:40 AM');
});

test('nothing to promise renders as nothing, not as an invalid date', () => {
  assert.equal(readyRangeLabel(null), null);
  assert.equal(readyRangeLabel(undefined), null);
  assert.equal(readyRangeLabel('not a timestamp'), null);
});

test('late is measured from the end of the window', () => {
  // Inside the window the shop is still on time. Flagging it there teaches the
  // counter to ignore the flag.
  const at = '2026-08-05T22:20:00Z';
  const centre = Date.parse(at);
  assert.equal(isPastDue(at, centre), false);
  assert.equal(isPastDue(at, centre + 29 * 60_000), false);
  assert.equal(isPastDue(at, centre + 31 * 60_000), true);
  assert.equal(isPastDue(null, centre), false);
});
