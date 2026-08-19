import type { Metadata } from 'next';
import { notFound } from 'next/navigation';
import { SiteFooter, SiteNav } from '../../chrome';
import { allGuides, getGuide, ldJson } from '@/lib/guides';
import { findArea, slugFor } from '@/lib/neighborhoods';

/**
 * One guide, rendered from the JSON the growth engine wrote.
 *
 * Server-rendered on demand: there is no generateStaticParams, because the set
 * of guides changes on the droplet after this app was built and a static list
 * would 404 every page published since the last deploy.
 */
export const revalidate = 60;
export const dynamicParams = true;

const SITE = 'https://creasenyc.com';

export async function generateMetadata({
  params,
}: {
  params: Promise<{ slug: string }>;
}): Promise<Metadata> {
  const { slug } = await params;
  const g = getGuide(slug);
  if (!g) return {};
  const url = `${SITE}/guides/${g.slug}`;
  return {
    title: `${g.title} | Crease`,
    description: g.description,
    alternates: { canonical: url },
    openGraph: { title: g.title, description: g.description, url, type: 'article' },
  };
}

export default async function GuidePage({ params }: { params: Promise<{ slug: string }> }) {
  const { slug } = await params;
  const g = getGuide(slug);
  if (!g) notFound();

  const url = `${SITE}/guides/${g.slug}`;
  const areas = g.areas.map((s) => findArea(s)).filter((a) => a !== undefined);
  const others = allGuides()
    .filter((x) => x.slug !== g.slug)
    .slice(0, 4);

  const graph: unknown[] = [
    {
      '@type': 'Article',
      headline: g.title,
      description: g.description,
      datePublished: g.published || undefined,
      dateModified: g.updated || g.published || undefined,
      mainEntityOfPage: url,
      author: { '@type': 'Organization', name: 'Crease', url: SITE },
      publisher: { '@type': 'Organization', name: 'Crease', url: SITE },
    },
    {
      '@type': 'BreadcrumbList',
      itemListElement: [
        { '@type': 'ListItem', position: 1, name: 'Crease', item: SITE },
        { '@type': 'ListItem', position: 2, name: 'Guides', item: `${SITE}/guides` },
        { '@type': 'ListItem', position: 3, name: g.title, item: url },
      ],
    },
  ];
  // Only when there are questions. An empty FAQPage is a structured-data
  // warning in Search Console and buys nothing.
  if (g.faq.length) {
    graph.push({
      '@type': 'FAQPage',
      mainEntity: g.faq.map((f) => ({
        '@type': 'Question',
        name: f.q,
        acceptedAnswer: { '@type': 'Answer', text: f.a },
      })),
    });
  }

  return (
    <>
      <SiteNav guides={false} />
      <main className="wrap">
        <article>
          <section className="home" style={{ gridTemplateColumns: '1fr' }}>
            <div>
              <span className="area">
                <a href="/guides" style={{ color: 'inherit', textDecoration: 'none' }}>
                  ← Guides
                </a>
              </span>
              <h1>{g.title}</h1>
              <p className="lede">{g.intro}</p>
              {g.updated && <p className="fine">Last updated {g.updated}.</p>}
            </div>
          </section>

          <div className="prose">
            {g.sections.map((s) => (
              <section className="band" key={s.heading}>
                <h2>{s.heading}</h2>
                {s.body.map((p, i) => (
                  <p key={i}>{p}</p>
                ))}
              </section>
            ))}
          </div>

          {g.faq.length > 0 && (
            <section className="band">
              <h2>Common questions</h2>
              <div className="prose">
                {g.faq.map((f) => (
                  <div key={f.q}>
                    <h3>{f.q}</h3>
                    <p>{f.a}</p>
                  </div>
                ))}
              </div>
            </section>
          )}
        </article>

        <section className="band">
          <h2>Book a pickup</h2>
          <p className="lede">
            Wash &amp; fold is $2.00 a pound with a $20 minimum, plus one courier fee — $29.95 for a
            round trip. A driver collects from your door anywhere within three miles of Clinton
            Hill.
          </p>
          <p>
            <a className="cta" href="/order">
              Check your address
            </a>
          </p>
        </section>

        {areas.length > 0 && (
          <section className="band">
            <h2>Where we collect</h2>
            <ul className="areas">
              {areas.map((a) => (
                <li key={a.name}>
                  <a
                    href={`/laundry-pickup/${slugFor(a)}`}
                    style={{ color: 'inherit', textDecoration: 'none' }}
                  >
                    {a.name}
                  </a>
                </li>
              ))}
            </ul>
          </section>
        )}

        {others.length > 0 && (
          <section className="band">
            <h2>More guides</h2>
            <div className="grid">
              {others.map((o) => (
                <article className="card" key={o.slug}>
                  <h3>
                    <a href={`/guides/${o.slug}`} style={{ color: 'inherit' }}>
                      {o.title}
                    </a>
                  </h3>
                  <p>{o.description}</p>
                </article>
              ))}
            </div>
          </section>
        )}
      </main>
      <SiteFooter />

      <script
        type="application/ld+json"
        dangerouslySetInnerHTML={{
          __html: ldJson({ '@context': 'https://schema.org', '@graph': graph }),
        }}
      />
    </>
  );
}
