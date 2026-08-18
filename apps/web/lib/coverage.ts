/**
 * Whether Crease reaches an address, and how far it is from the shop that
 * would take it.
 *
 * The radius is the courier band the whole business is priced against: Uber
 * Direct is essentially flat under three miles in Brooklyn and steps up past
 * it, so a fourth mile is not a slightly worse order, it is one the published
 * fee stops covering. See services/dispatch/src/pricing.ts.
 */
export const SERVICE_RADIUS_MILES = 3;

export interface Point {
  lat: number;
  lng: number;
}

/** Great-circle miles. Good to a few feet at city distances. */
export function milesBetween(a: Point, b: Point): number {
  const R = 3958.8;
  const p1 = (a.lat * Math.PI) / 180;
  const p2 = (b.lat * Math.PI) / 180;
  const dp = p2 - p1;
  const dl = ((b.lng - a.lng) * Math.PI) / 180;
  const h = Math.sin(dp / 2) ** 2 + Math.cos(p1) * Math.cos(p2) * Math.sin(dl / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(h));
}

export interface Shop extends Point {
  id: string;
  name: string;
}

export interface Coverage {
  covered: boolean;
  shop: Shop | null;
  miles: number | null;
}

/**
 * The nearest partner, and whether it is close enough to serve.
 *
 * Nearest rather than any-within-range because the answer is shown to a
 * person: "Fulton Cleaners, 0.4 miles away" is worth reading, and "yes" is
 * not.
 */
export function nearestShop(point: Point, shops: readonly Shop[]): Coverage {
  let best: Shop | null = null;
  let bestMiles = Number.POSITIVE_INFINITY;

  for (const shop of shops) {
    const miles = milesBetween(point, shop);
    if (miles < bestMiles) {
      bestMiles = miles;
      best = shop;
    }
  }

  if (!best) return { covered: false, shop: null, miles: null };
  return {
    covered: bestMiles <= SERVICE_RADIUS_MILES,
    shop: best,
    miles: Math.round(bestMiles * 100) / 100,
  };
}
