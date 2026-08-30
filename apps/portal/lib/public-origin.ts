/**
 * The portal's own public origin, for building redirect targets.
 *
 * PORTAL_PUBLIC_URL first, because it is the only source a caller cannot
 * reach. The Host header is the fallback: nothing in front of the app strips
 * it, so it is caller-supplied, and a redirect built from it sends the browser
 * wherever the caller asked. The vhosts pin proxy_set_header Host to $host and
 * nginx rewrites Location, which is why the fallback is tolerable at all — but
 * it is a fallback, not the first choice.
 *
 * A malformed PORTAL_PUBLIC_URL (a typo in the unit file) is ignored rather
 * than parsed, so a bad value degrades to the header instead of throwing on
 * every request. Same shape check middleware.ts uses.
 */
export function publicOrigin(headers: Headers): string {
  const configured = process.env.PORTAL_PUBLIC_URL?.trim().replace(/\/+$/, '');
  if (configured && /^https?:\/\/[^/]+$/.test(configured)) return configured;

  const host = headers.get('host');
  if (!host) return 'https://portal.creasenyc.com';
  const proto = headers.get('x-forwarded-proto') ?? 'https';
  return `${proto}://${host}`;
}
