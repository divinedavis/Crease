/**
 * Opening hours, as the `cleaners.hours` jsonb column stores them:
 * an array of { dow, open, close }, one entry per open day.
 *
 * dow follows JavaScript's Date.getDay() — 0 is Sunday — because every
 * consumer of this column is JavaScript and a second convention would
 * eventually ship a shop that looks closed on the wrong day. A day with no
 * entry is closed; couriers must arrive inside these windows or the leg gets
 * returned, which is why a shop with no hours at all is worth warning about
 * rather than treating as always-open.
 */

export type DayHours = { dow: number; open: string; close: string };

export const DAY_NAMES = [
  'Sunday',
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
];

const TIME = /^([01]\d|2[0-3]):[0-5]\d$/;

/**
 * Turn the posted form (open_0/close_0/closed_0 … open_6/close_6/closed_6)
 * back into the column shape, or say precisely which day is wrong.
 */
export function parseHoursForm(
  get: (name: string) => FormDataEntryValue | null,
): { hours: DayHours[] } | { error: string } {
  const hours: DayHours[] = [];
  for (let dow = 0; dow < 7; dow++) {
    if (get(`closed_${dow}`)) continue;
    const open = String(get(`open_${dow}`) ?? '');
    const close = String(get(`close_${dow}`) ?? '');
    if (!TIME.test(open) || !TIME.test(close)) {
      return { error: `${DAY_NAMES[dow]}: enter both an opening and a closing time, or mark it closed.` };
    }
    // HH:MM compares correctly as a string. Overnight windows are refused
    // rather than guessed at — a close before an open is far more often a
    // typo than a laundromat that shuts at 2am, and a courier dispatched into
    // the guess knocks on a dark storefront.
    if (close <= open) {
      return { error: `${DAY_NAMES[dow]}: closing time must be after opening time.` };
    }
    hours.push({ dow, open, close });
  }
  return { hours };
}

/** The stored rows keyed by day, for pre-filling the form. */
export function hoursByDay(hours: unknown): Map<number, DayHours> {
  const map = new Map<number, DayHours>();
  if (!Array.isArray(hours)) return map;
  for (const row of hours) {
    if (row && typeof row.dow === 'number' && row.dow >= 0 && row.dow <= 6) {
      map.set(row.dow, { dow: row.dow, open: String(row.open ?? ''), close: String(row.close ?? '') });
    }
  }
  return map;
}
