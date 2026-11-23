/**
 * Shared by settings (address edits) and join (new shops): both must turn an
 * address into the coordinates couriers are quoted from, the same way.
 */

/**
 * The Census Bureau's geocoder: free, keyless, and US-only — which is fine,
 * because so are the couriers. One match or nothing; a guessed rooftop is a
 * courier at the wrong building.
 */
export async function geocode(
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
