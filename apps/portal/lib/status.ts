/** Shop-floor wording. Nobody behind a counter says "in_transit_to_cleaner". */
export const STATUS_LABEL: Record<string, string> = {
  draft: 'Not paid yet',
  scheduled: 'Paid — courier not sent',
  pickup_dispatched: 'Courier heading to customer',
  in_transit_to_cleaner: 'On its way to you',
  at_cleaner: 'Needs intake',
  awaiting_approval: 'Waiting on customer',
  cleaning: 'Cleaning',
  ready: 'Ready to send back',
  return_dispatched: 'Courier heading to you',
  in_transit_to_customer: 'Out for delivery',
  delivered: 'Delivered',
  cancelled: 'Cancelled',
  failed: 'Needs attention',
};

export const LEG_LABEL: Record<string, string> = {
  pending: 'Queued',
  dispatching: 'Finding a courier',
  courier_assigned: 'Courier assigned',
  en_route_to_pickup: 'Heading to pickup',
  at_pickup: 'At pickup',
  picked_up: 'Collected',
  en_route_to_dropoff: 'Heading to dropoff',
  at_dropoff: 'At dropoff',
  delivered: 'Delivered',
  returned: 'Came back undelivered',
  cancelled: 'Cancelled',
  failed: 'Failed',
};

/**
 * What the customer bought. The counter has to know this before the bag is
 * finished: a pickup-only order leaves over the counter and a "Send it back"
 * on it would book a second courier nobody paid for.
 */
export const TIER_LABEL: Record<string, string> = {
  round_trip: 'Round trip — we collect and we deliver back',
  pickup_only: 'Pickup only — the customer collects from you',
  return_only: 'Drop-off — the customer brings it in, we deliver back',
};

/**
 * The status as the counter should read it, corrected for what the customer
 * bought. The bare status cannot carry this: 'ready' means "book the courier"
 * on a round trip and "they are coming in for it" on a pickup-only order, and
 * 'scheduled' means "a driver is booked" on every tier except a drop-off,
 * where nobody is coming until the customer walks in with the bag.
 *
 * The app tells that same customer "Ready to collect", so this says it too.
 * Two screens describing one bag differently is how a shop ends up couriering
 * an order back to someone standing at the counter waiting for it.
 */
export function statusLabel(status: string, tier?: string | null): string {
  if (status === 'ready' && tier === 'pickup_only') return 'Ready to collect';
  if (status === 'scheduled' && tier === 'return_only') return 'Paid — waiting for the drop-off';
  return STATUS_LABEL[status] ?? status;
}

export function statusTone(status: string): 'neutral' | 'live' | 'warn' | 'danger' {
  if (status === 'failed' || status === 'cancelled') return 'danger';
  if (status === 'at_cleaner' || status === 'ready' || status === 'awaiting_approval') return 'warn';
  if (
    ['pickup_dispatched', 'in_transit_to_cleaner', 'return_dispatched', 'in_transit_to_customer'].includes(
      status,
    )
  ) {
    return 'live';
  }
  return 'neutral';
}

export function money(cents: number | null | undefined): string {
  if (cents == null) return '—';
  return `$${(cents / 100).toFixed(2)}`;
}

/**
 * Board columns, in the order a shop works them: what needs hands first,
 * then what is blocked, then what is merely moving.
 *
 * Every status the queue query returns has to appear here. The query excludes
 * only delivered and cancelled, so a status missing from this list is fetched
 * and then drawn nowhere — a board that looks like an idle shop while orders
 * pile up behind it.
 *
 * A row lands in the first column that claims it, so a `tier` column must sit
 * directly above the untiered column it narrows: the narrow one takes the
 * orders it names and the general one catches everything else, including a
 * tier this build has never heard of.
 *
 * `tile` marks the columns worth a headline number at the top of the page —
 * the counts a shop glances at between customers. `tone` colors that tile's
 * dot only; the number itself stays in text ink. `background` collapses the
 * column behind its count: those orders exist, but they are not this
 * counter's work, and 29 unpaid drafts must not bury the three bags that are.
 */
export const BOARD: {
  title: string;
  statuses: string[];
  tier?: string;
  empty: string;
  tile?: boolean;
  tone?: 'neutral' | 'live' | 'warn' | 'danger';
  background?: boolean;
}[] = [
  // Neither of the first two is the shop's work, so they stay out of the way
  // until something is genuinely stuck in one.
  { title: 'Not paid yet', statuses: ['draft'], empty: '', background: true },
  // A drop-off never gets a leg 1 — the customer carries the bag in — so
  // filing it under couriers would have the counter waiting on a driver who
  // was never booked. What this column is really saying is "expect a person".
  {
    title: 'Expecting a drop-off',
    statuses: ['scheduled'],
    tier: 'return_only',
    empty: '',
  },
  // Paid, no courier booked. This is its own column and not part of "On the
  // road" because nothing is moving yet — filing it under couriers told the
  // counter a driver was coming when nobody had asked for one.
  { title: 'Waiting on a courier', statuses: ['scheduled'], empty: '' },
  {
    title: 'Needs intake',
    statuses: ['at_cleaner'],
    empty: 'Nothing waiting to be counted.',
    tile: true,
    tone: 'warn',
  },
  {
    title: 'Waiting on customer',
    statuses: ['awaiting_approval'],
    empty: 'No orders held for approval.',
    tile: true,
    tone: 'warn',
  },
  { title: 'Cleaning', statuses: ['cleaning'], empty: 'Nothing on the rack.', tile: true, tone: 'neutral' },
  // Split off before "send back" can be read as an instruction: this bag is
  // collected over the counter, and a courier booked against it is a fare
  // nobody paid for.
  {
    title: 'Waiting to be collected',
    statuses: ['ready'],
    tier: 'pickup_only',
    empty: '',
  },
  {
    title: 'Ready to send back',
    statuses: ['ready'],
    empty: 'Nothing ready to go out.',
    tile: true,
    tone: 'warn',
  },
  {
    title: 'On the road',
    statuses: [
      'pickup_dispatched',
      'in_transit_to_cleaner',
      'return_dispatched',
      'in_transit_to_customer',
    ],
    empty: 'No couriers moving.',
    tile: true,
    tone: 'live',
  },
  { title: 'Needs attention', statuses: ['failed'], empty: '', tile: true, tone: 'danger' },
];
