'use client';

import { useActionState, useEffect, useState } from 'react';
import { AddressField } from './address-field';
import { quoteAddress, type Quote } from './actions';
import { TIERS } from '@/lib/tiers';

const money = (c: number) => `$${(c / 100).toFixed(2)}`;

function sessionRef(): string {
  if (typeof window === 'undefined') return '';
  const existing = window.localStorage.getItem('crease.session');
  if (existing) return existing;
  const made = Math.random().toString(36).slice(2) + Date.now().toString(36);
  window.localStorage.setItem('crease.session', made);
  return made;
}

/**
 * Address in, prices out — the one thing somebody landing here wants.
 *
 * Prices are shown only for an address we can actually serve. Quoting $29.95
 * to a street four miles from the nearest partner is a number we would have to
 * take back, and taking a number back is how a first order becomes the last.
 */
export function QuoteBox() {
  const [session, setSession] = useState('');
  useEffect(() => setSession(sessionRef()), []);
  const [when, setWhen] = useState<'now' | 'later'>('now');

  const [quote, ask, asking] = useActionState<Quote | null, FormData>(quoteAddress, null);

  return (
    <div className="quote">
      <div className="pillrow">
        <button
          type="button"
          className={when === 'now' ? 'pill on' : 'pill'}
          onClick={() => setWhen('now')}
        >
          Pickup now
        </button>
        <button
          type="button"
          className={when === 'later' ? 'pill on' : 'pill'}
          onClick={() => setWhen('later')}
        >
          Schedule
        </button>
      </div>

      <form action={ask}>
        <AddressField placeholder="Enter pickup address" />
        <div className="field muted">
          <span className="sq" aria-hidden="true" />
          <span className="dest">We collect, wash, fold and bring it back</span>
        </div>
        {when === 'later' && (
          <div className="field">
            <input
              name="preferred_when"
              placeholder="When suits you? e.g. tomorrow morning"
              aria-label="Preferred pickup time"
            />
          </div>
        )}
        <input type="hidden" name="session" value={session} />
        <button type="submit" className="cta" disabled={asking}>
          {asking ? 'Checking…' : 'See prices'}
        </button>
      </form>

      {quote && <Prices quote={quote} />}
    </div>
  );
}

function Prices({ quote }: { quote: Quote }) {
  if (quote.status !== 'covered') {
    return (
      <div className="answer">
        <h3>{quote.status === 'error' ? 'Try again' : 'Not yet'}</h3>
        <p>{quote.message}</p>
      </div>
    );
  }

  return (
    <div className="prices">
      <p className="fine">{quote.miles} miles from our Clinton Hill base</p>
      {TIERS.map((tier) => (
        <a
          key={tier.id}
          className="tier"
          href={`/order?tier=${tier.id}&address=${encodeURIComponent(quote.address ?? '')}`}
        >
          <span className="tier-name">
            <strong>{tier.name}</strong>
            <span>{tier.blurb}</span>
          </span>
          <span className="tier-price">
            <strong>{money(tier.priceCents)}</strong>
            {tier.etaMinutes && <span>driver ~{tier.etaMinutes} min</span>}
          </span>
        </a>
      ))}
      <p className="fine">
        Laundry is $2.00 a pound with a $20 minimum, added to this — you see the whole bill before
        you pay.
      </p>
    </div>
  );
}
