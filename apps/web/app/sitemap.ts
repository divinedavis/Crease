import type { MetadataRoute } from 'next';

export default function sitemap(): MetadataRoute.Sitemap {
  // Static and short by design: two pages and a policy. A sitemap padded with
  // anchors is a sitemap nobody trusts.
  return [
    { url: 'https://creasenyc.com/', changeFrequency: 'weekly', priority: 1 },
    { url: 'https://creasenyc.com/privacy.html', changeFrequency: 'yearly', priority: 0.3 },
  ];
}
