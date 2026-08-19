import type { MetadataRoute } from 'next';
import { CORE_AREAS, EDGE_AREAS, slugFor } from '@/lib/neighborhoods';

export default function sitemap(): MetadataRoute.Sitemap {
  // Static and short by design: two pages and a policy. A sitemap padded with
  // anchors is a sitemap nobody trusts.
  const areas = [...CORE_AREAS, ...EDGE_AREAS].map((a) => ({
    url: `https://creasenyc.com/laundry-pickup/${slugFor(a)}`,
    changeFrequency: 'monthly' as const,
    priority: 0.8,
  }));
  return [
    { url: 'https://creasenyc.com/', changeFrequency: 'weekly', priority: 1 },
    ...areas,
    { url: 'https://creasenyc.com/privacy.html', changeFrequency: 'yearly', priority: 0.3 },
  ];
}
