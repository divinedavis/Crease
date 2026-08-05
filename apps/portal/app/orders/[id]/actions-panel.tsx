'use client';

import { useState, useTransition } from 'react';
import { markCollected, markReady, requestReturnCourier, retryPickupCourier } from '@/app/actions';

/**
 * The irreversible buttons on this screen.
 *
 * "Send it back" spends money — it books a courier — so it is never the
 * default-styled button next to a harmless one, and it reports the carrier's
 * refusal verbatim instead of a generic failure. A shop that does not know
 * *why* dispatch failed will just press it again.
 *
 * The tier decides which ending an order has, so it is passed in rather than
 * inferred from status: 'ready' looks identical on an order a courier collects
 * and on one the customer walks in for.
 */
export function ActionsPanel({
  orderId,
  status,
  serviceTier,
  hasReturnWindow,
}: {
  orderId: string;
  status: string;
  serviceTier: string;
  hasReturnWindow: boolean;
}) {
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);

  function run(fn: () => Promise<{ error?: string } | undefined>) {
    setError(null);
    startTransition(async () => {
      const res = await fn();
      if (res?.error) setError(res.error);
    });
  }

  const pickupOnly = serviceTier === 'pickup_only';

  const canMarkReady = ['cleaning', 'awaiting_approval'].includes(status);
  // Only once the customer has chosen a window. Before that the shop pressing
  // this would summon a courier at a time nobody agreed to.
  const canSendBack = !pickupOnly && status === 'ready' && hasReturnWindow;
  const canMarkCollected = pickupOnly && status === 'ready';
  // 'scheduled' is the ordinary case, not the exception: dispatch normally
  // happens the moment the customer pays, so an order still sitting here is
  // one nothing has sent a courier for. A return-only order has no leg 1 at
  // all and must never get this button.
  const canDispatchPickup = serviceTier !== 'return_only' && ['scheduled', 'failed'].includes(status);

  if (!canMarkReady && !canSendBack && !canMarkCollected && !canDispatchPickup) return null;

  return (
    <div className="card" style={{ marginTop: 20 }}>
      {error && <div className="notice danger">{error}</div>}

      {canMarkReady && (
        <p style={{ marginTop: 0, color: 'var(--muted)', fontSize: 14 }}>
          Marking this ready tells the customer their clothes are done and lets them choose a
          delivery time. Only press it when the order is actually finished — this is the message
          they act on.
        </p>
      )}

      {!pickupOnly && status === 'ready' && !hasReturnWindow && (
        <p style={{ marginTop: 0, color: 'var(--muted)', fontSize: 14 }}>
          Waiting on the customer to choose a delivery time. You'll be able to book a courier
          once they have.
        </p>
      )}

      {canSendBack && (
        <p style={{ marginTop: 0, color: 'var(--muted)', fontSize: 14 }}>
          Books a courier to collect from your counter now. Have the bag tagged and on the rack
          before you press this.
        </p>
      )}

      {canMarkCollected && (
        <p style={{ marginTop: 0, color: 'var(--muted)', fontSize: 14 }}>
          The customer collects this one themselves — they only paid for the pickup. Press this
          when they have the bag in their hand, and the order is closed.
        </p>
      )}

      {canDispatchPickup && (
        <p style={{ marginTop: 0, color: 'var(--muted)', fontSize: 14 }}>
          {status === 'failed'
            ? 'The last attempt at leg 1 failed. This books another courier to the customer.'
            : 'Paid, but no courier has been booked to collect from the customer yet. This books one now.'}
        </p>
      )}

      <div className="row-actions" style={{ marginTop: 0 }}>
        {canMarkReady && (
          <button type="button" disabled={pending} onClick={() => run(() => markReady(orderId))}>
            {pending ? 'Working…' : 'Mark ready — tell the customer'}
          </button>
        )}
        {canSendBack && (
          <button
            type="button"
            className="primary"
            disabled={pending}
            onClick={() => run(() => requestReturnCourier(orderId))}
          >
            {pending ? 'Booking courier…' : 'Send it back'}
          </button>
        )}
        {canMarkCollected && (
          <button
            type="button"
            className="primary"
            disabled={pending}
            onClick={() => run(() => markCollected(orderId))}
          >
            {pending ? 'Closing…' : 'Customer collected'}
          </button>
        )}
        {canDispatchPickup && (
          <button
            type="button"
            disabled={pending}
            onClick={() => run(() => retryPickupCourier(orderId))}
          >
            {pending
              ? 'Booking courier…'
              : status === 'failed'
                ? 'Try the pickup courier again'
                : 'Send the courier'}
          </button>
        )}
      </div>
    </div>
  );
}
