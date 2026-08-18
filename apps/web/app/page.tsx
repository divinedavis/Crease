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
          <a href="https://portal.creasenyc.com">For cleaners</a>
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
              $2.00 a pound, $20 minimum. A courier collects from your door, Fulton Cleaners on
              Fulton Street washes and folds it, and it comes back to you.
            </p>
            {/* Said before the address box, not after it. Somebody four miles
                away should learn that from a sentence rather than from typing
                their street and being turned down. */}
            <p className="fine" style={{ marginBottom: 18 }}>
              We collect and deliver within <b>3 miles of Fulton Cleaners</b>, 909 Fulton Street —
              Clinton Hill, Fort Greene, Bed-Stuy, Prospect Heights, Crown Heights and the blocks
              around them. Check your address and we&rsquo;ll tell you either way.
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

        <section className="band" id="how">
          <h2>How it works</h2>
          <div className="grid">
            <div className="card">
              <span className="num">1</span>
              <h3>Book a pickup</h3>
              <p>
                Pick a window that suits you. A courier collects from your door — no bags to drop
                off, no counter to queue at.
              </p>
            </div>
            <div className="card">
              <span className="num">2</span>
              <h3>Fulton Cleaners does the work</h3>
              <p>
                Your bag goes to a shop on Fulton Street, not a warehouse. They weigh it and charge
                $2.00 a pound for exactly what came in — $20 minimum.
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
                shop&rsquo;s weight — $2.00 a pound, $20 minimum — and if it comes in over what you
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
              {/* eslint-disable-next-line @next/next/no-img-element */}
              <img src="/assets/qr-portal.svg" alt="QR code linking to the Crease cleaner portal" />
              <div>
                <h3>Run a cleaner?</h3>
                <p>Scan for the shop portal — count bags, price orders, get paid.</p>
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
            <h4>Cleaners</h4>
            <ul>
              <li>
                <a href="https://portal.creasenyc.com">Partner portal</a>
              </li>
              <li>
                <a href="mailto:divinejdavis@gmail.com">Partner with us</a>
              </li>
            </ul>
          </div>
          <div>
            <h4>Where we collect</h4>
            <ul>
              <li>Within 3 miles of</li>
              <li>909 Fulton Street</li>
              <li>Clinton Hill · Fort Greene</li>
              <li>Bed-Stuy · Prospect Heights</li>
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
