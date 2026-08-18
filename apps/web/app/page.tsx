import { CoverageCheck } from './coverage-check';

/**
 * The App Store link, when there is one.
 *
 * There is not, yet: the app is on TestFlight and itunes.apple.com/lookup for
 * 6797080792 returns nothing. Linking to a store page that 404s is worse than
 * saying "coming soon", so the URL is configuration and the page renders
 * whichever truth it currently has. Set CREASE_APP_STORE_URL the day it ships.
 */
const APP_STORE_URL = process.env.CREASE_APP_STORE_URL ?? null;
const TESTFLIGHT_URL = process.env.CREASE_TESTFLIGHT_URL ?? null;

export default function Home() {
  const appLink = APP_STORE_URL ?? TESTFLIGHT_URL;

  return (
    <>
      <header className="wrap">
        <div className="brand">
          {/* eslint-disable-next-line @next/next/no-img-element */}
          <img src="/assets/icon.svg" alt="" width={40} height={40} />
          Crease
        </div>
      </header>

      <main className="wrap">
        <section className="hero">
          <div className="hero-copy">
            <h1>
              Dry cleaning, <em>picked up and delivered.</em>
            </h1>
            <p className="lede">
              A courier collects from your door. Your neighborhood cleaner does the work — and
              everything comes back pressed. Order from your phone or right here.
            </p>

            <CoverageCheck appStoreUrl={appLink} />

            {!APP_STORE_URL && (
              <span className="badge-note">
                {TESTFLIGHT_URL
                  ? 'The iPhone app is in TestFlight while the App Store review runs.'
                  : 'The iPhone app is coming to the App Store. Ordering here works today.'}
              </span>
            )}
          </div>
          <div className="hero-shot">
            {/* eslint-disable-next-line @next/next/no-img-element */}
            <img
              src="/assets/app-home.png"
              alt="The Crease app showing a scheduled pickup and orders being counted at the cleaner"
              width={640}
              height={1392}
            />
          </div>
        </section>

        <section className="steps">
          <h2>How it works</h2>
          <div className="grid">
            <div className="card">
              <span className="num">1</span>
              <h3>Book a pickup</h3>
              <p>
                Pick a window that suits you. A courier collects your garments from your door — no
                bags to drop off, no counter to queue at.
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
              <p>
                Track both trips — to the cleaner and back to you. Your clothes return ready to
                wear.
              </p>
            </div>
          </div>
        </section>

        <section className="fair">
          <h2>You approve the final price</h2>
          <p>
            Nobody can price a bag of laundry before opening it — so we don&rsquo;t pretend to. You
            pick your garments at your cleaner&rsquo;s own prices and see the whole bill, cleaning
            and courier, before you pay. The shop counts what actually arrived, and if it comes in
            higher than what you picked, nothing more is charged until you approve it.
          </p>
        </section>
      </main>

      <footer className="wrap">
        <span>© 2026 Crease</span>
        <span>
          <a href="https://portal.usecreaseapp.com">Cleaner? Partner with us</a> ·{' '}
          <a href="/privacy.html">Privacy</a> ·{' '}
          <a href="mailto:divinejdavis@gmail.com">Contact</a>
        </span>
      </footer>
    </>
  );
}
