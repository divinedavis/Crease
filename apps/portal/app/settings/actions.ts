'use server';

import { revalidatePath } from 'next/cache';
import { redirect } from 'next/navigation';
import { headers } from 'next/headers';
import { supabaseServer } from '@/lib/supabase';
import { callDispatch } from '@/lib/dispatch';
import { parseHoursForm } from '@/lib/hours';

/**
 * Every write here rides the staff member's own session, so RLS decides which
 * shop they can touch. The one trap: Postgrest reports an RLS miss as zero
 * rows updated, not as an error — this codebase has already shipped a write
 * that "succeeded" against nothing — so every update selects back what it
 * wrote and treats an empty answer as the refusal it is.
 */

const NOT_YOURS = 'This shop is not linked to your account.';

/**
 * The portal's own public origin, for Stripe to send the shop back to.
 *
 * Derived from a server-set env var, NOT request headers: x-forwarded-host is
 * attacker-controllable unless every proxy in front strips it, and this value
 * becomes a Stripe redirect target — a spoofed host would land the shop on an
 * attacker page after onboarding. Falls back to the request host only when the
 * env var is unset (local dev).
 */
async function portalOrigin(): Promise<string> {
  const fromEnv = process.env.PORTAL_PUBLIC_URL;
  if (fromEnv) return fromEnv.replace(/\/+$/, '');
  const h = await headers();
  const host = h.get('host') ?? 'localhost:3000';
  const proto = h.get('x-forwarded-proto') ?? 'http';
  return `${proto}://${host}`;
}

export async function saveShopDetails(cleanerId: string, _prev: unknown, formData: FormData) {
  const db = await supabaseServer();

  const { data: current } = await db
    .from('cleaners')
    .select('line1, line2, city, state, postal_code, lat, lng')
    .eq('id', cleanerId)
    .maybeSingle();
  if (!current) return { error: NOT_YOURS };

  const field = (name: string) => String(formData.get(name) ?? '').trim();
  const updates: Record<string, unknown> = {
    phone: field('phone') || null,
    email: field('email') || null,
    line1: field('line1'),
    line2: field('line2') || null,
    city: field('city'),
    state: field('state').toUpperCase(),
    postal_code: field('postal_code'),
  };

  if (!updates.line1 || !updates.city || !updates.state || !updates.postal_code) {
    return { error: 'Street, city, state and ZIP are all required.' };
  }

  const turnaround = Number(field('turnaround_hours'));
  if (!Number.isInteger(turnaround) || turnaround < 1 || turnaround > 24 * 14) {
    return { error: 'Standard turnaround must be a whole number of hours (1–336).' };
  }
  updates.turnaround_hours = turnaround;

  // Couriers are quoted from lat/lng, not from the text. An address edit that
  // kept the old coordinates would keep sending drivers to the old storefront,
  // so the two move together or not at all.
  const moved =
    updates.line1 !== current.line1 ||
    (updates.line2 ?? null) !== (current.line2 ?? null) ||
    updates.city !== current.city ||
    updates.state !== current.state ||
    updates.postal_code !== current.postal_code;

  if (moved) {
    const coords = await geocode(
      `${updates.line1}, ${updates.city}, ${updates.state} ${updates.postal_code}`,
    );
    if (coords === 'unreachable') {
      return { error: 'Could not verify the address right now — nothing was changed. Try again in a minute.' };
    }
    if (coords === 'nomatch') {
      return {
        error:
          "That address didn't match a real street address. Check the street number and ZIP — couriers are routed to exactly what you enter here.",
      };
    }
    updates.lat = coords.lat;
    updates.lng = coords.lng;
  }

  const { data: saved, error } = await db
    .from('cleaners')
    .update(updates)
    .eq('id', cleanerId)
    .select('id');
  if (error) return { error: error.message };
  if (!saved?.length) return { error: NOT_YOURS };

  revalidatePath('/settings');
  return { ok: true, relocated: moved };
}

export async function saveHours(cleanerId: string, _prev: unknown, formData: FormData) {
  const parsed = parseHoursForm((name) => formData.get(name));
  if ('error' in parsed) return { error: parsed.error };
  if (parsed.hours.length === 0) {
    // All seven days closed is a shop nobody can ever be dispatched to. If
    // they're really closing, that's the `active` flag and a conversation
    // with us — not a quiet way to disappear from routing.
    return { error: 'At least one day must be open. Contact Crease if the shop is closing.' };
  }

  const db = await supabaseServer();
  const { data: saved, error } = await db
    .from('cleaners')
    .update({ hours: parsed.hours })
    .eq('id', cleanerId)
    .select('id');
  if (error) return { error: error.message };
  if (!saved?.length) return { error: NOT_YOURS };

  revalidatePath('/settings');
  return { ok: true };
}

/**
 * Send the shop into Stripe's hosted onboarding. The dispatcher creates the
 * Connect account if it doesn't exist and answers with a one-time URL; the
 * redirect leaves the portal, and Stripe returns them to /settings when done.
 */
export async function startPayoutOnboarding(cleanerId: string) {
  const db = await supabaseServer();

  // Payouts are an owner/manager operation, not a day-to-day one: gate on the
  // staff role, not mere membership. (The dispatch call rides the internal key,
  // which does not check the shop, so this is the only gate.)
  const { data: isAdmin } = await db.rpc('is_cleaner_admin', { p_cleaner: cleanerId });
  if (!isAdmin) return { error: 'Only an owner or manager can manage payouts.' };

  const origin = await portalOrigin();
  let url: string;
  try {
    const res = await callDispatch(`/v1/cleaners/${cleanerId}/connect-onboarding`, {
      returnUrl: `${origin}/settings?payouts=done`,
      refreshUrl: `${origin}/settings?payouts=expired`,
    });
    url = res.url;
  } catch (err) {
    return { error: (err as Error).message };
  }
  if (!url) return { error: 'Stripe did not return an onboarding link. Try again.' };
  redirect(url);
}

/** Re-ask Stripe whether payouts are enabled yet, and cache the answer. */
export async function refreshPayoutStatus(cleanerId: string) {
  const db = await supabaseServer();
  const { data: isAdmin } = await db.rpc('is_cleaner_admin', { p_cleaner: cleanerId });
  if (!isAdmin) return { error: 'Only an owner or manager can manage payouts.' };

  try {
    await callDispatch(`/v1/cleaners/${cleanerId}/connect-refresh`);
  } catch (err) {
    return { error: (err as Error).message };
  }
  revalidatePath('/settings');
  return { ok: true };
}

/**
 * The Census Bureau's geocoder: free, keyless, and US-only — which is fine,
 * because so are the couriers. One match or nothing; a guessed rooftop is a
 * courier at the wrong building.
 */
async function geocode(
  oneline: string,
): Promise<{ lat: number; lng: number } | 'nomatch' | 'unreachable'> {
  const url =
    'https://geocoding.geo.census.gov/geocoder/locations/onelineaddress' +
    `?address=${encodeURIComponent(oneline)}&benchmark=Public_AR_Current&format=json`;
  try {
    const res = await fetch(url, { cache: 'no-store', signal: AbortSignal.timeout(10_000) });
    if (!res.ok) return 'unreachable';
    const json = await res.json();
    const match = json?.result?.addressMatches?.[0];
    if (!match?.coordinates) return 'nomatch';
    return { lat: Number(match.coordinates.y), lng: Number(match.coordinates.x) };
  } catch {
    return 'unreachable';
  }
}
