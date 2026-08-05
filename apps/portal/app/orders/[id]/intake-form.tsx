'use client';

import { useActionState, useMemo, useState } from 'react';
import { saveIntake } from '@/app/actions';
import { money } from '@/lib/status';
import { billableUnits, lineTotalCents, subtotalCents } from '@/lib/pricing';
import { readyHoursFor, readyRangeLabel } from '@/lib/ready';

type Service = {
  id: string;
  label: string;
  unit_price_cents: number;
  unit: 'piece' | 'pound';
  minimum_units: number;
  turnaround_hours: number | null;
};

/**
 * The counting screen.
 *
 * The total updates as the counter types, because the number the customer
 * gets charged is decided here and the person entering it should see the
 * consequence before they commit. The estimate is shown alongside so an
 * unusually large gap is obvious in the moment rather than in a dispute.
 *
 * The count decides the ready time too, so that moves with the boxes as well.
 * A wash & fold line pulls the shop's 48-hour default down to two hours, and
 * the counter should watch that happen rather than learn about it from a
 * customer who was promised the afternoon.
 */
export function IntakeForm({
  orderId,
  services,
  initial,
  estimateCents,
  thresholdCents,
  notes,
  shopTurnaroundHours,
  arrivedAtMs,
}: {
  orderId: string;
  services: Service[];
  initial: Record<string, number>;
  estimateCents: number;
  thresholdCents: number;
  notes: string | null;
  shopTurnaroundHours: number;
  arrivedAtMs: number;
}) {
  const [qty, setQty] = useState<Record<string, number>>(initial);
  const [state, action, pending] = useActionState(saveIntake.bind(null, orderId), null);

  const subtotal = useMemo(
    () => subtotalCents(services.map((s) => ({ item: s, entered: qty[s.id] ?? 0 }))),
    [qty, services],
  );

  const overBy = subtotal - estimateCents;
  const willNeedApproval = overBy > thresholdCents;
  const byWeight = services.some((s) => s.unit === 'pound');
  const count = services.reduce((n, s) => n + (qty[s.id] ?? 0), 0);

  // Only the lines with something in them: a service the counter left blank is
  // not in the bag, and letting a dry cleaning row nobody counted set the pace
  // would quote three days for a load of laundry.
  //
  // Measured from when the bag arrived, which is what the save writes and what
  // the customer's app is already showing. Counting a bag that has sat on the
  // rack since this morning does not buy it another two days.
  const readyPreview = useMemo(() => {
    const hours = readyHoursFor(
      services.filter((s) => (qty[s.id] ?? 0) > 0),
      shopTurnaroundHours,
    );
    return readyRangeLabel(new Date(arrivedAtMs + hours * 3600_000));
  }, [qty, services, shopTurnaroundHours, arrivedAtMs]);

  return (
    <form action={action} className="card">
      {state?.error && <div className="notice danger">{state.error}</div>}

      {/* Saving leaves the form on screen, so without this the counter cannot
          tell a save that went through from one that did nothing. The money
          line is spelled out because the alternative — silence — is what let a
          transport-only order read as a payment problem. */}
      {state?.ok && (
        <div className={`notice ${state.needsApproval ? 'warn' : 'ok'}`}>
          {state.needsApproval
            ? 'Saved and held. The customer has been asked to approve this total before you start.'
            : (state.paymentNote ?? 'Saved. Start cleaning.')}
          {/* The saved estimate, not the previewed one. This is the number the
              customer is now looking at, and the counter should read it here
              rather than from the customer over the phone. */}
          {state.readyAt && ` Their app now says ready by ${readyRangeLabel(state.readyAt)}.`}
        </div>
      )}

      <div className="intake">
        {services.map((s) => {
          const entered = qty[s.id] ?? 0;
          const charged = billableUnits(s, entered);
          // Say so when the weight minimum is doing the work. A counter who
          // types 12 and sees a 15 lb charge should know why before the
          // customer asks.
          const lifted = charged > entered;
          return (
            <div className="intake-row" key={s.id}>
              <label htmlFor={`qty_${s.id}`} style={{ marginBottom: 0 }}>
                {s.label}
                <span style={{ fontWeight: 400, color: 'var(--muted)' }}>
                  {' '}
                  · {money(s.unit_price_cents)}
                  {s.unit === 'pound' ? ' / lb' : ' each'}
                  {lifted && ` · ${Number(s.minimum_units)} lb minimum`}
                </span>
              </label>
              <input
                id={`qty_${s.id}`}
                name={`qty_${s.id}`}
                type="number"
                min={0}
                max={s.unit === 'pound' ? 200 : 99}
                // A scale reads 17.4. Stepping by whole numbers would make the
                // counter round, and rounding down is money the shop loses.
                step={s.unit === 'pound' ? 0.1 : 1}
                inputMode="decimal"
                value={entered || ''}
                placeholder="0"
                onChange={(e) =>
                  setQty((q) => ({ ...q, [s.id]: Math.max(0, Number(e.target.value) || 0) }))
                }
              />
              <span className="line-total">
                {entered ? money(lineTotalCents(s, entered)) : ''}
              </span>
            </div>
          );
        })}
      </div>

      {/* Not a field the counter fills in: the services carry their own
          turnaround, so what is in the bag already answers this. Shown anyway
          because it is the half of the save that reaches the customer without
          anyone saying it out loud. */}
      <div className="field" style={{ marginTop: 20 }}>
        <label>Ready by</label>
        <div style={{ fontWeight: 600 }}>{readyPreview}</div>
        <p style={{ fontSize: 13, color: 'var(--muted)', marginTop: 6, marginBottom: 0 }}>
          Worked out from what you counted — the slowest service in the bag sets
          it. Saving fixes this time and shows it to the customer. They only get
          asked to pick a delivery time once you mark the order ready.
        </p>
      </div>

      <div className="field">
        <label htmlFor="cleaner_notes">Notes for the customer</label>
        <textarea
          id="cleaner_notes"
          name="cleaner_notes"
          rows={2}
          defaultValue={notes ?? ''}
          placeholder="Stain on the left cuff — treating it, may not lift fully."
        />
      </div>

      <div className="totals">
        <div>
          <span style={{ color: 'var(--muted)' }}>Customer estimate</span>
          <span>{money(estimateCents)}</span>
        </div>
        <div>
          <span style={{ color: 'var(--muted)' }}>
            Counted
            {count > 0 &&
              (byWeight
                ? ` · ${count.toFixed(1)} lb`
                : ` · ${count} garment${count === 1 ? '' : 's'}`)}
          </span>
          <span>{money(subtotal)}</span>
        </div>
        <div className="grand">
          <span>Total</span>
          <span>{money(subtotal)}</span>
        </div>
      </div>

      {willNeedApproval && (
        <div className="notice warn" style={{ marginTop: 16 }}>
          This is {money(overBy)} over the estimate. Saving will hold the order and ask the
          customer to approve before you start cleaning.
        </div>
      )}

      <div className="row-actions">
        <button className="primary" type="submit" disabled={pending || count === 0}>
          {pending ? 'Saving…' : willNeedApproval ? 'Save and ask customer' : 'Save and start cleaning'}
        </button>
      </div>
    </form>
  );
}
