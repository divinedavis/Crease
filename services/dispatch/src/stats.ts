import type { SupabaseClient } from '@supabase/supabase-js';

/**
 * Crease, counted, for the owner dashboard that already exists.
 *
 * Find A Crib's dashboard renders any site that hands it a payload, and both
 * sites sit on this droplet — so the numbers are aggregated here, where the
 * schema is, and read over loopback. The alternative was giving another
 * process Crease's service-role key, which is every row in the database for
 * the sake of a dozen counts.
 *
 * Counts only. No name, phone, address or email leaves this route: the tables
 * underneath it are a list of where people live, and a dashboard needs the
 * shape of the demand, not the people.
 */

export interface DashboardStats {
  generated_at: string;
  since: string | null;
  demand: {
    checks: number;
    in_area: number;
    outside: number;
    with_email: number;
    neighborhoods: Array<{ name: string; checks: number }>;
  };
  requests: { total: number; new: number; contacted: number; booked: number; declined: number };
  orders: {
    total: number;
    paid: number;
    delivered: number;
    in_flight: number;
    cancelled: number;
    captured_cents: number;
    margin_cents: number;
  };
  customers: { total: number; repeat: number };
  canvass: {
    shops: number;
    dry_cleaners: number;
    laundromats: number;
    contacted: number;
    interested: number;
    following_up: number;
    declined: number;
  };
  partners: { active: number; payouts_enabled: number };
}

/** Rows a range filter applies to, by their own time column. */
function sinceFor(range: string | undefined): string | null {
  const days: Record<string, number> = { today: 1, month: 30, '3m': 90, '6m': 182 };
  const n = days[String(range ?? 'all')];
  if (!n) return null;
  const from = new Date();
  if (range === 'today') from.setUTCHours(0, 0, 0, 0);
  else from.setUTCDate(from.getUTCDate() - n);
  return from.toISOString();
}

export async function dashboardStats(
  db: SupabaseClient,
  range?: string,
): Promise<DashboardStats> {
  const since = sinceFor(range);

  // head:true counts server-side. A dashboard tile is a number; pulling rows to
  // produce one would move a customer list across the wire to be thrown away.
  const count = async (table: string, apply: (q: any) => any = (q) => q) => {
    let q = db.from(table).select('id', { count: 'exact', head: true });
    q = apply(q);
    const { count: n } = await q;
    return n ?? 0;
  };
  const sinceOn = (col: string) => (q: any) => (since ? q.gte(col, since) : q);
  const both = (a: (q: any) => any, b: (q: any) => any) => (q: any) => b(a(q));

  const pingWindow = sinceOn('created_at');
  const [checks, inArea, withEmail] = await Promise.all([
    count('demand_pings', pingWindow),
    count('demand_pings', both(pingWindow, (q) => q.eq('in_service_area', true))),
    count('demand_pings', both(pingWindow, (q) => q.not('email', 'is', null))),
  ]);

  // The one place rows are read rather than counted, because "which streets"
  // is the question the map is for — and a neighbourhood name is not a person.
  const { data: hoods } = await (since
    ? db.from('demand_pings').select('neighborhood').gte('created_at', since)
    : db.from('demand_pings').select('neighborhood'));
  const tally = new Map<string, number>();
  for (const row of hoods ?? []) {
    const name = (row as any).neighborhood;
    if (name) tally.set(name, (tally.get(name) ?? 0) + 1);
  }
  const neighborhoods = [...tally.entries()]
    .map(([name, checks]) => ({ name, checks }))
    .sort((a, b) => b.checks - a.checks)
    .slice(0, 8);

  const reqWindow = sinceOn('created_at');
  const [reqTotal, reqNew, reqContacted, reqBooked, reqDeclined] = await Promise.all([
    count('pickup_requests', reqWindow),
    count('pickup_requests', both(reqWindow, (q) => q.eq('status', 'new'))),
    count('pickup_requests', both(reqWindow, (q) => q.eq('status', 'contacted'))),
    count('pickup_requests', both(reqWindow, (q) => q.eq('status', 'booked'))),
    count('pickup_requests', both(reqWindow, (q) => q.eq('status', 'declined'))),
  ]);

  const orderWindow = sinceOn('created_at');
  const IN_FLIGHT = [
    'scheduled',
    'pickup_dispatched',
    'in_transit_to_cleaner',
    'at_cleaner',
    'awaiting_approval',
    'cleaning',
    'ready',
    'return_dispatched',
    'in_transit_to_customer',
  ];
  const [orderTotal, delivered, inFlight, cancelled] = await Promise.all([
    // Drafts are not orders. Somebody who opened the app and closed it is
    // demand, and it is counted as demand, not as a sale.
    count('orders', both(orderWindow, (q) => q.neq('status', 'draft'))),
    count('orders', both(orderWindow, (q) => q.eq('status', 'delivered'))),
    count('orders', both(orderWindow, (q) => q.in('status', IN_FLIGHT))),
    count('orders', both(orderWindow, (q) => q.in('status', ['cancelled', 'failed']))),
  ]);

  // Realized money, from the view that reconciles what was captured against
  // what the couriers and the shop actually cost.
  const { data: margins } = await (since
    ? db.from('order_margin').select('captured_cents, realized_margin_cents').gte('created_at', since)
    : db.from('order_margin').select('captured_cents, realized_margin_cents'));
  let captured = 0;
  let margin = 0;
  let paid = 0;
  for (const row of (margins ?? []) as any[]) {
    const c = Number(row.captured_cents) || 0;
    if (c > 0) paid += 1;
    captured += c;
    margin += Number(row.realized_margin_cents) || 0;
  }

  // Customers by their orders, not by the auth table: an account created and
  // never used is not a customer, and counting it as one flatters the funnel.
  const { data: buyers } = await (since
    ? db.from('orders').select('customer_id').neq('status', 'draft').gte('created_at', since)
    : db.from('orders').select('customer_id').neq('status', 'draft'));
  const perCustomer = new Map<string, number>();
  for (const row of (buyers ?? []) as any[]) {
    if (!row.customer_id) continue;
    perCustomer.set(row.customer_id, (perCustomer.get(row.customer_id) ?? 0) + 1);
  }
  const repeat = [...perCustomer.values()].filter((n) => n > 1).length;

  // The canvass is a standing total, never windowed: "479 shops in Brooklyn"
  // does not mean anything different this month than last.
  const [shops, dryCleaners, laundromats, visited, interested, followUp, declined] =
    await Promise.all([
      count('prospects'),
      count('prospects', (q) => q.eq('kind', 'dry_cleaner')),
      count('prospects', (q) => q.eq('kind', 'laundromat')),
      count('prospects', (q) => q.eq('visited', true)),
      count('prospects', (q) => q.eq('outcome', 'interested')),
      count('prospects', (q) => q.eq('outcome', 'follow_up')),
      count('prospects', (q) => q.eq('outcome', 'declined')),
    ]);

  const [activePartners, payoutsReady] = await Promise.all([
    count('cleaners', (q) => q.eq('active', true)),
    count('cleaners', (q) => q.eq('active', true).eq('payouts_enabled', true)),
  ]);

  return {
    generated_at: new Date().toISOString(),
    since,
    demand: {
      checks,
      in_area: inArea,
      outside: Math.max(0, checks - inArea),
      with_email: withEmail,
      neighborhoods,
    },
    requests: {
      total: reqTotal,
      new: reqNew,
      contacted: reqContacted,
      booked: reqBooked,
      declined: reqDeclined,
    },
    orders: {
      total: orderTotal,
      paid,
      delivered,
      in_flight: inFlight,
      cancelled,
      captured_cents: captured,
      margin_cents: margin,
    },
    customers: { total: perCustomer.size, repeat },
    canvass: {
      shops,
      dry_cleaners: dryCleaners,
      laundromats,
      contacted: visited,
      interested,
      following_up: followUp,
      declined,
    },
    partners: { active: activePartners, payouts_enabled: payoutsReady },
  };
}
