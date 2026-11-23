#!/usr/bin/env node
/**
 * Shop sign-up by invite link, checked against the real database.
 *
 * Migration 0055 lets a stranger with a link create a (pending) shop, so the
 * claims worth proving are about who can do what with the anon key, not about
 * the queries the portal happens to send:
 *
 *   - a live code peeks and claims once; a used one answers nothing / P0002
 *   - the claim makes an INACTIVE shop, its owner row and its laundry price
 *   - the new owner reads their own pending shop but cannot switch it on
 *   - a customer cannot see the pending shop, list/mint invites or approve
 *   - nobody but service_role reads shop_invites or crease_admins directly
 *
 * It makes a throwaway user, invite and shop, and deletes all three at the
 * end whatever happened. Runs in the deploy journey suite.
 *
 *   CREASE_ALLOW_PROD=1 CREASE_TEST_PASSWORD=... node scripts/invite-check.mjs
 */
import { randomBytes } from 'node:crypto';
import { assertNotProduction, makeClient, readEnv } from './lib/client.mjs';

const TEST_PASSWORD = process.env.CREASE_TEST_PASSWORD;
if (!TEST_PASSWORD) {
  console.error('set CREASE_TEST_PASSWORD (see README) before running this');
  process.exit(1);
}
const svcEnv = readEnv('services/dispatch/.env');
const webEnv = readEnv('apps/portal/.env.local');
const URL = svcEnv.SUPABASE_URL;
const ANON = webEnv.NEXT_PUBLIC_SUPABASE_ANON_KEY;
assertNotProduction(svcEnv);

const admin = await makeClient(svcEnv.SUPABASE_SERVICE_ROLE_KEY, URL);
const CUSTOMER_EMAIL = 'testcustomer@crease.local';

let failures = 0;
const check = (label, ok, detail = '') => {
  if (!ok) failures++;
  console.log(`${ok ? '  PASS' : '  FAIL'}  ${label}${detail ? ` — ${detail}` : ''}`);
};
const denied = (error) => Boolean(error) && (error.code === '42501' || /permission denied|not allowed/i.test(error.message ?? ''));

const email = `invite-check-${randomBytes(4).toString('hex')}@crease.local`;
const password = randomBytes(18).toString('base64url');
let userId = null;
let inviteId = null;
let cleanerId = null;

try {
  const { data: created, error: userErr } = await admin.auth.admin.createUser({
    email,
    password,
    email_confirm: true,
  });
  if (userErr) throw new Error(`createUser: ${userErr.message}`);
  userId = created.user.id;

  const { data: invite, error: invErr } = await admin
    .from('shop_invites')
    .insert({ label: 'Invite Check Laundromat' })
    .select('id, code')
    .single();
  if (invErr) throw new Error(`insert invite: ${invErr.message}`);
  inviteId = invite.id;
  check('a new invite gets a 12-hex code', /^[A-F0-9]{12}$/.test(invite.code), invite.code);

  // --- before sign-in ------------------------------------------------------
  const anon = await makeClient(ANON, URL);
  const { data: peek } = await anon.rpc('peek_shop_invite', { p_code: invite.code.toLowerCase() });
  check('anyone with the code sees the shop name', peek?.[0]?.label === 'Invite Check Laundromat', JSON.stringify(peek));
  const { data: peekBad } = await anon.rpc('peek_shop_invite', { p_code: '000000000000' });
  check('an unknown code shows nothing', Array.isArray(peekBad) && peekBad.length === 0, JSON.stringify(peekBad));
  const { error: anonTable } = await anon.from('shop_invites').select('code').limit(1);
  check('anon cannot read shop_invites', denied(anonTable), anonTable?.message ?? 'read allowed');

  const claimArgs = {
    p_code: invite.code,
    p_name: 'Invite Check Laundromat',
    p_phone: '+17185550142',
    p_line1: '203 Bond St',
    p_city: 'Brooklyn',
    p_state: 'NY',
    p_postal_code: '11217',
    p_lat: 40.6852,
    p_lng: -73.9876,
    p_price_cents_per_lb: 125,
    p_minimum_lbs: 10,
    p_turnaround_hours: 24,
  };
  const { error: anonClaim } = await anon.rpc('claim_shop_invite', claimArgs);
  check('anon cannot claim', Boolean(anonClaim), anonClaim?.message ?? 'claim allowed without sign-in');

  // --- the shop owner ------------------------------------------------------
  const owner = await makeClient(ANON, URL);
  const { error: ownerAuth } = await owner.auth.signInWithPassword({ email, password });
  if (ownerAuth) throw new Error(`owner sign-in: ${ownerAuth.message}`);

  const { error: badClaim } = await owner.rpc('claim_shop_invite', { ...claimArgs, p_price_cents_per_lb: 5 });
  check('the database refuses a nonsense price', badClaim?.code === '22023', badClaim?.message ?? 'accepted');

  const { data: claimed, error: claimErr } = await owner.rpc('claim_shop_invite', claimArgs);
  check('the owner claims the invite', !claimErr && typeof claimed === 'string', claimErr?.message);
  cleanerId = claimed ?? null;

  const { data: shop } = await admin
    .from('cleaners')
    .select('active, approved_at, commission_bps, phone, email')
    .eq('id', cleanerId)
    .maybeSingle();
  check('the shop starts inactive and unapproved', shop?.active === false && shop?.approved_at === null, JSON.stringify(shop));
  check('the shop pays the card-fee floor (290 bps)', shop?.commission_bps === 290, JSON.stringify(shop));
  check('the shop email is the signed-in owner', shop?.email === email, shop?.email);

  const { data: staffRow } = await admin
    .from('cleaner_staff')
    .select('role')
    .eq('cleaner_id', cleanerId)
    .eq('user_id', userId)
    .maybeSingle();
  check('the owner is staff with role owner', staffRow?.role === 'owner', JSON.stringify(staffRow));

  const { data: price } = await admin
    .from('service_items')
    .select('service_type, unit, unit_price_cents, minimum_units, active')
    .eq('cleaner_id', cleanerId);
  check(
    'the shop has its wash & fold price',
    price?.length === 1 && price[0].unit === 'pound' && price[0].unit_price_cents === 125 && Number(price[0].minimum_units) === 10,
    JSON.stringify(price),
  );

  const { data: own } = await owner.from('cleaners').select('id, active').eq('id', cleanerId).maybeSingle();
  check('the owner reads their own pending shop', own?.id === cleanerId && own.active === false, JSON.stringify(own));

  const { error: selfApprove } = await owner.from('cleaners').update({ active: true }).eq('id', cleanerId).select('id');
  check('the owner cannot switch their shop on', denied(selfApprove), selfApprove?.message ?? 'update allowed');
  const { error: ownerApprove } = await owner.rpc('approve_shop', { p_cleaner: cleanerId });
  check('the owner cannot call approve_shop', denied(ownerApprove), ownerApprove?.message ?? 'approved');

  const { data: again, error: againErr } = await owner.rpc('claim_shop_invite', claimArgs);
  check('a used invite cannot be claimed again', againErr?.code === 'P0002', againErr?.message ?? `claimed ${again}`);
  const { data: peekUsed } = await anon.rpc('peek_shop_invite', { p_code: invite.code });
  check('a used invite shows nothing', Array.isArray(peekUsed) && peekUsed.length === 0, JSON.stringify(peekUsed));

  // --- a customer ----------------------------------------------------------
  const customer = await makeClient(ANON, URL);
  const { error: custAuth } = await customer.auth.signInWithPassword({ email: CUSTOMER_EMAIL, password: TEST_PASSWORD });
  if (custAuth) throw new Error(`customer sign-in: ${custAuth.message}`);
  const { data: seen } = await customer.from('cleaners').select('id').eq('id', cleanerId);
  check('a customer cannot see the pending shop', Array.isArray(seen) && seen.length === 0, JSON.stringify(seen));
  const { error: custList } = await customer.rpc('list_shop_invites');
  check('a customer cannot list invites', denied(custList), custList?.message ?? 'listed');
  const { error: custMint } = await customer.rpc('create_shop_invite', { p_label: 'x' });
  check('a customer cannot mint invites', denied(custMint), custMint?.message ?? 'minted');
  const { error: custApprove } = await customer.rpc('approve_shop', { p_cleaner: cleanerId });
  check('a customer cannot approve', denied(custApprove), custApprove?.message ?? 'approved');
  const { error: custAdmins } = await customer.from('crease_admins').select('user_id').limit(1);
  check('a customer cannot read crease_admins', denied(custAdmins), custAdmins?.message ?? 'read allowed');
} catch (err) {
  failures++;
  console.log(`  FAIL  ${err.message}`);
} finally {
  // Shop first (cascades staff + price), then the invite, then the user.
  if (cleanerId) await admin.from('cleaners').delete().eq('id', cleanerId);
  if (inviteId) await admin.from('shop_invites').delete().eq('id', inviteId);
  if (userId) {
    const { error } = await admin.auth.admin.deleteUser(userId);
    if (error) {
      failures++;
      console.log(`  FAIL  cleanup: could not delete ${email}: ${error.message}`);
    }
  }
}

console.log(failures === 0 ? '\ninvite-check: all passed' : `\ninvite-check: ${failures} failed`);
process.exit(failures === 0 ? 0 : 1);
