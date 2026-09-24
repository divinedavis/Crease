/**
 * A shop's price list, as the shop types it into /settings.
 *
 * Every number here is quoted to customers the moment it is saved — the app
 * and the booking sheet read service_items directly — so the parser refuses
 * anything it would be embarrassing to quote rather than clamping it into
 * range. A price of $0.00 is refused too: a free service is a typo far more
 * often than it is a promotion, and nothing in the booking flow can charge
 * for a line priced at nothing.
 *
 * Existing orders are not touched by a change here: order_items bakes the unit
 * price into each row when the order is created.
 */

export const SERVICE_TYPES = ['wash_fold', 'dry_clean', 'press'] as const;
export type ServiceType = (typeof SERVICE_TYPES)[number];

export const SERVICE_TYPE_LABEL: Record<ServiceType, string> = {
  wash_fold: 'Laundry',
  dry_clean: 'Dry cleaning',
  press: 'Pressing',
};

export type Unit = 'pound' | 'piece';

export interface ServiceItemInput {
  label: string;
  service_type: ServiceType;
  unit: Unit;
  unit_price_cents: number;
  minimum_units: number;
  turnaround_hours: number | null;
  active: boolean;
}

const MAX_PRICE_CENTS = 99_999; // $999.99 — a wedding dress, not a typo'd extra zero past it
const MAX_MINIMUM_LB = 100;

type Read = (name: string) => FormDataEntryValue | null;

/** Dollars as typed ("2", "2.5", "$2.50") to whole cents, or null if it isn't money. */
export function parseDollars(raw: string): number | null {
  const cleaned = raw.trim().replace(/^\$/, '');
  if (!/^\d{1,4}(\.\d{1,2})?$/.test(cleaned)) return null;
  return Math.round(Number(cleaned) * 100);
}

export function parseServiceItemForm(read: Read): { item: ServiceItemInput } | { error: string } {
  const text = (name: string) => String(read(name) ?? '').trim();

  const label = text('label');
  if (!label) return { error: 'Give the service a name, like “Wash & fold” or “Comforter”.' };
  if (label.length > 60) return { error: 'Keep the name under 60 characters.' };

  const serviceType = text('service_type') as ServiceType;
  if (!SERVICE_TYPES.includes(serviceType)) return { error: 'Pick which kind of service this is.' };

  // Dry cleaning and pressing are counted by the garment. Only laundry is
  // weighed — the app asks for pounds or pieces off this one field, and a
  // per-pound dry-cleaning price would be read as a price per garment.
  const unit = text('unit') as Unit;
  if (unit !== 'pound' && unit !== 'piece') return { error: 'Pick per pound or per item.' };
  if (unit === 'pound' && serviceType !== 'wash_fold') {
    return { error: 'Only laundry can be priced by the pound. Dry cleaning and pressing are per item.' };
  }

  const price = parseDollars(text('price'));
  if (price === null) return { error: 'Enter the price in dollars, like 2.00.' };
  if (price <= 0) return { error: 'The price has to be more than $0.00.' };
  if (price > MAX_PRICE_CENTS) return { error: 'That price is over $999.99. Check it for an extra zero.' };

  let minimum = 0;
  if (unit === 'pound') {
    const rawMin = text('minimum');
    if (rawMin) {
      if (!/^\d{1,3}(\.\d{1,2})?$/.test(rawMin)) return { error: 'Enter the minimum in pounds, like 10.' };
      minimum = Number(rawMin);
      if (minimum > MAX_MINIMUM_LB) return { error: `A minimum over ${MAX_MINIMUM_LB} lb is almost certainly a typo.` };
    }
  }

  let turnaround: number | null = null;
  const rawTurn = text('turnaround_hours');
  if (rawTurn) {
    if (!/^\d{1,3}$/.test(rawTurn)) return { error: 'Turnaround is a whole number of hours.' };
    turnaround = Number(rawTurn);
    if (turnaround < 1 || turnaround > 336) return { error: 'Turnaround must be between 1 hour and 14 days (336 hours).' };
  }

  return {
    item: {
      label,
      service_type: serviceType,
      unit,
      unit_price_cents: price,
      minimum_units: minimum,
      turnaround_hours: turnaround,
      active: read('active') === 'on',
    },
  };
}

/**
 * The row's `code`, which is unique per shop across every service type (the
 * original constraint was never dropped when service types arrived). Derived
 * from the name, suffixed until it is free.
 */
export function codeFor(label: string, serviceType: ServiceType, taken: Iterable<string>): string {
  const slug =
    label
      .toLowerCase()
      .normalize('NFKD')
      .replace(/[^a-z0-9]+/g, '_')
      .replace(/^_+|_+$/g, '')
      .slice(0, 40) || 'item';
  const base = `${serviceType}_${slug}`;
  const used = new Set(taken);
  if (!used.has(base)) return base;
  for (let n = 2; ; n++) {
    if (!used.has(`${base}_${n}`)) return `${base}_${n}`;
  }
}

export function priceLine(item: { unit: string; unit_price_cents: number; minimum_units: number | string }): string {
  const price = `$${(item.unit_price_cents / 100).toFixed(2)}`;
  if (item.unit !== 'pound') return `${price} each`;
  const min = Number(item.minimum_units);
  return min > 0 ? `${price} / lb · ${min} lb minimum` : `${price} / lb`;
}
