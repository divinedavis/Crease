#!/usr/bin/env node
/**
 * Nothing more than three miles from its shop is booked.
 *
 * The rule is enforced at the customer payment-intent route — the one door to
 * a card hold — so this books a draft to a Manhattan address and checks that
 * door stays shut, then books one nearby and checks it opens. Both drafts and
 * the far address are removed afterwards; no card is ever confirmed.
 *
 *   CREASE_TEST_PASSWORD=... node scripts/e2e-service-area.mjs
 */
import { adminClient, readEnv } from './lib/client.mjs';

const TEST_PASSWORD = process.env.CREASE_TEST_PASSWORD;
if (!TEST_PASSWORD) {
  console.error('set CREASE_TEST_PASSWORD before running this');
  process.exit(1);
}

const { env, db } = await adminClient();
const anon = readEnv('apps/ios/Secrets.xcconfig');
const BASE = process.env.CREASE_BASE ?? env.PUBLIC_URL ?? 'http://localhost:8080';

let failures = 0;
function check(label, actual, expected) {
  const ok = actual === expected;
  if (!ok) failures++;
  console.log(`${ok ? '  PASS' : '  FAIL'}  ${label}: ${actual}${ok ? '' : ` (expected ${expected})`}`);
}

const auth = await fetch(`${env.SUPABASE_URL}/auth/v1/token?grant_type=password`, {
  method: 'POST',
  headers: { apikey: anon.SUPABASE_ANON_KEY, 'content-type': 'application/json' },
  body: JSON.stringify({ email: 'testcustomer@crease.local', password: TEST_PASSWORD }),
});
if (!auth.ok) {
  console.error(`sign-in failed: ${auth.status} ${await auth.text()}`);
  process.exit(1);
}
const { access_token: token, user } = await auth.json();

const { data: cleaner } = await db
  .from('cleaners').select('id, lat, lng').eq('slug', 'bedford-cleaners').single();
const { data: near } = await db
  .from('addresses').select('id').eq('user_id', user.id).not('lat', 'is', null).limit(1).single();
// Coney Island — about nine miles from the seeded shop, well outside.
const { data: far } = await db.from('addresses').insert({
  user_id: user.id, label: 'e2e far', line1: '1208 Surf Ave', city: 'Brooklyn',
  state: 'NY', postal_code: '11224', lat: 40.5755, lng: -73.9707,
}).select('id').single();

const drafts = [];
async function draftTo(addressId) {
  const now = new Date();
  const { data: order } = await db.from('orders').insert({
    customer_id: user.id, cleaner_id: cleaner.id, address_id: addressId, status: 'draft',
    estimate_subtotal_cents: 0, delivery_fee_cents: 1695, service_tier: 'pickup_only',
    pickup_window_start: now.toISOString(),
    pickup_window_end: new Date(now.getTime() + 2 * 3600_000).toISOString(),
  }).select('id').single();
  drafts.push(order.id);
  const res = await fetch(`${BASE}/v1/me/orders/${order.id}/payment-intent`, {
    method: 'POST',
    headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
    body: '{}',
  });
  return { status: res.status, json: await res.json().catch(() => ({})) };
}

try {
  console.log('\nFAR   Coney Island, ~9 mi out');
  const refused = await draftTo(far.id);
  check('payment refused', refused.status, 422);
  check('says why', refused.json.code, 'out_of_area');
  const { count: farPayments } = await db
    .from('payments').select('*', { count: 'exact', head: true }).eq('order_id', drafts[0]);
  check('no hold created', farPayments, 0);

  console.log('\nNEAR  the seeded address');
  const allowed = await draftTo(near.id);
  check('payment starts', allowed.status, 200);
  check('client secret returned', Boolean(allowed.json.clientSecret), true);
} finally {
  // An armed-but-unpaid intent holds nothing and expires on its own; deleting
  // the drafts is enough, and the far address goes with them.
  for (const id of drafts) {
    await db.from('payments').delete().eq('order_id', id);
    await db.from('orders').delete().eq('id', id);
  }
  await db.from('addresses').delete().eq('id', far.id);
}

console.log(`\n${failures === 0 ? 'ALL CHECKS PASSED' : `${failures} FAILURE(S)`}\n`);
process.exit(failures === 0 ? 0 : 1);
