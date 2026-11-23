/**
 * Shop sign-up by invite link: the pure parts, so they can be tested without
 * a browser or a database.
 *
 * The database re-checks every one of these rules in claim_shop_invite()
 * (migration 0055). This copy exists to give the person at the counter a
 * sentence they can act on before anything is written.
 */

/** Cookie that carries the invite code across the Google round trip. */
export const JOIN_COOKIE = 'crease_join';

/** Invite codes are 12 upper-case hex characters (see shop_invites.code). */
export function isInviteCode(value: unknown): value is string {
  return typeof value === 'string' && /^[A-F0-9]{12}$/.test(value);
}

/** A code as typed or linked: trimmed and upper-cased, or null if it is not one. */
export function normalizeInviteCode(value: unknown): string | null {
  if (typeof value !== 'string') return null;
  const code = value.trim().toUpperCase();
  return isInviteCode(code) ? code : null;
}

/**
 * Where the OAuth callback should send somebody who started from a join link.
 * Only ever a /join/<code> path built here, never a URL taken from the request,
 * so the cookie cannot be turned into an open redirect.
 */
export function joinPathFromCookie(value: string | undefined | null): string | null {
  const code = normalizeInviteCode(value ?? '');
  return code ? `/join/${code}` : null;
}

/** US numbers only, as +1XXXXXXXXXX. Couriers call this number. */
export function normalizeUsPhone(raw: string): string | null {
  const digits = raw.replace(/\D/g, '');
  const ten = digits.length === 11 && digits.startsWith('1') ? digits.slice(1) : digits;
  if (ten.length !== 10 || /^[01]/.test(ten)) return null;
  return `+1${ten}`;
}

export type JoinForm = {
  name: string;
  phone: string;
  line1: string;
  city: string;
  state: string;
  postal_code: string;
  price_cents_per_lb: number;
  minimum_lbs: number;
  turnaround_hours: number;
};

/** Parse the join form, or say in shop language what to fix. */
export function parseJoinForm(get: (name: string) => unknown): { form: JoinForm } | { error: string } {
  const text = (name: string) => String(get(name) ?? '').trim();

  const name = text('name');
  if (!name || name.length > 120) return { error: 'Enter the shop’s name.' };

  const phone = normalizeUsPhone(text('phone'));
  if (!phone) return { error: 'Enter the shop’s phone number (10 digits). Couriers call it at pickup.' };

  const line1 = text('line1');
  const city = text('city');
  const state = text('state').toUpperCase();
  const postal_code = text('postal_code');
  if (!line1 || line1.length > 200 || !city || city.length > 80) {
    return { error: 'Enter the shop’s street address and city.' };
  }
  if (!/^[A-Z]{2}$/.test(state)) return { error: 'State is two letters, like NY.' };
  if (!/^[0-9]{5}$/.test(postal_code)) return { error: 'ZIP is five digits.' };

  const priceText = text('price_per_lb').replace(/^\$/, '');
  const price = Number(priceText);
  if (!priceText || !Number.isFinite(price) || price < 0.5 || price > 20) {
    return { error: 'Price per pound should be between $0.50 and $20.' };
  }
  const price_cents_per_lb = Math.round(price * 100);

  const minText = text('minimum_lbs') || '0';
  const minimum_lbs = Number(minText);
  if (!Number.isFinite(minimum_lbs) || minimum_lbs < 0 || minimum_lbs > 50) {
    return { error: 'Minimum pounds should be between 0 and 50.' };
  }

  const turnaround_hours = Number(text('turnaround_hours') || '24');
  if (!Number.isInteger(turnaround_hours) || turnaround_hours < 1 || turnaround_hours > 336) {
    return { error: 'Ready time should be a whole number of hours (1–336).' };
  }

  return {
    form: { name, phone, line1, city, state, postal_code, price_cents_per_lb, minimum_lbs, turnaround_hours },
  };
}

/**
 * Split the canvass list's one-line address ("203 Bond St, Brooklyn") into the
 * form's street and city, so the shop starts from what we already know.
 */
export function splitProspectAddress(address: string | null | undefined): { line1: string; city: string } {
  const parts = String(address ?? '').split(',').map((p) => p.trim()).filter(Boolean);
  if (parts.length === 0) return { line1: '', city: 'Brooklyn' };
  return { line1: parts[0], city: parts[1] ?? 'Brooklyn' };
}
