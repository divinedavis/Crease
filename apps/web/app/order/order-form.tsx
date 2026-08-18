'use client';

import { useActionState } from 'react';
import { requestPickup, type RequestResult } from '../actions';

export interface ShopOption {
  id: string;
  name: string;
  line1: string | null;
}

const TIERS = [
  { id: 'round_trip', label: 'Round trip — we collect and deliver back', price: '$29.95' },
  { id: 'pickup_only', label: 'Pickup only — we collect, you fetch it', price: '$16.95' },
  { id: 'return_only', label: "Return only — it's already at the shop", price: '$16.95' },
];

const SERVICES = [
  { id: 'dry_clean', label: 'Dry cleaning' },
  { id: 'wash_fold', label: 'Wash & fold' },
  { id: 'press', label: 'Press only' },
];

export function OrderForm({ shops }: { shops: ShopOption[] }) {
  const [state, submit, sending] = useActionState<RequestResult | null, FormData>(
    requestPickup,
    null,
  );

  if (state?.ok) {
    return (
      <div className="answer yes">
        <h3>Got it — we&rsquo;ll text you shortly</h3>
        <p>{state.message}</p>
        <p className="fine">
          Nothing is charged now. The price is confirmed with you before a courier is booked.
        </p>
      </div>
    );
  }

  return (
    <form action={submit} className="check" style={{ display: 'grid', gap: 12 }}>
      {state && !state.ok && <div className="answer">{state.message}</div>}

      <input name="name" required autoComplete="name" placeholder="Your name" aria-label="Your name" />
      <input
        name="phone"
        required
        type="tel"
        autoComplete="tel"
        placeholder="Mobile number — we confirm by text"
        aria-label="Mobile number"
      />
      <input
        name="email"
        type="email"
        autoComplete="email"
        placeholder="Email (optional)"
        aria-label="Email, optional"
      />
      <input
        name="address"
        required
        autoComplete="street-address"
        placeholder="Pickup address in Brooklyn"
        aria-label="Pickup address"
      />
      <input
        name="address_notes"
        placeholder="Buzzer, floor, or where to leave it (optional)"
        aria-label="Access notes, optional"
      />

      <label className="fine" htmlFor="service_tier">
        What do you need?
      </label>
      <select id="service_tier" name="service_tier" defaultValue="round_trip" aria-label="Service tier">
        {TIERS.map((t) => (
          <option key={t.id} value={t.id}>
            {t.label} · {t.price}
          </option>
        ))}
      </select>

      <label className="fine" htmlFor="service_type">
        Which service?
      </label>
      <select id="service_type" name="service_type" defaultValue="dry_clean" aria-label="Service">
        {SERVICES.map((s) => (
          <option key={s.id} value={s.id}>
            {s.label}
          </option>
        ))}
      </select>

      {shops.length > 1 && (
        <>
          <label className="fine" htmlFor="cleaner_id">
            Preferred cleaner (optional — we&rsquo;ll pick the nearest otherwise)
          </label>
          <select id="cleaner_id" name="cleaner_id" defaultValue="" aria-label="Preferred cleaner">
            <option value="">Nearest to me</option>
            {shops.map((s) => (
              <option key={s.id} value={s.id}>
                {s.name}
                {s.line1 ? ` — ${s.line1}` : ''}
              </option>
            ))}
          </select>
        </>
      )}

      <input
        name="items_note"
        placeholder="Roughly what's in the bag — e.g. 2 shirts, a suit, one comforter"
        aria-label="What is in the bag"
      />
      <input
        name="preferred_when"
        placeholder="When suits you? e.g. tomorrow morning"
        aria-label="Preferred pickup time"
      />

      <button type="submit" disabled={sending}>
        {sending ? 'Sending…' : 'Request a pickup'}
      </button>
      <p className="fine">
        No account, no card. We confirm the price with you before a courier is booked.
      </p>
    </form>
  );
}
