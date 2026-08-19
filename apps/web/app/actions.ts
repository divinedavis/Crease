'use server';

import { cookies, headers } from 'next/headers';
import { nearestShop, SERVICE_RADIUS_MILES, type Shop } from '@/lib/coverage';
import { geocodeBrooklyn } from '@/lib/geocode';
import { serviceClient } from '@/lib/supabase';

export interface CheckResult {
  status: 'covered' | 'outside' | 'unknown' | 'error';
  message: string;
  shopName?: string;
  miles?: number;
  neighborhood?: string | null;
  /** Echoed back so the follow-up email lands on the same row. */
  pingId?: string;
}

/**
 * "Do you reach me?" — and the record of having been asked.
 *
 * The recording is not a side effect of this feature, it is the feature. Every
 * order Crease has ever taken came from the two neighbourhoods where a partner
 * already exists, which makes the order table a map of where shops were signed
 * rather than where anybody wants this. The addresses that come back "not yet"
 * are the ones worth knowing, and they are only ever seen here.
 */
/**
 * Is this the owner's own browser?
 *
 * /?owner=1 leaves this cookie so the nginx traffic count can skip the person
 * building the site. The rows the site writes need the same mark: six address
 * checks and "67% inside the courier band" were, on the day this was added,
 * one man testing his own product from a laptop and then a phone. A dashboard
 * that reports that as demand is worse than one that reports nothing.
 */
async function ownerDevice(): Promise<boolean> {
  try {
    return (await cookies()).get('crease_owner')?.value === '1';
  } catch {
    // Server actions always have a cookie store; if that ever changes, the
    // honest default is to count the row rather than silently drop it.
    return false;
  }
}

/** The point attached to a chosen suggestion, if there is one and it is real. */
function pickedPoint(formData: FormData): { lat: number; lng: number; label: string; neighborhood: string | null } | null {
  const lat = Number(formData.get('lat'));
  const lng = Number(formData.get('lng'));
  if (!Number.isFinite(lat) || !Number.isFinite(lng) || (lat === 0 && lng === 0)) return null;
  // Bounded to the city, because these arrive in a form post: a point in the
  // Atlantic would otherwise be quoted against whichever shop is least far.
  if (lat < 40.4 || lat > 41.0 || lng < -74.3 || lng > -73.6) return null;
  return { lat, lng, label: String(formData.get('address') ?? ''), neighborhood: null };
}

export async function checkCoverage(_prev: unknown, formData: FormData): Promise<CheckResult> {
  const query = String(formData.get('address') ?? '').trim();
  const sessionRef = String(formData.get('session') ?? '').slice(0, 64) || null;

  if (query.length < 3) {
    return { status: 'error', message: 'Enter a street address so we can check.' };
  }
  if (query.length > 300) {
    return { status: 'error', message: "That's longer than an address — try just the street." };
  }

  const db = serviceClient();

  // A suggestion the customer chose already carries its coordinates from the
  // city's own address file — more accurate than anything a free-text geocode
  // would return, and one less request to make them wait for.
  const picked = pickedPoint(formData);
  const geo = picked ?? (await geocodeBrooklyn(query));

  // Shops are read fresh: signing one is exactly the event that changes this
  // answer, and a cached list would keep telling a whole neighbourhood no for
  // as long as the process lived.
  let shops: Shop[] = [];
  if (db) {
    const { data } = await db
      .from('cleaners')
      .select('id, name, lat, lng')
      .eq('active', true);
    shops = (data ?? []) as Shop[];
  }

  const cover = geo ? nearestShop(geo, shops) : { covered: false, shop: null, miles: null };

  let pingId: string | undefined;
  if (db) {
    const { data } = await db
      .from('demand_pings')
      .insert({
        query,
        lat: geo?.lat ?? null,
        lng: geo?.lng ?? null,
        neighborhood: geo?.neighborhood ?? null,
        in_service_area: cover.covered,
        nearest_cleaner_id: cover.shop?.id ?? null,
        nearest_miles: cover.miles,
        session_ref: sessionRef,
        source: 'web',
        owner: await ownerDevice(),
      })
      .select('id')
      .single();
    pingId = data?.id;
  }

  if (!geo) {
    return {
      status: 'unknown',
      message:
        "We couldn't find that address in Brooklyn. Try the street number and street name — or leave your email and we'll come back to you.",
      pingId,
    };
  }

  if (cover.covered && cover.shop) {
    return {
      status: 'covered',
      message: `Yes — ${cover.shop.name} is ${cover.miles} miles away and takes pickups from your block.`,
      shopName: cover.shop.name,
      miles: cover.miles ?? undefined,
      neighborhood: geo.neighborhood,
      pingId,
    };
  }

  return {
    status: 'outside',
    message: cover.miles
      ? `Not yet. We collect within ${SERVICE_RADIUS_MILES} miles of ${cover.shop?.name ?? 'our partner'} on Fulton Street, and you are ${cover.miles} miles out — past that band a courier costs more than the fee collects. Leave your email and we will tell you when we reach your street.`
      : `Not yet — we have no partner near you.`,
    miles: cover.miles ?? undefined,
    neighborhood: geo.neighborhood,
    pingId,
  };
}

/** Attach an email to an address we already recorded. */
export async function joinWaitlist(_prev: unknown, formData: FormData) {
  const email = String(formData.get('email') ?? '').trim().toLowerCase();
  const pingId = String(formData.get('pingId') ?? '');

  // Deliberately loose. The point is to reach somebody when their street opens,
  // not to enforce RFC 5322 at the door — and a rejected address that would
  // have worked is a customer lost to a regex.
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(email) || email.length > 320) {
    return { ok: false, message: 'That email looks off — check it and try again.' };
  }

  const db = serviceClient();
  if (!db) return { ok: false, message: 'Something went wrong. Try again in a moment.' };

  if (pingId) {
    await db.from('demand_pings').update({ email }).eq('id', pingId);
  } else {
    // No address checked first — still worth keeping, still a person in
    // Brooklyn who wants this.
    await db
      .from('demand_pings')
      .insert({ query: '(email only)', email, source: 'web', owner: await ownerDevice() });
  }

  return { ok: true, message: "You're on the list. We'll email you the day we reach your street." };
}

export interface RequestResult {
  ok: boolean;
  message: string;
}

/**
 * A pickup, requested from a browser.
 *
 * Nothing is charged and no account is made: the point is to find out whether
 * people in Brooklyn want this badly enough to hand over a phone number, and a
 * card form in front of that question answers a different one.
 *
 * The address is geocoded so the request lands with the coverage answer already
 * attached — a request from outside the courier band is still worth having, and
 * it is worth knowing that is what it is before somebody calls them back.
 */
export async function requestPickup(_prev: unknown, formData: FormData): Promise<RequestResult> {
  const field = (name: string, max: number) => String(formData.get(name) ?? '').trim().slice(0, max);

  const name = field('name', 120);
  const phone = field('phone', 32);
  const address = field('address', 300);
  const email = field('email', 320).toLowerCase();

  if (name.length < 1) return { ok: false, message: 'Tell us your name so we know who to text.' };
  // Loose on purpose: US mobiles arrive as (718) 555-0142, +1 718 555 0142 and
  // 7185550142, and rejecting a real number over punctuation loses the order.
  if (phone.replace(/\D/g, '').length < 7) {
    return { ok: false, message: 'That phone number looks short — we confirm pickups by text.' };
  }
  if (address.length < 3) return { ok: false, message: 'We need a street address to collect from.' };
  if (email && !/^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(email)) {
    return { ok: false, message: 'That email looks off — leave it blank if you would rather not.' };
  }

  const db = serviceClient();
  if (!db) return { ok: false, message: 'Something went wrong on our side. Try again in a moment.' };

  const geo = pickedPoint(formData) ?? (await geocodeBrooklyn(address));

  let cleanerId = field('cleaner_id', 64) || null;
  let covered = false;
  if (geo) {
    const { data } = await db.from('cleaners').select('id, name, lat, lng').eq('active', true);
    const cover = nearestShop(geo, (data ?? []) as Shop[]);
    covered = cover.covered;
    // Only fill in a shop nobody chose. A stated preference outranks proximity.
    if (!cleanerId) cleanerId = cover.shop?.id ?? null;
  }

  const { error } = await db.from('pickup_requests').insert({
    name,
    phone,
    email: email || null,
    address,
    address_notes: field('address_notes', 500) || null,
    lat: geo?.lat ?? null,
    lng: geo?.lng ?? null,
    service_type: field('service_type', 20) || 'dry_clean',
    service_tier: field('service_tier', 20) || 'round_trip',
    items_note: field('items_note', 1000) || null,
    preferred_when: field('preferred_when', 200) || null,
    cleaner_id: cleanerId,
    owner: await ownerDevice(),
  });

  if (error) {
    console.error('[web] pickup request insert failed', error);
    return { ok: false, message: 'We could not save that. Try again, or text us and we will sort it.' };
  }

  // The request is kept either way. Somebody outside the band who still wants a
  // pickup is the strongest possible argument for signing a shop near them,
  // and they are told the truth rather than promised a courier.
  return {
    ok: true,
    message: covered
      ? "We'll text you to confirm the pickup window and the price before anything is charged."
      : "You're just outside our current courier range, so we'll text you about the nearest option — and you're now first in line when we sign a cleaner near you.",
  };
}

export interface Quote {
  status: 'covered' | 'outside' | 'unknown' | 'error';
  message: string;
  shopName?: string;
  shopLine1?: string | null;
  miles?: number;
  address?: string;
  pingId?: string;
}

/**
 * What a pickup from this address costs, on every tier.
 *
 * The same recording as the coverage check, because it is the same act: a
 * person typing their street is expressing demand at a location whether or not
 * they go on to book. Prices are only shown for an address we can actually
 * serve — quoting $29.95 to somebody four miles from the nearest partner is a
 * number we would have to take back.
 */
export async function quoteAddress(_prev: unknown, formData: FormData): Promise<Quote> {
  const result = await checkCoverage(_prev, formData);
  const address = String(formData.get('address') ?? '').trim();

  return {
    status: result.status,
    message: result.message,
    shopName: result.shopName,
    miles: result.miles,
    address,
    pingId: result.pingId,
  };
}
