import { NextResponse } from 'next/server';

/**
 * Address suggestions while somebody types.
 *
 * NYC Planning's Geosearch, not Nominatim and not Google. Nominatim's usage
 * policy forbids type-ahead outright — it is the one use they name — and
 * Google Places bills per keystroke-session for a question this city already
 * answers for free. Geosearch is Pelias over the city's own address file: no
 * key, no bill, and it only knows New York, which for a Brooklyn courier
 * service is a feature rather than a limit.
 *
 * Proxied rather than called from the browser so the rate limit, the cache and
 * the borough filter are ours, and so a change of provider never means
 * shipping new JavaScript to everybody.
 */
const GEOSEARCH = 'https://geosearch.planninglabs.nyc/v2/autocomplete';
const MIN_CHARS = 3;
const MAX_SUGGESTIONS = 6;
const CACHE_TTL_MS = 10 * 60_000;

interface Suggestion {
  label: string;
  street: string;
  borough: string | null;
  lat: number;
  lng: number;
}

const cache = new Map<string, { at: number; body: Suggestion[] }>();

export async function GET(request: Request) {
  const q = (new URL(request.url).searchParams.get('q') ?? '').trim();

  // Below three characters every street in the city matches, which is a list
  // nobody can read and a request nobody needed.
  if (q.length < MIN_CHARS) return NextResponse.json({ suggestions: [] });
  if (q.length > 120) return NextResponse.json({ suggestions: [] });

  const key = q.toLowerCase().replace(/\s+/g, ' ');
  const hit = cache.get(key);
  if (hit && Date.now() - hit.at < CACHE_TTL_MS) {
    return NextResponse.json({ suggestions: hit.body });
  }

  let suggestions: Suggestion[] = [];
  try {
    const url = new URL(GEOSEARCH);
    url.searchParams.set('text', q);
    const res = await fetch(url, {
      headers: { 'User-Agent': 'Crease (creasenyc.com)' },
      signal: AbortSignal.timeout(4000),
    });
    if (res.ok) {
      const body = (await res.json()) as any;
      suggestions = (body.features ?? [])
        .map((f: any): Suggestion | null => {
          const [lng, lat] = f.geometry?.coordinates ?? [];
          if (typeof lat !== 'number' || typeof lng !== 'number') return null;
          const p = f.properties ?? {};
          return {
            label: String(p.label ?? '').replace(/, USA$/, ''),
            street: String(p.name ?? p.label ?? ''),
            borough: p.borough ?? null,
            lat,
            lng,
          };
        })
        .filter(Boolean)
        // Brooklyn first — it is the only borough Crease serves — but the rest
        // of the city still shows, because somebody in Queens typing their own
        // address deserves to be told no rather than shown nothing.
        .sort((a: Suggestion, b: Suggestion) => {
          const ab = a.borough === 'Brooklyn' ? 0 : 1;
          const bb = b.borough === 'Brooklyn' ? 0 : 1;
          return ab - bb;
        })
        .slice(0, MAX_SUGGESTIONS);
    }
  } catch {
    // A suggestion service that is down must not stop somebody typing their
    // address by hand and pressing the button.
    suggestions = [];
  }

  if (cache.size > 2000) cache.clear();
  cache.set(key, { at: Date.now(), body: suggestions });

  return NextResponse.json(
    { suggestions },
    { headers: { 'Cache-Control': 'public, max-age=600' } },
  );
}
