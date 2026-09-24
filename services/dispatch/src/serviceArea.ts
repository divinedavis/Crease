/**
 * How far from its shop an order may be picked up.
 *
 * Three miles, measured from the cleaner the order is going to. It is the
 * courier band the prices are built on — Uber Direct is essentially flat under
 * three miles in Brooklyn and steps up past it — and the owner's rule is that
 * nothing outside it is booked. The website's address checker
 * (apps/web/lib/coverage.ts) and the app's copy (ServiceArea.swift) say the
 * same number; this is the one that actually stops a booking.
 *
 * `cleaners.service_radius_miles` exists and defaults to 5. It is not read
 * here on purpose: a shop row added with the default would quietly widen the
 * area past what the business can price.
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

/**
 * Whether a pickup at `door` can go to `shop`. A point with no coordinates is
 * outside: a distance nobody can measure is not one anybody can price.
 */
export function withinServiceArea(
  door: Partial<Point> | null | undefined,
  shop: Partial<Point> | null | undefined,
): boolean {
  if (door?.lat == null || door?.lng == null || shop?.lat == null || shop?.lng == null) return false;
  return milesBetween(door as Point, shop as Point) <= SERVICE_RADIUS_MILES;
}
