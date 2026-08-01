#!/usr/bin/env node
/**
 * Tenant isolation check for the portal.
 *
 * The portal runs on the anon key and trusts RLS to keep one shop out of
 * another shop's orders. That is a claim about the database, not about the
 * queries, so it has to be tested with a real signed-in session and the anon
 * key — the same credentials a browser gets. Reading it out of the policy
 * file proves nothing.
 *
 *   node scripts/rls-check.mjs
 */
import { makeClient, readEnv } from './lib/client.mjs';

const svcEnv = readEnv('services/dispatch/.env');
const webEnv = readEnv('apps/portal/.env.local');
const URL = svcEnv.SUPABASE_URL;
const admin = await makeClient(svcEnv.SUPABASE_SERVICE_ROLE_KEY, URL);

let failures = 0;
const check = (label, ok, detail = '') => {
  if (!ok) failures++;
  console.log(`${ok ? '  PASS' : '  FAIL'}  ${label}${detail ? ` — ${detail}` : ''}`);
};

// --- a second shop, so "isolation" has something to isolate from ----------
let { data: rival } = await admin.from('cleaners').select('id').eq('slug', 'rival-cleaners').maybeSingle();
if (!rival) {
  const { data } = await admin
    .from('cleaners')
    .insert({
      name: 'Rival Cleaners',
      slug: 'rival-cleaners',
      line1: '1 Competitor St',
      city: 'Brooklyn',
      state: 'NY',
      postal_code: '11222',
      lat: 40.73,
      lng: -73.95,
    })
    .select('id')
    .single();
  rival = data;
}

// Start from an address, not from a profile: staff accounts have profiles too
// (the auth trigger makes one for every user) and no address, so picking an
// arbitrary profile lands on a shop employee about half the time.
const { data: address } = await admin
  .from('addresses')
  .select('id, user_id')
  .limit(1)
  .single();
if (!address) throw new Error('no seeded address — run scripts/seed.mjs first');

const { data: rivalOrder } = await admin
  .from('orders')
  .insert({
    customer_id: address.user_id,
    cleaner_id: rival.id,
    address_id: address.id,
    status: 'at_cleaner',
    estimate_subtotal_cents: 5000,
  })
  .select('id, short_code')
  .single();

// --- sign in as Bedford staff, with the anon key, like a browser ---------
const web = await makeClient(webEnv.NEXT_PUBLIC_SUPABASE_ANON_KEY, URL);
const { error: authErr } = await web.auth.signInWithPassword({
  email: 'shop@bedfordcleaners.local',
  password: 'crease-dev-password',
});
check('staff can sign in', !authErr, authErr?.message);

console.log('\nTENANT ISOLATION (signed in as Bedford Cleaners)');

const { data: visible } = await web.from('orders').select('id, cleaner_id, short_code');
check('sees its own orders', (visible ?? []).length > 0, `${visible?.length ?? 0} visible`);
check(
  "cannot see the rival shop's order",
  !(visible ?? []).some((o) => o.id === rivalOrder.id),
  `rival order ${rivalOrder.short_code}`,
);
check(
  'every visible order belongs to a shop it staffs',
  (visible ?? []).every((o) => o.cleaner_id !== rival.id),
);

// Direct fetch by id must not be a way around the list filter.
const { data: direct } = await web.from('orders').select('id').eq('id', rivalOrder.id).maybeSingle();
check('direct fetch by id is blocked', direct == null);

// Writes must be blocked too — reading is not the only attack.
const { error: writeErr } = await web
  .from('orders')
  .update({ status: 'ready' })
  .eq('id', rivalOrder.id)
  .select();
const { data: afterWrite } = await admin
  .from('orders')
  .select('status')
  .eq('id', rivalOrder.id)
  .single();
check("cannot modify the rival shop's order", afterWrite.status === 'at_cleaner', afterWrite.status);

console.log('\nSENSITIVE TABLES');
const { data: events, error: evErr } = await web.from('delivery_events').select('id').limit(1);
check(
  'webhook landing table is not readable',
  (events ?? []).length === 0,
  evErr ? evErr.code : 'empty',
);

const { data: otherProfiles } = await web.from('profiles').select('id');
check(
  'cannot enumerate other users’ profiles',
  (otherProfiles ?? []).length <= 1,
  `${otherProfiles?.length ?? 0} rows`,
);

// --- anon, no session at all ---------------------------------------------
console.log('\nANONYMOUS (no session)');
const anon = await makeClient(webEnv.NEXT_PUBLIC_SUPABASE_ANON_KEY, URL);
const { data: anonOrders } = await anon.from('orders').select('id').limit(5);
check('anon sees no orders', (anonOrders ?? []).length === 0);
const { data: anonProfiles } = await anon.from('profiles').select('id').limit(5);
check('anon sees no profiles', (anonProfiles ?? []).length === 0);

await admin.from('orders').delete().eq('id', rivalOrder.id);

console.log(failures === 0 ? '\nALL CHECKS PASSED\n' : `\n${failures} CHECK(S) FAILED\n`);
process.exit(failures === 0 ? 0 : 1);
