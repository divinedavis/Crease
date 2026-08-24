import type { MetadataRoute } from 'next';
import { allGuides } from '@/lib/guides';
import { AREAS_UPDATED, CORE_AREAS, EDGE_AREAS, slugFor } from '@/lib/neighborhoods';

/**
 * Re-read rather than baked, because the guides are written on the droplet
 * after this app was built. A sitemap that only lists what existed at build
 * time is a sitemap that never mentions anything the engine published.
 */
export const revalidate = 60;

const SITE = 'https://creasenyc.com';

export default function sitemap(): MetadataRoute.Sitemap {
  const areas = [...CORE_AREAS, ...EDGE_AREAS].map((a) => ({
    url: `${SITE}/laundry-pickup/${slugFor(a)}`,
    lastModified: AREAS_UPDATED,
    changeFrequency: 'monthly' as const,
    priority: 0.8,
  }));

  const guides = allGuides();
  // lastmod is the date the content actually changed, not today's date. A
  // sitemap that claims every page changed this morning is one Google stops
  // believing, and lastmod is the only signal that makes it re-crawl.
  const guideEntries = guides.map((g) => ({
    url: `${SITE}/guides/${g.slug}`,
    lastModified: g.updated || g.published || undefined,
    changeFrequency: 'monthly' as const,
    priority: 0.7,
  }));
  const newestGuide = guides
    .map((g) => g.updated || g.published)
    .filter(Boolean)
    .sort()
    .pop();

  return [
    { url: `${SITE}/`, lastModified: newestGuide ?? AREAS_UPDATED, changeFrequency: 'weekly', priority: 1 },
    ...areas,
    ...(guides.length
      ? [
          {
            url: `${SITE}/guides`,
            lastModified: newestGuide,
            changeFrequency: 'weekly' as const,
            priority: 0.6,
          },
        ]
      : []),
    ...guideEntries,
    { url: `${SITE}/privacy.html`, changeFrequency: 'yearly', priority: 0.3 },
  ];
}
