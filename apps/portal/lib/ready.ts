/**
 * When the shop says the bag will be finished.
 *
 * The customer is shown this same estimate in the app and will quote it back
 * over the phone, so the portal must derive it from the same rule and say it
 * with the same words. Two screens computing their own answer is how "you told
 * me six" becomes an argument nobody can settle.
 *
 * Both halves live here because the intake screen needs both: what the count
 * implies (the turnaround rule) and how it is said (the window).
 */

/**
 * Mirrors the cleaners.turnaround_hours column default. Only reached when the
 * shop row did not come back — better to inherit the slow default than to
 * promise a suit in an hour because a join was empty.
 */
export const DEFAULT_TURNAROUND_HOURS = 48;

/**
 * The estimate is a promise, not a schedule, so it is said as a window. Half
 * an hour either side is wide enough to absorb a busy rack and narrow enough
 * that a customer can plan an evening around it.
 */
const SLACK_MINUTES = 30;

/** The shop's wall clock. The droplet runs UTC and the counter does not. */
const SHOP_TZ = process.env.NEXT_PUBLIC_SHOP_TIMEZONE || 'America/New_York';

/**
 * How long the counted bag takes: the slowest thing in it.
 *
 * A suit and a wash & fold load in the same bag are done when the suit is
 * done, so this takes the maximum rather than an average — quoting the fast
 * half of a mixed order promises clothes that are still in the machine.
 *
 * A null override means the service has no opinion of its own and inherits the
 * shop's default, which is why the fallback is applied per item here instead
 * of once at the end.
 */
export function readyHoursFor(
  counted: Array<{ turnaround_hours?: number | null }>,
  shopDefaultHours: number | null | undefined,
): number {
  const fallback = Number(shopDefaultHours) > 0 ? Number(shopDefaultHours) : DEFAULT_TURNAROUND_HOURS;
  const hours = counted.map((c) =>
    typeof c.turnaround_hours === 'number' && c.turnaround_hours > 0 ? c.turnaround_hours : fallback,
  );
  return hours.length ? Math.max(...hours) : fallback;
}

function windowAround(at: string | Date | null | undefined): { start: Date; end: Date } | null {
  if (!at) return null;
  const centre = at instanceof Date ? at : new Date(at);
  if (Number.isNaN(centre.getTime())) return null;
  return {
    start: new Date(centre.getTime() - SLACK_MINUTES * 60_000),
    end: new Date(centre.getTime() + SLACK_MINUTES * 60_000),
  };
}

/**
 * The window in the app's own wording, so a phone call has one answer.
 * The day is repeated on the end only when the window crosses midnight.
 */
export function readyRangeLabel(at: string | Date | null | undefined): string | null {
  const win = windowAround(at);
  if (!win) return null;

  const day = new Intl.DateTimeFormat('en-US', {
    month: 'short',
    day: 'numeric',
    year: 'numeric',
    timeZone: SHOP_TZ,
  });
  const clock = new Intl.DateTimeFormat('en-US', {
    hour: 'numeric',
    minute: '2-digit',
    timeZone: SHOP_TZ,
  });

  const endDay = day.format(win.end) === day.format(win.start) ? '' : `${day.format(win.end)} at `;
  return `${day.format(win.start)} at ${clock.format(win.start)} – ${endDay}${clock.format(win.end)}`;
}

/**
 * Late against what the customer was told — measured from the end of the
 * window, not its centre. Inside the window the shop is still on time, and a
 * board that says otherwise trains the counter to ignore the flag.
 */
export function isPastDue(at: string | Date | null | undefined, now: number = Date.now()): boolean {
  const win = windowAround(at);
  return Boolean(win && win.end.getTime() < now);
}
