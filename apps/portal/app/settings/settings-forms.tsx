'use client';

import { useActionState, useEffect, useRef } from 'react';
import { DAY_NAMES, type DayHours } from '@/lib/hours';
import {
  saveShopDetails,
  saveHours,
  startPayoutOnboarding,
  refreshPayoutStatus,
  saveServiceItem,
  addServiceItem,
} from './actions';
import { SERVICE_TYPES, SERVICE_TYPE_LABEL, priceLine } from '@/lib/price-list';

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
            <div className="field" key={day} style={{ display: 'flex', flexWrap: 'wrap', gap: 12, alignItems: 'center' }}>
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

export type PriceListItem = {
  id: string;
  label: string;
  service_type: string;
  unit: string;
  unit_price_cents: number;
  minimum_units: number | string;
  turnaround_hours: number | null;
  active: boolean;
};

/**
 * The fields one price-list line is made of. Shared by the edit rows and the
 * add form so the two can never ask for different things.
 */
function ServiceFields({ item, idPrefix }: { item?: PriceListItem; idPrefix: string }) {
  const id = (name: string) => `${idPrefix}_${name}`;
  const minimum = Number(item?.minimum_units ?? 0);
  return (
    <div className="price-fields">
      <div className="field wide">
        <label htmlFor={id('label')}>Name</label>
        <input id={id('label')} name="label" defaultValue={item?.label ?? ''} maxLength={60} required
          placeholder="Wash & fold" />
      </div>
      <div className="field">
        <label htmlFor={id('service_type')}>Kind</label>
        <select id={id('service_type')} name="service_type" defaultValue={item?.service_type ?? 'wash_fold'}>
          {SERVICE_TYPES.map((t) => (
            <option key={t} value={t}>{SERVICE_TYPE_LABEL[t]}</option>
          ))}
        </select>
      </div>
      <div className="field">
        <label htmlFor={id('unit')}>Charged</label>
        <select id={id('unit')} name="unit" defaultValue={item?.unit ?? 'pound'}>
          <option value="pound">Per pound</option>
          <option value="piece">Per item</option>
        </select>
      </div>
      <div className="field">
        <label htmlFor={id('price')}>Price ($)</label>
        <input id={id('price')} name="price" inputMode="decimal" required placeholder="2.00"
          defaultValue={item ? (item.unit_price_cents / 100).toFixed(2) : ''} />
      </div>
      <div className="field">
        <label htmlFor={id('minimum')}>Minimum (lb)</label>
        <input id={id('minimum')} name="minimum" inputMode="decimal" placeholder="none"
          defaultValue={minimum > 0 ? String(minimum) : ''} />
      </div>
      <div className="field">
        <label htmlFor={id('turnaround_hours')}>Ready in (hours)</label>
        <input id={id('turnaround_hours')} name="turnaround_hours" inputMode="numeric"
          placeholder="shop default" defaultValue={item?.turnaround_hours ?? ''} />
      </div>
      <label className="offered">
        <input type="checkbox" name="active" defaultChecked={item ? item.active : true} /> Offered to customers
      </label>
    </div>
  );
}

function ServiceItemRow({ cleanerId, item }: { cleanerId: string; item: PriceListItem }) {
  const [state, action, pending] = useActionState(saveServiceItem.bind(null, cleanerId, item.id), null);
  return (
    <form action={action} className={`price-row${item.active ? '' : ' off'}`}>
      <div className="price-head">
        <strong>{item.label}</strong>
        <span className="sub">
          {item.active ? priceLine(item) : `Not offered · last price ${priceLine(item)} — check it before switching on`}
        </span>
      </div>
      <Feedback state={state} saved="Saved. The app quotes this from the next booking." />
      <ServiceFields item={item} idPrefix={item.id} />
      <button type="submit" disabled={pending}>{pending ? 'Saving…' : 'Save'}</button>
    </form>
  );
}

function AddServiceForm({ cleanerId }: { cleanerId: string }) {
  const [state, action, pending] = useActionState(addServiceItem.bind(null, cleanerId), null);
  const form = useRef<HTMLFormElement>(null);
  useEffect(() => {
    if (state?.ok) form.current?.reset();
  }, [state]);
  return (
    <form action={action} ref={form} className="price-row add">
      <div className="price-head"><strong>Add a service</strong></div>
      <Feedback state={state} saved="Added. Customers can book it from the next order." />
      <ServiceFields idPrefix="new" />
      <button className="primary" type="submit" disabled={pending}>{pending ? 'Adding…' : 'Add service'}</button>
    </form>
  );
}

export function PriceList({ cleanerId, items }: { cleanerId: string; items: PriceListItem[] }) {
  const byType = SERVICE_TYPES.map((t) => ({ type: t, rows: items.filter((i) => i.service_type === t) }))
    .filter((g) => g.rows.length > 0);
  return (
    <section className="group">
      <h2>Prices &amp; services</h2>
      <div className="card">
        <p className="sub" style={{ marginTop: 0 }}>
          What customers see and are quoted in the app. Laundry can be per pound with a minimum
          weight; dry cleaning and pressing are per item. Changes apply to new bookings only —
          orders already placed keep the price they were booked at.
        </p>
        {byType.map((g) => (
          <div key={g.type} className="price-group">
            <h3>{SERVICE_TYPE_LABEL[g.type]}</h3>
            {g.rows.map((item) => (
              <ServiceItemRow key={item.id} cleanerId={cleanerId} item={item} />
            ))}
          </div>
        ))}
        <AddServiceForm cleanerId={cleanerId} />
      </div>
    </section>
  );
}
