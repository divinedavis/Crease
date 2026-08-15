/**
 * Delivery windows — the customer-chosen times that become courier dispatch
 * times.
 *
 * This lives in its own module rather than beside the route that writes it
 * because the two windows on an order arrive by different doors. The return
 * window comes through a route here and can be checked at the door; the pickup
 * window is INSERTed straight into `orders` by the app and never passes a route
 * at all. The only place both are guaranteed to meet is the dispatcher that
 * spends money on them, so the check has to be importable from there too.
 */

/** How far ahead a delivery window may be booked. Long enough for a week away,
 *  short enough that a mistyped year cannot park a courier in 2036. */
export const WINDOW_HORIZON_DAYS = 30;

/** Which window is being checked — only the customer-facing wording differs. */
export type WindowKind = 'pickup' | 'delivery';

/**
 * The chosen window, or the reason it is not one.
 *
 * Checked rather than trusted: these are the fields that go straight to a
 * carrier as a dispatch time. A window that has already closed quotes as "send
 * someone now", and a far-future one holds an order open indefinitely against a
 * quote that expired months earlier.
 */
export function parseWindow(
  start?: string | null,
  end?: string | null,
  kind: WindowKind = 'delivery',
): { start: string; end: string } | { error: string } {
  const plural = kind === 'pickup' ? 'Pickups' : 'Deliveries';
  if (!start || !end) return { error: `A ${kind} window needs both a start and an end time.` };

  const from = Date.parse(start);
  const to = Date.parse(end);
  if (Number.isNaN(from) || Number.isNaN(to)) return { error: `That ${kind} time is not a date.` };
  if (from >= to) return { error: `A ${kind} window has to end after it starts.` };

  // The end, not the start: "as soon as possible" legitimately opens a minute
  // ago, but a window that has already closed is not a time anyone can be sent.
  const now = Date.now();
  if (to <= now) return { error: `That ${kind} time has already passed.` };
  if (from > now + WINDOW_HORIZON_DAYS * 24 * 60 * 60 * 1000) {
    return { error: `${plural} can be booked up to ${WINDOW_HORIZON_DAYS} days ahead.` };
  }

  return { start: new Date(from).toISOString(), end: new Date(to).toISOString() };
}
