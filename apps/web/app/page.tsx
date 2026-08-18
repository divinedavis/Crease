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

const SERVICES = [
  { emoji: '👔', name: 'Dry cleaning', note: 'Suits, coats, dresses', href: '/order?service=dry_clean' },
  { emoji: '🧺', name: 'Wash & fold', note: 'By the pound, back in hours', href: '/order?service=wash_fold' },
  { emoji: '✨', name: 'Press only', note: 'Already clean, needs pressing', href: '/order?service=press' },
  { emoji: '📦', name: 'Return only', note: "It's at the shop — bring it home", href: '/order?tier=return_only' },
];

export default function Home() {
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
            <span className="area">📍 Brooklyn, NY</span>
            <h1>Dry cleaning, picked up and delivered.</h1>
            <QuoteBox />
          </div>

          <div id="services">
            <h2 style={{ fontSize: '1.35rem', marginBottom: 16 }}>Services</h2>
            <div className="tiles">
              {SERVICES.map((s) => (
                <a className="tile" key={s.name} href={s.href}>
                  <span className="emoji" aria-hidden="true">
                    {s.emoji}
                  </span>
                  <strong>{s.name}</strong>
                  <span>{s.note}</span>
                </a>
              ))}
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
              <h3>A real cleaner does the work</h3>
              <p>
                Your order goes to a neighborhood dry cleaner, not a warehouse. They count every
                garment and price exactly what&rsquo;s in the bag.
              </p>
            </div>
            <div className="card">
              <span className="num">3</span>
              <h3>Delivered back, pressed</h3>
              <p>Track both trips — to the cleaner and back to you. Ready to wear.</p>
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
                Nobody can price a bag before opening it. If the shop counts more than you picked,
                we ask you before taking another penny. Cancel before a driver is assigned and you
                pay nothing.
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
                  <a href={s.href}>{s.name}</a>
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
            <h4>Neighborhoods</h4>
            <ul>
              <li>Clinton Hill</li>
              <li>Fort Greene</li>
              <li>Bed-Stuy</li>
              <li>Prospect Heights</li>
            </ul>
          </div>
          <div className="legal">
            © 2026 Crease · <a href="/privacy.html">Privacy</a>
          </div>
        </div>
      </footer>
    </>
  );
}
