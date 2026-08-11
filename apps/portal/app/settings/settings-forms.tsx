'use client';

import { useActionState } from 'react';
import { DAY_NAMES, type DayHours } from '@/lib/hours';
import { saveShopDetails, saveHours, startPayoutOnboarding, refreshPayoutStatus } from './actions';

type ActionResult = { ok?: boolean; error?: string; relocated?: boolean } | null;

function Feedback({ state, saved }: { state: ActionResult; saved: string }) {
  if (!state) return null;
  if (state.error) return <div className="notice danger">{state.error}</div>;
  return <div className="notice ok">{saved}</div>;
}

export function ShopDetailsForm({
  shop,
}: {
  shop: {
    id: string;
    phone: string | null;
    email: string | null;
    line1: string;
    line2: string | null;
    city: string;
    state: string;
    postal_code: string;
    turnaround_hours: number;
  };
}) {
  const [state, action, pending] = useActionState(saveShopDetails.bind(null, shop.id), null);

  return (
    <section className="group">
      <h2>Shop details</h2>
      <form action={action} className="card">
        <Feedback
          state={state}
          saved={
            state?.relocated
              ? 'Saved. Couriers will be routed to the new address from the next order.'
              : 'Saved.'
          }
        />
        <div className="field">
          <label htmlFor="line1">Street address</label>
          <input id="line1" name="line1" defaultValue={shop.line1} required />
        </div>
        <div className="field">
          <label htmlFor="line2">Unit, floor, etc. (optional)</label>
          <input id="line2" name="line2" defaultValue={shop.line2 ?? ''} />
        </div>
        <div className="field">
          <label htmlFor="city">City</label>
          <input id="city" name="city" defaultValue={shop.city} required />
        </div>
        <div className="field">
          <label htmlFor="state">State</label>
          <input id="state" name="state" defaultValue={shop.state} maxLength={2} required />
        </div>
        <div className="field">
          <label htmlFor="postal_code">ZIP</label>
          <input id="postal_code" name="postal_code" defaultValue={shop.postal_code} required />
        </div>
        <div className="field">
          <label htmlFor="phone">Phone (shown to customers)</label>
          <input id="phone" name="phone" type="tel" defaultValue={shop.phone ?? ''} />
        </div>
        <div className="field">
          <label htmlFor="email">Email</label>
          <input id="email" name="email" type="email" defaultValue={shop.email ?? ''} />
        </div>
        <div className="field">
          <label htmlFor="turnaround_hours">Standard turnaround (hours)</label>
          <input
            id="turnaround_hours"
            name="turnaround_hours"
            type="number"
            min={1}
            max={336}
            defaultValue={shop.turnaround_hours}
            required
          />
        </div>
        <button className="primary" type="submit" disabled={pending}>
          {pending ? 'Saving…' : 'Save details'}
        </button>
      </form>
    </section>
  );
}

export function HoursForm({
  cleanerId,
  byDay,
}: {
  cleanerId: string;
  byDay: Record<number, DayHours>;
}) {
  const [state, action, pending] = useActionState(saveHours.bind(null, cleanerId), null);

  return (
    <section className="group">
      <h2>Opening hours</h2>
      <form action={action} className="card">
        <Feedback state={state} saved="Saved. Couriers will only be sent inside these windows." />
        <p className="sub" style={{ marginTop: 0 }}>
          Pickups and returns are only scheduled while you're open — a courier who arrives to a
          locked door sends the bag straight back.
        </p>
        {DAY_NAMES.map((day, dow) => {
          const row = byDay[dow];
          return (
            <div className="field" key={day} style={{ display: 'flex', gap: 12, alignItems: 'center' }}>
              <label style={{ width: 90, marginBottom: 0 }}>{day}</label>
              <input type="time" name={`open_${dow}`} defaultValue={row?.open ?? ''} />
              <span className="sub">to</span>
              <input type="time" name={`close_${dow}`} defaultValue={row?.close ?? ''} />
              <label style={{ marginBottom: 0, fontWeight: 400 }}>
                <input type="checkbox" name={`closed_${dow}`} defaultChecked={!row} /> Closed
              </label>
            </div>
          );
        })}
        <button className="primary" type="submit" disabled={pending}>
          {pending ? 'Saving…' : 'Save hours'}
        </button>
      </form>
    </section>
  );
}

export function PayoutPanel({
  cleanerId,
  hasAccount,
  payoutsEnabled,
}: {
  cleanerId: string;
  hasAccount: boolean;
  payoutsEnabled: boolean;
}) {
  const [startState, startAction, starting] = useActionState(
    () => startPayoutOnboarding(cleanerId),
    null,
  );
  const [refreshState, refreshAction, refreshing] = useActionState(
    () => refreshPayoutStatus(cleanerId),
    null,
  );
  const state = startState ?? refreshState;

  return (
    <section className="group">
      <h2>Payouts</h2>
      <div className="card">
        {state?.error && <div className="notice danger">{state.error}</div>}
        {payoutsEnabled ? (
          <p>
            <span className="pill ok">Payouts on</span>{' '}
            <span className="sub">
              Your share of every settled order is transferred to your bank automatically.
            </span>
          </p>
        ) : (
          <p className="sub" style={{ marginTop: 0 }}>
            {hasAccount
              ? 'Stripe still needs information before it can pay you. Finish onboarding, then check status.'
              : 'Connect a bank account through Stripe to get paid for cleaned orders. Takes about five minutes — have your bank details and EIN (or SSN for sole proprietors) ready.'}
          </p>
        )}
        <div className="row-actions">
          {!payoutsEnabled && (
            <form action={startAction}>
              <button className="primary" type="submit" disabled={starting}>
                {starting
                  ? 'Opening Stripe…'
                  : hasAccount
                    ? 'Finish Stripe onboarding'
                    : 'Set up payouts'}
              </button>
            </form>
          )}
          {hasAccount && (
            <form action={refreshAction}>
              <button type="submit" disabled={refreshing}>
                {refreshing ? 'Checking…' : 'Check status'}
              </button>
            </form>
          )}
        </div>
      </div>
    </section>
  );
}
