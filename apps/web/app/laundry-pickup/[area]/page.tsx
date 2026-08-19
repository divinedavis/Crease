import type { Metadata } from 'next';
import { notFound } from 'next/navigation';
import { CORE_AREAS, EDGE_AREAS, findArea, slugFor } from '@/lib/neighborhoods';
import { QuoteBox } from '../../quote-box';

/**
 * A page per neighborhood, because that is how people search.
 *
 * Nobody types "wash and fold three miles from 909 Fulton Street". They type
 * "laundry pickup Park Slope", and a service area is exactly the kind of thing
 * a single home page cannot rank for in eighteen places at once.
 *
 * Each page says something true about collecting from that particular
 * neighborhood — how far it is, what the trip looks like — rather than the
 * same paragraph with the name swapped, which is what search engines
 * (correctly) treat as one page repeated.
 */
export function generateStaticParams() {
  return [...CORE_AREAS, ...EDGE_AREAS].map((a) => ({ area: slugFor(a) }));
}

export async function generateMetadata({
  params,
}: {
  params: Promise<{ area: string }>;
}): Promise<Metadata> {
  const { area: slug } = await params;
  const area = findArea(slug);
  if (!area) return {};
  const title = `Laundry pickup & delivery in ${area.name} — $2.00/lb | Crease`;
  const description = `Wash and fold pickup and delivery in ${area.name}, Brooklyn. $2.00 a pound, $20 minimum. A courier collects from your door and Fulton Cleaners does the rest.`;
  return {
    title,
    description,
    alternates: { canonical: `https://creasenyc.com/laundry-pickup/${slug}` },
    openGraph: { title, description, url: `https://creasenyc.com/laundry-pickup/${slug}` },
  };
}

export default async function AreaPage({ params }: { params: Promise<{ area: string }> }) {
  const { area: slug } = await params;
  const area = findArea(slug);
  if (!area) notFound();

  const partial = EDGE_AREAS.some((a) => slugFor(a) === slug);
  const others = [...CORE_AREAS, ...EDGE_AREAS].filter((a) => slugFor(a) !== slug);

  return (
    <>
      <nav className="wrap nav">
        <div className="brand">
          {/* eslint-disable-next-line @next/next/no-img-element */}
          <img src="/assets/icon.svg" alt="" width={34} height={34} />
          <a href="/" style={{ color: 'inherit', textDecoration: 'none' }}>
            Crease
          </a>
        </div>
        <div className="links">
          <a href="/order">Order</a>
          <a href="/#areas">Where we collect</a>
          <a href="https://portal.creasenyc.com">For cleaners</a>
        </div>
        <a href="/order" style={{ color: 'var(--green)' }}>
          Book a pickup
        </a>
      </nav>

      <main className="wrap">
        <section className="home">
          <div>
            <span className="area">📍 {area.name}, Brooklyn</span>
            <h1>Laundry pickup and delivery in {area.name}.</h1>
            <p className="lede">
              $2.00 a pound, $20 minimum. A courier collects from your door in {area.name}, Fulton
              Cleaners washes and folds it, and it comes back to you.
            </p>
            <p className="fine" style={{ marginBottom: 18 }}>
              {area.note ??
                `${area.name} is about ${area.miles} miles from Fulton Cleaners at 909 Fulton Street.`}{' '}
              {partial && (
                <>
                  <b>Part of {area.name} sits outside our three-mile band</b> — check your address
                  and you&rsquo;ll get an answer about your own block rather than your neighborhood.
                </>
              )}
            </p>
            <QuoteBox />
          </div>

          <div>
            <h2 style={{ fontSize: '1.35rem', marginBottom: 16 }}>What it costs</h2>
            <div className="card" style={{ marginBottom: 14 }}>
              <h3>$2.00 a pound</h3>
              <p>
                $20 minimum, which is a 10 lb bag. You&rsquo;re charged the shop&rsquo;s scale
                weight — not an estimate, and never more than the order comes to without asking you
                first.
              </p>
            </div>
            <div className="card">
              <h3>Plus one courier fee</h3>
              <p>
                $29.95 for a round trip, or $16.95 if you only need one leg. Cleaning and couriers
                arrive as a single charge, itemised before you pay.
              </p>
            </div>
          </div>
        </section>

        <section className="band">
          <h2>How it works in {area.name}</h2>
          <div className="grid">
            <div className="card">
              <span className="num">1</span>
              <h3>Book a pickup</h3>
              <p>
                Pick a window. A courier collects from your door in {area.name} — no bags to carry,
                no counter to queue at.
              </p>
            </div>
            <div className="card">
              <span className="num">2</span>
              <h3>Fulton Cleaners does the work</h3>
              <p>
                Your bag goes to a shop on Fulton Street, {area.miles} miles away, not a warehouse.
                They weigh it and charge $2.00 a pound for exactly what came in.
              </p>
            </div>
            <div className="card">
              <span className="num">3</span>
              <h3>Washed, folded, delivered</h3>
              <p>Back to your door in {area.name}, folded and ready to put away.</p>
            </div>
          </div>
        </section>

        <section className="band">
          <h2>Other neighborhoods we collect from</h2>
          <ul className="areas">
            {others.map((a) => (
              <li key={a.name}>
                <a href={`/laundry-pickup/${slugFor(a)}`} style={{ color: 'inherit', textDecoration: 'none' }}>
                  {a.name}
                </a>
              </li>
            ))}
          </ul>
        </section>
      </main>

      <footer className="sitefoot">
        <div className="wrap">
          <div className="footgrid">
            <div>
              <h4>Crease</h4>
              <ul>
                <li>
                  <a href="/order">Book a pickup</a>
                </li>
                <li>
                  <a href="/#areas">Where we collect</a>
                </li>
                <li>
                  <a href="mailto:divinejdavis@gmail.com">Contact</a>
                </li>
              </ul>
            </div>
            <div>
              <h4>Service</h4>
              <ul>
                <li>Wash &amp; fold · $2.00/lb</li>
                <li>$20 minimum</li>
                <li>Dry cleaning · soon</li>
              </ul>
            </div>
            <div>
              <h4>Cleaners</h4>
              <ul>
                <li>
                  <a href="https://portal.creasenyc.com">Partner portal</a>
                </li>
              </ul>
            </div>
            <div className="legal">
              © 2026 Crease · <a href="/privacy.html">Privacy</a>
            </div>
          </div>
        </div>
      </footer>

      {/* Structured data so a search engine can read the service, the area and
          the price without inferring them from prose. */}
      <script
        type="application/ld+json"
        dangerouslySetInnerHTML={{
          __html: JSON.stringify({
            '@context': 'https://schema.org',
            '@type': 'Service',
            serviceType: 'Laundry pickup and delivery',
            name: `Laundry pickup and delivery in ${area.name}`,
            provider: {
              '@type': 'LocalBusiness',
              name: 'Crease',
              url: 'https://creasenyc.com',
              address: {
                '@type': 'PostalAddress',
                streetAddress: '909 Fulton Street',
                addressLocality: 'Brooklyn',
                addressRegion: 'NY',
                addressCountry: 'US',
              },
            },
            areaServed: { '@type': 'Place', name: `${area.name}, Brooklyn, NY` },
            offers: {
              '@type': 'Offer',
              price: '2.00',
              priceCurrency: 'USD',
              description: 'Wash and fold, per pound, $20 minimum',
            },
          }),
        }}
      />
    </>
  );
}
