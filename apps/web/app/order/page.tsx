import { OrderForm } from './order-form';
import { serviceClient } from '@/lib/supabase';

export const metadata = { title: 'Book a pickup — Crease' };

// Signing a shop is exactly the event that changes this page, so it must not
// be baked at build time. Five minutes is short enough that a new partner
// shows up the same afternoon and long enough that the list is not re-read on
// every visit.
export const revalidate = 300;

/**
 * Ordering from a browser, before the browser can place a real order.
 *
 * A row in `orders` belongs to an authenticated customer — customer_id is
 * auth.uid(), and every policy on it turns on that — so a true self-serve web
 * checkout needs accounts, sign-in and a Stripe Element before it can take a
 * penny. This takes the request instead: everything needed to place the order
 * on somebody's behalf, from a form that costs them twenty seconds and no
 * password.
 *
 * It is also the better instrument. A name, a phone number and a street is a
 * person who wants a pickup on Tuesday; an email on a waitlist is a person who
 * once read a page.
 */
export default async function OrderPage() {
  const db = serviceClient();
  const { data: shops } = db
    ? await db.from('cleaners').select('id, name, line1').eq('active', true).order('name')
    : { data: [] };

  return (
    <>
      <header className="wrap">
        <div className="brand">
          {/* eslint-disable-next-line @next/next/no-img-element */}
          <img src="/assets/icon.svg" alt="" width={40} height={40} />
          <a href="/" style={{ color: 'inherit', textDecoration: 'none' }}>
            Crease
          </a>
        </div>
      </header>

      <main className="wrap">
        <section className="hero" style={{ paddingBottom: 32 }}>
          <div className="hero-copy">
            <h1>Book a pickup.</h1>
            <p className="lede">
              Tell us where you are and roughly what you&rsquo;re sending. We confirm by text, a
              courier collects, and your neighborhood cleaner prices exactly what&rsquo;s in the
              bag — you approve the total before anything is charged.
            </p>
            <OrderForm shops={shops ?? []} />
          </div>
        </section>
      </main>

      <footer className="wrap">
        <span>© 2026 Crease</span>
        <span>
          <a href="/">Home</a> · <a href="/privacy.html">Privacy</a> ·{' '}
          <a href="mailto:divinejdavis@gmail.com">Contact</a>
        </span>
      </footer>
    </>
  );
}
