'use server';

import { redirect } from 'next/navigation';
import { supabaseServer } from '@/lib/supabase';
import { geocode } from '@/lib/geocode';
import { normalizeInviteCode, parseJoinForm } from '@/lib/join';

/**
 * Spend an invite: the shop, its owner login and its laundry price, all in
 * claim_shop_invite() (migration 0055) so nothing half-exists.
 *
 * Runs on the signed-in shop owner's own session (anon key), never the
 * service role: the function reads auth.uid() to decide who becomes the
 * owner, so nobody can claim a shop on someone else's behalf. The shop it
 * creates is inactive; the founder switches it on from the canvass page.
 */
export async function claimShop(rawCode: string, _prev: unknown, formData: FormData) {
  const code = normalizeInviteCode(rawCode);
  if (!code) return { error: 'This sign-up link isn’t valid. Ask Crease for a new one.' };

  const db = await supabaseServer();
  const {
    data: { user },
  } = await db.auth.getUser();
  if (!user) return { error: 'Sign in with Google first.' };

  const parsed = parseJoinForm((name) => formData.get(name));
  if ('error' in parsed) return { error: parsed.error };
  const f = parsed.form;

  const coords = await geocode(`${f.line1}, ${f.city}, ${f.state} ${f.postal_code}`);
  if (coords === 'unreachable') {
    return { error: 'Couldn’t check the address right now. Try again in a minute.' };
  }
  if (coords === 'nomatch') {
    return {
      error: 'That address didn’t match a real street address. Check the street number and ZIP — couriers go exactly where this says.',
    };
  }

  const { error } = await db.rpc('claim_shop_invite', {
    p_code: code,
    p_name: f.name,
    p_phone: f.phone,
    p_line1: f.line1,
    p_city: f.city,
    p_state: f.state,
    p_postal_code: f.postal_code,
    p_lat: coords.lat,
    p_lng: coords.lng,
    p_price_cents_per_lb: f.price_cents_per_lb,
    p_minimum_lbs: f.minimum_lbs,
    p_turnaround_hours: f.turnaround_hours,
  });
  if (error) {
    console.error('[portal] claimShop failed', { code, user: user.id }, error);
    if (error.code === 'P0002') {
      return { error: 'This link has expired or was already used. Ask Crease for a new one.' };
    }
    return { error: 'Couldn’t finish signing up. Try again.' };
  }

  redirect('/settings?welcome=1');
}
