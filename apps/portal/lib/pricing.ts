/**
 * How a counted intake becomes money.
 *
 * This lives in one place because it is applied twice: the intake form shows
 * the counter what a line will cost, and the server action decides what is
 * actually billed. Those two must agree exactly — a customer who watched the
 * screen say $33.75 and then sees $39.15 on their card has caught the shop
 * lying, even if the difference was an honest rounding split.
 *
 * Both rules here exist because laundry is sold by weight:
 *
 *   - the weight minimum, which every shop enforces and which makes a 4 lb
 *     order viable against a $25.98 round trip
 *   - per-line rounding, because a fractional weight times a cent price gives
 *     fractional cents, and money columns hold integers
 */

export type PricedItem = {
  unit_price_cents: number;
  /** Pounds for laundry, garments for everything else. */
  unit?: 'piece' | 'pound';
  /** Shop's floor. Zero for per-piece services, which have no minimum. */
  minimum_units?: number | string | null;
};

/**
 * What the shop bills for a line, which is not always what the scale read.
 *
 * Returns zero for a zero entry rather than lifting it to the minimum: a line
 * the counter left blank is a line that was not part of the order, and
 * charging a 15 lb floor for it would invent an item.
 */
export function billableUnits(item: PricedItem, entered: number): number {
  if (!Number.isFinite(entered) || entered <= 0) return 0;
  const floor = Number(item.minimum_units) || 0;
  return Math.max(entered, floor);
}

/** One line's charge, in whole cents. */
export function lineTotalCents(item: PricedItem, entered: number): number {
  return Math.round(billableUnits(item, entered) * item.unit_price_cents);
}

/**
 * The bill.
 *
 * Rounds each line and then sums, rather than summing and rounding once. The
 * order matters: the customer sees per-line totals on the intake screen and on
 * their receipt, and a total that does not equal the visible lines added up is
 * the kind of discrepancy that turns into a chargeback.
 */
export function subtotalCents(
  items: Array<{ item: PricedItem; entered: number }>,
): number {
  return items.reduce((sum, { item, entered }) => sum + lineTotalCents(item, entered), 0);
}
