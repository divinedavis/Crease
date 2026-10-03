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

/**
 * Accounts whose orders are development, not business.
 *
 * Every order in this database was placed by one of three accounts — a seeded
 * test customer, a throwaway, and the founder's own — while the payment flow
 * was being built. Reporting 70 orders and $811 collected on a dashboard is
 * not a rounding error, it is a fiction that gets believed, and the first
 * thing it hides is the real number: nobody has bought anything yet.
 *
 * Listed by id in the environment rather than looked up by email, because
 * emails live in auth.users where PostgREST cannot reach them, and one admin
 * API call per dashboard load to re-learn a constant is a strange way to spend
 * a request. Clearing CREASE_TEST_CUSTOMER_IDS turns the exclusion off.
 */
const TEST_CUSTOMER_IDS = (process.env.CREASE_TEST_CUSTOMER_IDS ?? '')
  .split(',')
  .map((id) => id.trim())
  .filter((id) => /^[0-9a-f-]{36}$/i.test(id));

/**
 * Rows a range filter applies to, by their own time column.
 *
 * "This month" and "Today" are calendar windows in New York, the same ones the
 * owner dashboard prints in its header ("Oct 1 → now"). A rolling 30 days here
 * put September requests under an October heading.
 */
function sinceFor(range: string | undefined, now = new Date()): string | null {
  const r = String(range ?? 'all');
  if (r === '6m' || r === '3m') {
    return new Date(now.getTime() - (r === '6m' ? 182 : 91) * 864e5).toISOString();
  }
  if (r !== 'month' && r !== 'today') return null;
  const parts = Object.fromEntries(
    new Intl.DateTimeFormat('en-US', {
      timeZone: 'America/New_York',
      year: 'numeric',
      month: 'numeric',
      day: 'numeric',
    })
      .formatToParts(now)
      .map((p) => [p.type, Number(p.value)]),
  ) as Record<string, number>;
  return nyMidnight(parts.year, parts.month, r === 'month' ? 1 : parts.day).toISOString();
}

/** Midnight on a New York calendar day, as an instant (EST or EDT as it falls). */
function nyMidnight(year: number, month: number, day: number): Date {
  const utc = Date.UTC(year, month - 1, day);
  const nyHour = Number(
    new Intl.DateTimeFormat('en-US', { timeZone: 'America/New_York', hour: 'numeric', hourCycle: 'h23' })
      .format(new Date(utc)),
  );
  // At 00:00 UTC New York reads 19:00 or 20:00 the day before.
  return new Date(utc + (24 - nyHour) * 36e5);
}

export { sinceFor };

export async function dashboardStats(
  db: SupabaseClient,
  range?: string,
): Promise<DashboardStats> {
  const since = sinceFor(range);
  const testIds = TEST_CUSTOMER_IDS;
  // PostgREST wants a parenthesised list; an empty one matches nothing, so the
  // filter is only applied when there is something to exclude.
  const notTest = (q: any) =>
    testIds.length ? q.not('customer_id', 'in', `(${testIds.join(',')})`) : q;

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

  // Rows written by a device marked with /?owner=1. The owner checking his own
  // address is not a household in Fort Greene wanting this, and counting it as
  // one is how a map of demand becomes a map of where he was standing.
  const notOwner = (q: any) => q.eq('owner', false);

  const pingWindow = both(sinceOn('created_at'), notOwner);
  const [checks, inArea, withEmail] = await Promise.all([
    count('demand_pings', pingWindow),
    count('demand_pings', both(pingWindow, (q) => q.eq('in_service_area', true))),
    count('demand_pings', both(pingWindow, (q) => q.not('email', 'is', null))),
  ]);

  // The one place rows are read rather than counted, because "which streets"
  // is the question the map is for — and a neighbourhood name is not a person.
  const { data: hoods } = await (since
    ? notOwner(db.from('demand_pings').select('neighborhood')).gte('created_at', since)
    : notOwner(db.from('demand_pings').select('neighborhood')));
  const tally = new Map<string, number>();
  for (const row of hoods ?? []) {
    const name = (row as any).neighborhood;
    if (name) tally.set(name, (tally.get(name) ?? 0) + 1);
  }
  const neighborhoods = [...tally.entries()]
    .map(([name, checks]) => ({ name, checks }))
    .sort((a, b) => b.checks - a.checks)
    .slice(0, 8);

  // Bot submissions stay in the table for the record but are nobody waiting.
  const notSpam = (q: any) => q.neq('status', 'spam');
  const reqWindow = both(both(sinceOn('created_at'), notOwner), notSpam);
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
    count('orders', both(orderWindow, (q) => notTest(q.neq('status', 'draft')))),
    count('orders', both(orderWindow, (q) => notTest(q.eq('status', 'delivered')))),
    count('orders', both(orderWindow, (q) => notTest(q.in('status', IN_FLIGHT)))),
    count('orders', both(orderWindow, (q) => notTest(q.in('status', ['cancelled', 'failed'])))),
  ]);

  // Realized money, from the view that reconciles what was captured against
  // what the couriers and the shop actually cost.
  // order_margin carries no customer_id, so the test orders are excluded by
  // their short codes rather than left to inflate the money tiles.
  const { data: testOrders } = testIds.length
    ? await db.from('orders').select('short_code').in('customer_id', testIds)
    : { data: [] as any[] };
  const testCodes = new Set(((testOrders ?? []) as any[]).map((r) => r.short_code));

  const { data: margins } = await (since
    ? db.from('order_margin').select('short_code, captured_cents, realized_margin_cents').gte('created_at', since)
    : db.from('order_margin').select('short_code, captured_cents, realized_margin_cents'));
  let captured = 0;
  let margin = 0;
  let paid = 0;
  for (const row of (margins ?? []) as any[]) {
    if (testCodes.has(row.short_code)) continue;
    const c = Number(row.captured_cents) || 0;
    if (c > 0) paid += 1;
    captured += c;
    margin += Number(row.realized_margin_cents) || 0;
  }

  // Customers by their orders, not by the auth table: an account created and
  // never used is not a customer, and counting it as one flatters the funnel.
  const { data: buyers } = await (since
    ? notTest(db.from('orders').select('customer_id').neq('status', 'draft')).gte('created_at', since)
    : notTest(db.from('orders').select('customer_id').neq('status', 'draft')));
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
