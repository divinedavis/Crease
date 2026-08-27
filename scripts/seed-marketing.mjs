#!/usr/bin/env node
/**
 * Give the demo customer a plausible order history, against the real partner.
 *
 * Separate from seed.mjs on purpose. seed.mjs builds the *test* fixture —
 * Bedford Cleaners, a shop that was invented while the app was being written
 * and which migration 0043 deactivated — and half the e2e scripts look that
 * slug up by name, so repointing it would break them. What the App Store
 * panels and App Review need is the opposite: the one shop that actually
 * exists, and an Orders screen that is not empty.
 *
 * Idempotent through fixed short codes: re-running rewrites the same three
 * rows rather than piling up orders on the demo account.
 *
 *   CREASE_ALLOW_PROD=1 node scripts/seed-marketing.mjs
 *
 * The prod flag is deliberate. These rows are only useful on the stack the
 * TestFlight build and App Review actually talk to.
 */
import { adminClient } from './lib/client.mjs';

const TEST_EMAIL = 'testcustomer@crease.local';

const { db } = await adminClient();

// --- customer -------------------------------------------------------------
const { data: existing, error: listErr } = await db.auth.admin.listUsers();
if (listErr) throw listErr;
const user = existing.users.find((u) => u.email === TEST_EMAIL);
if (!user) throw new Error(`${TEST_EMAIL} does not exist — run scripts/seed.mjs first`);

// --- the real partner -----------------------------------------------------
// By `active`, not by slug: the panels should show whichever shop the app
// itself would offer, so this cannot drift away from what a customer sees.
const { data: cleaners, error: cleanerErr } = await db
  .from('cleaners')
  .select('id, name, slug')
  .eq('active', true);
if (cleanerErr) throw cleanerErr;
if (cleaners.length !== 1) {
  console.warn(`${cleaners.length} active cleaners — using ${cleaners[0]?.name}`);
}
const cleaner = cleaners[0];
if (!cleaner) throw new Error('no active cleaner to seed against');

// --- address --------------------------------------------------------------
const { data: address, error: addrErr } = await db
  .from('addresses')
  .select('id, line1')
  .eq('user_id', user.id)
  .order('created_at', { ascending: true })
  .limit(1)
  .maybeSingle();
if (addrErr) throw addrErr;
if (!address) throw new Error('demo customer has no address — run scripts/seed.mjs first');

// Abandoned checkouts pile up on a demo account — forty of them the first time
// this ran — and each renders a "Payment wasn't completed" card above the
// orders worth looking at. Nothing is ever charged for a draft, so they are
// safe to drop, and both the panels and App Review want the list to read like
// a customer's.
const { error: draftErr, count: draftsCleared } = await db
  .from('orders')
  .delete({ count: 'exact' })
  .eq('customer_id', user.id)
  .eq('status', 'draft');
if (draftErr) throw draftErr;
console.log(`cleared ${draftsCleared ?? 0} draft orders`);

// The three rows below, named up front so the cancel sweep can spare them.
const ORDER_CODES = ['A7C219', 'B4E80D', 'C1F53A'];

// Months of e2e runs also left open orders on this account — two dozen of
// them, most against shops migration 0043 deactivated, so the app renders them
// with a blank shop name. Cancelling rather than deleting keeps the legs and
// payouts that prove the money path works; it just moves them out of the
// active list, under Past orders, where they belong.
const { error: staleErr, count: staleCancelled } = await db
  .from('orders')
  .update({ status: 'cancelled', cancelled_reason: 'test fixture' }, { count: 'exact' })
  .eq('customer_id', user.id)
  .not('status', 'in', '(delivered,cancelled,failed)')
  .not('short_code', 'in', `(${ORDER_CODES.join(',')})`);
if (staleErr) throw staleErr;
console.log(`cancelled ${staleCancelled ?? 0} stale open orders`);

const hour = 3600_000;
const now = Date.now();

// One order per stage worth photographing: the wait before pickup, the days at
// the shop that every other tracker leaves silent, and the moment the customer
// picks their own return time.
const ORDERS = [
  {
    short_code: 'A7C219',
    status: 'scheduled',
    pickup_window_start: new Date(now + hour).toISOString(),
    pickup_window_end: new Date(now + 3 * hour).toISOString(),
    estimate_subtotal_cents: 2400,
    delivery_fee_cents: 2995,
    service_tier: 'round_trip',
    customer_notes: 'Wash & fold, about 12 lb. Nothing delicate.',
  },
  {
    short_code: 'B4E80D',
    status: 'cleaning',
    pickup_window_start: new Date(now - 26 * hour).toISOString(),
    pickup_window_end: new Date(now - 24 * hour).toISOString(),
    estimate_subtotal_cents: 3596,
    subtotal_cents: 3596,
    delivery_fee_cents: 2995,
    service_tier: 'round_trip',
    customer_notes: '4 laundered shirts, 1 pair of slacks. Light starch.',
  },
  {
    short_code: 'C1F53A',
    status: 'ready',
    pickup_window_start: new Date(now - 50 * hour).toISOString(),
    pickup_window_end: new Date(now - 48 * hour).toISOString(),
    estimate_subtotal_cents: 3200,
    subtotal_cents: 3349,
    delivery_fee_cents: 2995,
    service_tier: 'round_trip',
    customer_notes: 'Two dresses and an overcoat.',
  },
];

for (const order of ORDERS) {
  const row = {
    ...order,
    customer_id: user.id,
    cleaner_id: cleaner.id,
    address_id: address.id,
    total_cents: (order.subtotal_cents ?? order.estimate_subtotal_cents) + order.delivery_fee_cents,
  };
  const { data, error } = await db
    .from('orders')
    .upsert(row, { onConflict: 'short_code' })
    .select('id, short_code, status')
    .single();
  if (error) throw error;
  console.log(`${data.short_code}  ${data.status.padEnd(10)}  ${data.id}`);
}

console.log(`seeded ${ORDERS.length} orders for ${TEST_EMAIL} at ${cleaner.name} (${address.line1})`);
