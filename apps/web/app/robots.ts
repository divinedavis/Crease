import type { MetadataRoute } from 'next';

/**
 * Crawlable on purpose. The whole point of the site is that somebody in
 * Brooklyn searching for laundry pickup finds it, so the only thing kept out
 * of the index is the order form — a page with nothing to read and a form to
 * fill in ranks for nothing and dilutes the pages that do.
 */
export default function robots(): MetadataRoute.Robots {
  return {
    rules: [{ userAgent: '*', allow: '/', disallow: ['/order'] }],
    sitemap: 'https://creasenyc.com/sitemap.xml',
    host: 'https://creasenyc.com',
  };
}
