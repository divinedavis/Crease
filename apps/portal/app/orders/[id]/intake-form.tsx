'use client';

import { useActionState, useMemo, useState } from 'react';
import { saveIntake } from '@/app/actions';
import { money } from '@/lib/status';

type Service = { id: string; label: string; unit_price_cents: number };

/**
 * The counting screen.
 *
 * The total updates as the counter types, because the number the customer
 * gets charged is decided here and the person entering it should see the
 * consequence before they commit. The estimate is shown alongside so an
 * unusually large gap is obvious in the moment rather than in a dispute.
 */
export function IntakeForm({
  orderId,
  services,
  initial,
  estimateCents,
  thresholdCents,
  notes,
}: {
  orderId: string;
  services: Service[];
  initial: Record<string, number>;
  estimateCents: number;
  thresholdCents: number;
  notes: string | null;
}) {
  const [qty, setQty] = useState<Record<string, number>>(initial);
  const [state, action, pending] = useActionState(saveIntake.bind(null, orderId), null);

  const subtotal = useMemo(
    () =>
      services.reduce((sum, s) => sum + (qty[s.id] ?? 0) * s.unit_price_cents, 0),
    [qty, services],
  );

  const overBy = subtotal - estimateCents;
  const willNeedApproval = overBy > thresholdCents;
  const count = Object.values(qty).reduce((n, q) => n + q, 0);

  return (
    <form action={action} className="card">
      {state?.error && <div className="notice danger">{state.error}</div>}

      <div className="intake">
        {services.map((s) => (
          <div className="intake-row" key={s.id}>
            <label htmlFor={`qty_${s.id}`} style={{ marginBottom: 0 }}>
              {s.label}
              <span style={{ fontWeight: 400, color: 'var(--muted)' }}>
                {' '}
                · {money(s.unit_price_cents)}
              </span>
            </label>
            <input
              id={`qty_${s.id}`}
              name={`qty_${s.id}`}
              type="number"
              min={0}
              max={99}
              inputMode="numeric"
              value={qty[s.id] ?? 0}
              onChange={(e) =>
                setQty((q) => ({ ...q, [s.id]: Math.max(0, Number(e.target.value) || 0) }))
              }
            />
            <span className="line-total">
              {qty[s.id] ? money(qty[s.id] * s.unit_price_cents) : ''}
            </span>
          </div>
        ))}
      </div>

      <div className="field" style={{ marginTop: 20 }}>
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
            Counted{count > 0 && ` · ${count} garment${count === 1 ? '' : 's'}`}
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
