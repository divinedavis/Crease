#!/usr/bin/env node
/**
 * Seed one cleaner, one customer, and one order in Brooklyn.
 * Idempotent — re-running reuses the same cleaner slug and test user.
 *
 *   node scripts/seed.mjs
 */
import { createClient } from '@supabase/supabase-js';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const env = Object.fromEntries(
  readFileSync(join(root, 'services/dispatch/.env'), 'utf8')
    .split('\n')
    .filter((l) => l.includes('=') && !l.startsWith('#'))
    .map((l) => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1)]),
);

const db = createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY, {
  auth: { persistSession: false },
});

const TEST_EMAIL = 'testcustomer@crease.local';

// --- customer -------------------------------------------------------------
const { data: existing } = await db.auth.admin.listUsers();
let user = existing.users.find((u) => u.email === TEST_EMAIL);
if (!user) {
  const { data, error } = await db.auth.admin.createUser({
    email: TEST_EMAIL,
    password: 'crease-dev-password',
    email_confirm: true, // no verification step, per product rule
    user_metadata: { full_name: 'Test Customer' },
  });
  if (error) throw error;
  user = data.user;
}
await db.from('profiles').upsert({ id: user.id, full_name: 'Test Customer', phone: '+15555550123' });
console.log('customer:', user.id);

// --- address --------------------------------------------------------------
let { data: address } = await db
  .from('addresses')
  .select('*')
  .eq('user_id', user.id)
  .eq('label', 'Home')
  .maybeSingle();
if (!address) {
  const { data, error } = await db
    .from('addresses')
    .insert({
      user_id: user.id,
      label: 'Home',
      line1: '215 Bedford Ave',
      city: 'Brooklyn',
      state: 'NY',
      postal_code: '11211',
      lat: 40.7178,
      lng: -73.9569,
      access_notes: 'Buzzer 3R — leave with doorman if out',
    })
    .select()
    .single();
  if (error) throw error;
  address = data;
}
console.log('address:', address.id);

// --- cleaner --------------------------------------------------------------
let { data: cleaner } = await db
  .from('cleaners')
  .select('*')
  .eq('slug', 'bedford-cleaners')
  .maybeSingle();
if (!cleaner) {
  const { data, error } = await db
    .from('cleaners')
    .insert({
      name: 'Bedford Cleaners',
      slug: 'bedford-cleaners',
      phone: '+15555550199',
      email: 'shop@bedfordcleaners.local',
      line1: '404 Bedford Ave',
      city: 'Brooklyn',
      state: 'NY',
      postal_code: '11249',
      lat: 40.7141,
      lng: -73.9613,
      turnaround_hours: 48,
    })
    .select()
    .single();
  if (error) throw error;
  cleaner = data;
}
console.log('cleaner:', cleaner.id);

const PRICES = [
  ['shirt', 'Laundered shirt', 349, 0],
  ['pants', 'Pants / slacks', 799, 1],
  ['suit_2pc', 'Two-piece suit', 1899, 2],
  ['dress', 'Dress', 1599, 3],
  ['coat', 'Overcoat', 2499, 4],
  ['comforter', 'Comforter', 3499, 5],
];
await db.from('service_items').upsert(
  PRICES.map(([code, label, unit_price_cents, sort_order]) => ({
    cleaner_id: cleaner.id,
    code,
    label,
    unit_price_cents,
    sort_order,
  })),
  { onConflict: 'cleaner_id,code' },
);

// --- order ----------------------------------------------------------------
const now = Date.now();
const { data: order, error: orderErr } = await db
  .from('orders')
  .insert({
    customer_id: user.id,
    cleaner_id: cleaner.id,
    address_id: address.id,
    status: 'scheduled',
    pickup_window_start: new Date(now).toISOString(),
    pickup_window_end: new Date(now + 2 * 3600_000).toISOString(),
    estimate_subtotal_cents: 2400,
    customer_notes: '3 shirts, 1 pair of slacks. Light starch.',
  })
  .select()
  .single();
if (orderErr) throw orderErr;

console.log('order:', order.id, order.short_code);
console.log(JSON.stringify({ userId: user.id, cleanerId: cleaner.id, orderId: order.id }));
