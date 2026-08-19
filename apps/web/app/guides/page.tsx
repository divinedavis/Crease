import type { Metadata } from 'next';
import { SiteFooter, SiteNav } from '../chrome';
import { allGuides } from '@/lib/guides';

/**
 * The hub the guides hang off.
 *
 * Content written by the engine is read off disk, so this page has to be
 * re-read rather than baked at build time — see lib/guides.ts. Sixty seconds
 * is short enough that a page published at 05:20 is linked from here before
 * anybody is awake, and long enough that a crawler hitting thirty guides in a
 * row does not stat the directory thirty times.
 */
export const revalidate = 60;

export const metadata: Metadata = {
  title: 'Laundry guides for Brooklyn | Crease',
  description:
    'Straight answers about wash & fold, laundry pickup and delivery, and doing laundry without a machine in Brooklyn.',
  alternates: { canonical: 'https://creasenyc.com/guides' },
};

export default function GuidesIndex() {
  const guides = allGuides();
  return (
    <>
      <SiteNav guides={false} />
      <main className="wrap">
        <section className="home" style={{ gridTemplateColumns: '1fr' }}>
          <div>
            <h1>Laundry guides</h1>
            <p className="lede">
              What a load actually weighs, what wash &amp; fold costs in Brooklyn, and how to get
              laundry done when there is no machine in the building. Written for this neighborhood,
              not for everywhere.
            </p>
          </div>
        </section>

        <section className="band">
          {guides.length === 0 ? (
            <p className="fine">Nothing published yet.</p>
          ) : (
            <div className="grid">
              {guides.map((g) => (
                <article className="card" key={g.slug}>
                  <h3>
                    <a href={`/guides/${g.slug}`} style={{ color: 'inherit' }}>
                      {g.title}
                    </a>
                  </h3>
                  <p>{g.description}</p>
                </article>
              ))}
            </div>
          )}
        </section>
      </main>
      <SiteFooter />
    </>
  );
}
