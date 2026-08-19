import { NextResponse, type NextRequest } from 'next/server';

/**
 * Nothing, deliberately — and the reason is worth keeping.
 *
 * This used to re-register the owner's current address on every visit: a
 * marked device would fire /api/owner in the background so the nginx traffic
 * count could follow it from home wifi to cell. It never worked. Middleware
 * returns its response immediately and the un-awaited fetch was torn down with
 * the request, silently, so the address list only ever held whatever network
 * the owner was on the moment he clicked /?owner=1. On 19 Aug 2026 his home
 * address changed and the dashboard began counting him as a visitor to his own
 * site; the list still held the old one, and a test with the cookie set
 * registered nothing at all.
 *
 * The fix was to stop asking the app to notice. nginx now logs the
 * crease_owner cookie as the last field of every request, and the traffic
 * count drops any address that presents it that day — the cookie rides every
 * request a browser makes, so it follows the device wherever it goes. NEMO's
 * log has worked this way since July.
 *
 * /?owner=1 still sets the cookie and still records the address it was clicked
 * from, which is the fallback for a request that arrives without one.
 */
export function middleware(_request: NextRequest) {
  return NextResponse.next();
}

export const config = { matcher: [] };
