/** Shop-floor wording. Nobody behind a counter says "in_transit_to_cleaner". */
export const STATUS_LABEL: Record<string, string> = {
  draft: 'Draft',
  scheduled: 'Scheduled',
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
 */
export const BOARD: { title: string; statuses: string[]; empty: string }[] = [
  { title: 'Needs intake', statuses: ['at_cleaner'], empty: 'Nothing waiting to be counted.' },
  {
    title: 'Waiting on customer',
    statuses: ['awaiting_approval'],
    empty: 'No orders held for approval.',
  },
  { title: 'Cleaning', statuses: ['cleaning'], empty: 'Nothing on the rack.' },
  { title: 'Ready to send back', statuses: ['ready'], empty: 'Nothing ready to go out.' },
  {
    title: 'On the road',
    statuses: [
      'scheduled',
      'pickup_dispatched',
      'in_transit_to_cleaner',
      'return_dispatched',
      'in_transit_to_customer',
    ],
    empty: 'No couriers moving.',
  },
  { title: 'Needs attention', statuses: ['failed'], empty: '' },
];
