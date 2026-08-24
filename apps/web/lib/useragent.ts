/**
 * Is this an iPhone or an iPad?
 *
 * Its own file, with no Next imports, so it can be tested by `node --test`
 * without a request in flight — see useragent.test.ts. The one caller is
 * scan.ts, deciding whether a scanned QR code should hand off to the App
 * Store.
 */

/** The straightforward half. iPod is in there because iOS still ships on it. */
const APPLE_MOBILE = /iPhone|iPod/i;

/**
 * The half that catches people out: since iPadOS 13, Safari on an iPad
 * defaults to "Request Desktop Website" and sends a user-agent claiming to be
 * a Mac — no "iPad" anywhere in the string. What it cannot hide is that it is
 * a phone-lineage browser, so the "Mobile/…" build token stays. A real Mac
 * never sends it.
 */
const IPAD_AS_MAC = /Macintosh/i;
const MOBILE_TOKEN = /\bMobile\b/;

export function isIOS(userAgent: string): boolean {
  if (APPLE_MOBILE.test(userAgent)) return true;
  if (/iPad/i.test(userAgent)) return true;
  return IPAD_AS_MAC.test(userAgent) && MOBILE_TOKEN.test(userAgent);
}
