import type { MetadataRoute } from 'next';

/**
 * Crawlable on purpose. The whole point of the site is that somebody in
 * Brooklyn searching for laundry pickup finds it, so the only thing kept out
 * of the index is the order form — a page with nothing to read and a form to
 * fill in ranks for nothing and dilutes the pages that do.
 *
 * /r and /w join it for a different reason: they are not pages at all, they
 * are the two printed QR codes (see marketing/signage/) resolving to wherever
 * the scan should go today. Crawling them costs a redirect and puts a URL in
 * the index that exists to be pointed at by a phone camera, never typed.
 */
export default function robots(): MetadataRoute.Robots {
  return {
    rules: [{ userAgent: '*', allow: '/', disallow: ['/order', '/r', '/w'] }],
    sitemap: 'https://creasenyc.com/sitemap.xml',
    host: 'https://creasenyc.com',
  };
}
