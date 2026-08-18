/**
 * Turning what somebody typed into a point on Brooklyn.
 *
 * OpenStreetMap's Nominatim rather than Google Places: this runs on every
 * address anyone tries, including the ones that never become orders, and
 * Places bills $0.032 a call for exactly that kind of traffic. Nominatim is
 * free and asks for politeness in return — one request at a time, a real
 * User-Agent, and a cache so a street typed twice is fetched once.
 */
const ENDPOINT = 'https://nominatim.openstreetmap.org/search';
const CONTACT = 'Crease (usecreaseapp.com)';

export interface Geocoded {
  lat: number;
  lng: number;
  label: string;
  neighborhood: string | null;
}

/** Normalised so "251 Dekalb Ave" and "251 dekalb ave " share a cache slot. */
function key(query: string): string {
  return query.trim().toLowerCase().replace(/\s+/g, ' ');
}

const cache = new Map<string, Geocoded | null>();
/** Nominatim's usage policy is one request per second, so requests queue. */
let chain: Promise<unknown> = Promise.resolve();

export async function geocodeBrooklyn(query: string): Promise<Geocoded | null> {
  const cacheKey = key(query);
  if (cache.has(cacheKey)) return cache.get(cacheKey) ?? null;

  const run = chain.then(async () => {
    // Scoped to the borough rather than sent raw: "Fulton Street" alone
    // resolves to Manhattan, and a customer typing their own street should not
    // be told they live in the wrong borough.
    const url = new URL(ENDPOINT);
    url.searchParams.set('q', `${query}, Brooklyn, NY`);
    url.searchParams.set('format', 'jsonv2');
    url.searchParams.set('addressdetails', '1');
    url.searchParams.set('limit', '1');
    url.searchParams.set('countrycodes', 'us');

    try {
      const res = await fetch(url, {
        headers: { 'User-Agent': CONTACT, 'Accept-Language': 'en' },
        signal: AbortSignal.timeout(6000),
      });
      if (!res.ok) return null;
      const [hit] = (await res.json()) as any[];
      if (!hit) return null;
      const lat = Number(hit.lat);
      const lng = Number(hit.lon);
      if (!Number.isFinite(lat) || !Number.isFinite(lng)) return null;
      const a = hit.address ?? {};
      return {
        lat,
        lng,
        label: hit.display_name ?? query,
        neighborhood: a.neighbourhood ?? a.suburb ?? a.city_district ?? null,
      } satisfies Geocoded;
    } catch {
      // A geocoder that is down must not look like an address that does not
      // exist. The caller says "we could not check that" and keeps the ping.
      return null;
    } finally {
      // One in flight at a time, plus a beat, whatever happened above.
      await new Promise((r) => setTimeout(r, 1100));
    }
  });

  chain = run.catch(() => undefined);
  const result = (await run) as Geocoded | null;
  // Bounded: this process is long-lived and a cache that only grows is a leak
  // with a nice name.
  if (cache.size > 5000) cache.clear();
  cache.set(cacheKey, result);
  return result;
}
