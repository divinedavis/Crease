import { strict as assert } from 'node:assert';
import { test } from 'node:test';
import { parseHoursForm, hoursByDay } from './hours.ts';

function form(entries: Record<string, string>) {
  return (name: string) => (name in entries ? entries[name] : null);
}

test('open days become rows, closed days become nothing', () => {
  const result = parseHoursForm(
    form({
      closed_0: 'on',
      open_1: '08:00',
      close_1: '19:00',
      closed_2: 'on',
      closed_3: 'on',
      closed_4: 'on',
      closed_5: 'on',
      open_6: '09:00',
      close_6: '14:00',
    }),
  );
  assert.deepEqual(result, {
    hours: [
      { dow: 1, open: '08:00', close: '19:00' },
      { dow: 6, open: '09:00', close: '14:00' },
    ],
  });
});

test('a close at or before the open is refused by name', () => {
  const result = parseHoursForm(
    form({
      open_0: '10:00',
      close_0: '09:00',
      closed_1: 'on',
      closed_2: 'on',
      closed_3: 'on',
      closed_4: 'on',
      closed_5: 'on',
      closed_6: 'on',
    }),
  );
  assert.match((result as { error: string }).error, /^Sunday: closing time must be after/);
});

test('a day neither closed nor filled in is an error, not silently closed', () => {
  // Leaving Monday blank almost always means "I forgot", and treating it as
  // closed would quietly stop pickups for a day the shop works.
  const entries: Record<string, string> = {};
  for (let d = 0; d < 7; d++) if (d !== 1) entries[`closed_${d}`] = 'on';
  const result = parseHoursForm(form(entries));
  assert.match((result as { error: string }).error, /^Monday: enter both/);
});

test('hoursByDay tolerates the column being garbage', () => {
  assert.equal(hoursByDay(null).size, 0);
  assert.equal(hoursByDay('[]').size, 0);
  assert.equal(hoursByDay([{ dow: 9, open: 'x', close: 'y' }]).size, 0);
  assert.equal(hoursByDay([{ dow: 2, open: '08:00', close: '18:00' }]).get(2)?.close, '18:00');
});
