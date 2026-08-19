import { CORE_AREAS, EDGE_AREAS, HEADLINE_AREAS, slugFor } from '@/lib/neighborhoods';
import { QuoteBox } from './quote-box';

/**
 * The App Store link, when there is one.
 *
 * There is not, yet: the app is on TestFlight and itunes.apple.com/lookup for
 * 6797080792 returns nothing. Linking to a store page that 404s is worse than
 * pointing somebody at the thing that does work, so the QR goes to /order and
 * the badge appears only when CREASE_APP_STORE_URL is set.
 */
const APP_STORE_URL = process.env.CREASE_APP_STORE_URL ?? null;

// Laundry first, and only laundry. Dry cleaning is a per-garment price list
// every shop keeps differently; wash & fold is one rate anybody can quote from
// a doorstep, and it is weekly where dry cleaning is monthly. It comes back as
// a service when a shop has given real prices for it — until then it is named
// as what it is, which is not yet.
const SERVICES: Array<{ emoji: string; name: string; note: string; href: string | null }> = [
  { emoji: '🧺', name: 'Wash & fold', note: '$2.00/lb · $20 minimum', href: '/order?service=wash_fold' },
  { emoji: '🛏️', name: 'Bedding & towels', note: 'Weighed in with the rest', href: '/order?service=wash_fold' },
  { emoji: '📦', name: 'Return only', note: "It's at the shop — bring it home", href: '/order?tier=return_only' },
  { emoji: '👔', name: 'Dry cleaning', note: 'Coming next', href: null },
];

export default async function Home({
  searchParams,
}: {
  searchParams: Promise<Record<string, string | string[] | undefined>>;
}) {
  // /?owner=1 marks this device as yours so the traffic tile stops counting
  // it; /?owner=0 undoes it.
  //
  // A redirect rather than a fetch from here. Calling the route server-side
  // sends the request back through nginx from the box itself, and nginx sets
  // X-Real-IP from the socket it can see — so the address registered was the
  // droplet's own. The browser has to knock on that door itself.
  const params = await searchParams;
  if (params.owner !== undefined) {
    const { redirect } = await import('next/navigation');
    redirect(`/api/owner?owner=${params.owner === '0' ? '0' : '1'}`);
  }
  const ownerSet = params.owner_set;

  return (
    <>
      <nav className="wrap nav">
        <div className="brand">
          {/* eslint-disable-next-line @next/next/no-img-element */}
          <img src="/assets/icon.svg" alt="" width={34} height={34} />
          Crease
        </div>
        <div className="links">
          <a href="/order">Order</a>
          <a href="#services">Services</a>
          <a href="#how">How it works</a>
        </div>
        <a href="/order" style={{ color: 'var(--green)' }}>
          Book a pickup
        </a>
      </nav>

      <main className="wrap">
        <section className="home">
          <div>
            <span className="area">📍 Clinton Hill, Brooklyn</span>
            {ownerSet !== undefined && (
              <p className="fine">
                {ownerSet === '0'
                  ? 'This device counts as a visitor again.'
                  : 'Noted — visits from this device are no longer counted as traffic.'}
              </p>
            )}
            <h1>Laundry, picked up and delivered.</h1>
            <p className="lede">
              $2.00 a pound, $20 minimum. Book now and a driver is on the way — we collect from
              your door, wash and fold it, and bring it back.
            </p>
            {/* Said before the address box, not after it. Somebody four miles
                away should learn that from a sentence rather than from typing
                their street and being turned down. */}
            <p className="fine" style={{ marginBottom: 18 }}>
              We collect and deliver within <b>3 miles of Clinton Hill</b> —{' '}
              {HEADLINE_AREAS.join(', ')} and{' '}
              <a href="#areas">{CORE_AREAS.length + EDGE_AREAS.length - HEADLINE_AREAS.length} more
              neighborhoods</a>. Check your address and we&rsquo;ll tell you either way.
            </p>
            <QuoteBox />
          </div>

          <div id="services">
            <h2 style={{ fontSize: '1.35rem', marginBottom: 16 }}>Services</h2>
            <div className="tiles">
              {SERVICES.map((s) =>
                s.href ? (
                  <a className="tile" key={s.name} href={s.href}>
                    <span className="emoji" aria-hidden="true">
                      {s.emoji}
                    </span>
                    <strong>{s.name}</strong>
                    <span>{s.note}</span>
                  </a>
                ) : (
                  <div className="tile soon" key={s.name}>
                    <span className="emoji" aria-hidden="true">
                      {s.emoji}
                    </span>
                    <strong>{s.name}</strong>
                    <span>{s.note}</span>
                  </div>
                ),
              )}
            </div>
          </div>
        </section>

        <section className="band" id="areas">
          <h2>Where we collect</h2>
          <p className="lede" style={{ marginBottom: 22 }}>
            Three miles from Clinton Hill. That is most of brownstone Brooklyn — and a good deal
            further than people expect.
          </p>
          <div className="two">
            <div className="card">
              <h3>All of it is inside the band</h3>
              <ul className="areas">
                {CORE_AREAS.map((a) => (
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
            </div>
            <div className="card">
              <h3>Partly inside — check your street</h3>
              <ul className="areas">
                {EDGE_AREAS.map((a) => (
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
              <p className="fine" style={{ marginTop: 12 }}>
                These stretch past the band at the far end. Type your address and you get a yes or
                a no about your own block, not your neighborhood.
              </p>
            </div>
          </div>
        </section>

        <section className="band" id="how">
          <h2>How it works</h2>
          <div className="grid">
            <div className="card">
              <span className="num">1</span>
              <h3>Book a pickup</h3>
              <p>
                Book and a driver heads over — typically 20 to 30 minutes, not a window next
                Tuesday. No bags to drop off, no counter to queue at.
              </p>
            </div>
            <div className="card">
              <span className="num">2</span>
              <h3>We do the work</h3>
              <p>
                Washed and folded in the neighborhood, not trucked to a warehouse across the city.
                We weigh your bag and charge $2.00 a pound for exactly what came in — $20 minimum.
              </p>
            </div>
            <div className="card">
              <span className="num">3</span>
              <h3>Washed, folded, delivered</h3>
              <p>Track both trips — to the shop and back to you. Folded and ready to put away.</p>
            </div>
          </div>
        </section>

        <section className="band">
          <h2>You approve the final price</h2>
          <div className="two">
            <div className="card">
              <h3>One payment, itemised</h3>
              <p>
                Cleaning and couriers on one card charge, listed line by line before you pay. We
                hold exactly what the order comes to — never more.
              </p>
            </div>
            <div className="card">
              <h3>Nothing charged without you</h3>
              <p>
                Nobody knows what a bag weighs before it is on the scale. You are charged the
                weight we measure — $2.00 a pound, $20 minimum — and if it comes in over what you
                estimated we ask you before taking another penny. Cancel before a driver is
                assigned and you pay nothing.
              </p>
            </div>
          </div>
        </section>

        <section className="band">
          <h2>It&rsquo;s easier on your phone</h2>
          <div className="two">
            <div className="qr">
              {/* eslint-disable-next-line @next/next/no-img-element */}
              <img src="/assets/qr-order.svg" alt="QR code linking to creasenyc.com/order" />
              <div>
                <h3>{APP_STORE_URL ? 'Download the Crease app' : 'Order from your phone'}</h3>
                <p>
                  {APP_STORE_URL
                    ? 'Scan to download'
                    : 'Scan to book a pickup. The iPhone app is coming to the App Store.'}
                </p>
              </div>
            </div>
            <div className="qr">
              <div>
                <h3>Same day, most days</h3>
                <p>
                  Book in the morning and it is usually back the same evening. You pick the
                  delivery time once it is washed and folded.
                </p>
              </div>
            </div>
          </div>
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
                <a href="#how">How it works</a>
              </li>
              <li>
                <a href="mailto:divinejdavis@gmail.com">Contact</a>
              </li>
            </ul>
          </div>
          <div>
            <h4>Services</h4>
            <ul>
              {SERVICES.map((s) => (
                <li key={s.name}>
                  {/* A service with nowhere to go is still worth naming — it
                      answers "do you do dry cleaning?" without promising it. */}
                  {s.href ? <a href={s.href}>{s.name}</a> : <span>{s.name} · soon</span>}
                </li>
              ))}
            </ul>
          </div>
          <div>
            <h4>Where we collect</h4>
            <ul>
              <li>
                <a href="#areas">3 miles of Clinton Hill</a>
              </li>
              <li>Clinton Hill · Fort Greene</li>
              <li>Downtown Brooklyn · DUMBO</li>
              <li>Park Slope · Bed-Stuy</li>
              <li>
                <a href="#areas">and {CORE_AREAS.length + EDGE_AREAS.length - 6} more</a>
              </li>
            </ul>
          </div>
            <div className="legal">
              © 2026 Crease · <a href="/privacy.html">Privacy</a>
            </div>
          </div>
        </div>
      </footer>
    </>
  );
}
