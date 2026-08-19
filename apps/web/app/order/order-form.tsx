'use client';

import { useActionState } from 'react';
import { AddressField } from '../address-field';
import { requestPickup, type RequestResult } from '../actions';

const TIERS = [
  { id: 'round_trip', label: 'Round trip — we collect and deliver back', price: '$29.95' },
  { id: 'pickup_only', label: 'Pickup only — we collect, you fetch it', price: '$16.95' },
  { id: 'return_only', label: "Return only — it's already at the shop", price: '$16.95' },
];

// Only what a shop has actually priced. Dry cleaning returns as an option the
// day one gives a price list; offering it now would take an order nobody can
// quote.
const SERVICES = [{ id: 'wash_fold', label: 'Wash & fold — $2.00/lb, $20 minimum' }];

const TIER_IDS = new Set(TIERS.map((t) => t.id));
const SERVICE_IDS = new Set(SERVICES.map((s) => s.id));

export function OrderForm({
  initialTier = '',
  initialService = '',
  initialAddress = '',
  initialWhen = '',
}: {
  initialTier?: string;
  initialService?: string;
  initialAddress?: string;
  initialWhen?: string;
}) {
  // Validated, not trusted: these arrive in a URL anybody can edit, and an
  // unknown value would either select nothing or post a tier the dispatcher
  // has no price for.
  const tier = TIER_IDS.has(initialTier) ? initialTier : 'round_trip';
  const service = SERVICE_IDS.has(initialService) ? initialService : 'wash_fold';
  // A return carries no cleaning: the clothes are at the shop already and paid
  // for, so asking what is in the bag is asking about a bag that isn't there.
  const carriesCleaning = tier !== 'return_only';

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
      <AddressField
        placeholder="Pickup address in Brooklyn"
        defaultValue={initialAddress}
      />
      <input
        name="address_notes"
        placeholder="Buzzer, floor, or where to leave it (optional)"
        aria-label="Access notes, optional"
      />

      <label className="fine" htmlFor="service_tier">
        What do you need?
      </label>
      <select id="service_tier" name="service_tier" defaultValue={tier} aria-label="Service tier">
        {TIERS.map((t) => (
          <option key={t.id} value={t.id}>
            {t.label} · {t.price}
          </option>
        ))}
      </select>

      {/* One service, so a picker would be a control with nothing to choose. */}
      <input type="hidden" name="service_type" value={service} />

      {carriesCleaning && (
        <input
          name="items_note"
          placeholder="Roughly how much — e.g. two full kitchen bags, one comforter"
          aria-label="Roughly how much laundry"
        />
      )}
      <input
        name="preferred_when"
        defaultValue={initialWhen}
        placeholder="When suits you? e.g. tomorrow morning"
        aria-label="Preferred pickup time"
      />

      <button type="submit" disabled={sending}>
        {sending ? 'Sending…' : 'Request a pickup'}
      </button>
      <p className="fine">We confirm the price with you before a driver is booked.</p>
    </form>
  );
}
