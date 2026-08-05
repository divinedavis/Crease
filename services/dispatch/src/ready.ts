/**
 * When the laundry will be done.
 *
 * The estimate is anchored on when the bag ARRIVED at the shop, never on when
 * it was booked and never on when somebody got round to counting it. A courier
 * who is late, or a webhook that lands ten minutes after the handoff, must not
 * push the finish time out — the work started when the clothes did.
 */

/** Shown as a range, because an estimate stated to the minute reads as a
 *  promise. Half an hour either side is honest and still useful. */
export const READY_WINDOW_MINUTES = 30;

/** What a shop that has said nothing is assumed to take. Matches the column
 *  default on cleaners.turnaround_hours. */
export const DEFAULT_TURNAROUND_HOURS = 48;

/**
 * The slowest thing in the bag decides when the bag is done.
 *
 * A null on a service item means "inherit the shop's speed" rather than a
 * copied number that goes stale, so it falls back rather than being skipped —
 * skipping it would let one uncatalogued line item quietly halve the estimate.
 * This is what snaps a wash & fold order from 48 hours down to two, and what
 * keeps a mixed bag on the dry cleaning clock where it belongs.
 */
export function longestTurnaroundHours(
  items: ReadonlyArray<{ turnaround_hours?: number | null } | null | undefined>,
  cleanerHours: number | null | undefined,
): number {
  const fallback = cleanerHours ?? DEFAULT_TURNAROUND_HOURS;
  return items.reduce<number>(
    (slowest, item) => Math.max(slowest, item?.turnaround_hours ?? fallback),
    0,
  ) || fallback;
}

/** Arrival plus turnaround, as an ISO timestamp. */
export function readyAtFrom(arrivedAt: string | Date, hours: number): string {
  const from = arrivedAt instanceof Date ? arrivedAt.getTime() : Date.parse(arrivedAt);
  const base = Number.isNaN(from) ? Date.now() : from;
  return new Date(base + hours * 3_600_000).toISOString();
}

/** The range the customer is shown, so every surface renders the same one. */
export function readyWindow(estimatedReadyAt: string): { start: string; end: string } {
  const at = Date.parse(estimatedReadyAt);
  const spread = READY_WINDOW_MINUTES * 60_000;
  return {
    start: new Date(at - spread).toISOString(),
    end: new Date(at + spread).toISOString(),
  };
}
