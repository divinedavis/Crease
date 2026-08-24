import { headers } from 'next/headers';
import { redirect } from 'next/navigation';
import { isIOS } from './useragent';

/**
 * Where a printed QR code lands.
 *
 * The codes are on physical objects — a card on a laundromat counter, a cling
 * on a shop window — and physical objects cannot be redeployed. Whatever is
 * printed today has to keep working after the App Store listing appears, after
 * the order form moves, after the site is renamed again. So the printed URL is
 * a short stable path (/r, /w) that resolves here, and everything that might
 * change is decided at request time.
 *
 * Two placements rather than one because the person differs. Somebody standing
 * at a cleaner's counter has already decided; send them straight to the form.
 * Somebody who read a sticker on a window on the way past has not heard of
 * Crease; send them to the page that explains it. The paths are also how the
 * two are told apart afterwards — nginx logs the path, so the traffic count in
 * growth/traffic.py separates counter cards from window clings with no tag,
 * no cookie and nothing for an ad-blocker to strip.
 */

/**
 * The App Store link, when there is one. Same variable the home page reads —
 * see apps/web/app/page.tsx. Until it is set, an iPhone gets the web flow,
 * because a store page that 404s is worse than a form that works.
 */
const APP_STORE_URL = process.env.CREASE_APP_STORE_URL ?? null;

export type ScanSource = 'qr-register' | 'qr-window';

/**
 * Decided on the server, not in the browser: a redirect from a client
 * interstitial means a blank flash on a phone camera hand-off, and it does
 * nothing at all with JavaScript disabled. `headers()` opts the route out of
 * static rendering on its own — no `dynamic` export needed.
 */
export async function scanRedirect(source: ScanSource, fallback: string): Promise<never> {
  const ua = (await headers()).get('user-agent') ?? '';

  if (APP_STORE_URL && isIOS(ua)) {
    // No `src` to append: the App Store swallows unknown query params, and
    // the hop through this route is already in the nginx log.
    redirect(APP_STORE_URL);
  }

  const join = fallback.includes('?') ? '&' : '?';
  redirect(`${fallback}${join}src=${source}`);
}
