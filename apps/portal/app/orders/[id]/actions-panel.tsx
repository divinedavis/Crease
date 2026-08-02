'use client';

import { useState, useTransition } from 'react';
import { markReady, requestReturnCourier, retryPickupCourier } from '@/app/actions';

/**
 * The two irreversible buttons on this screen.
 *
 * "Send it back" spends money — it books a courier — so it is never the
 * default-styled button next to a harmless one, and it reports the carrier's
 * refusal verbatim instead of a generic failure. A shop that does not know
 * *why* dispatch failed will just press it again.
 */
export function ActionsPanel({
  orderId,
  status,
  hasReturnWindow,
}: {
  orderId: string;
  status: string;
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

  const canMarkReady = ['cleaning', 'awaiting_approval'].includes(status);
  // Only once the customer has chosen a window. Before that the shop pressing
  // this would summon a courier at a time nobody agreed to.
  const canSendBack = status === 'ready' && hasReturnWindow;
  const canRetryPickup = status === 'failed';

  if (!canMarkReady && !canSendBack && !canRetryPickup) return null;

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

      {status === 'ready' && !hasReturnWindow && (
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

      <div className="row-actions" style={{ marginTop: 0 }}>
        {canMarkReady && (
          <button type="button" disabled={pending} onClick={() => run(() => markReady(orderId))}>
            {pending ? 'Working…' : 'Mark ready — tell the customer'}
          </button>
        )}
        {status === 'ready' && !hasReturnWindow && (
        <p style={{ marginTop: 0, color: 'var(--muted)', fontSize: 14 }}>
          Waiting on the customer to choose a delivery time. You'll be able to book a courier
          once they have.
        </p>
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
        {canRetryPickup && (
          <button
            type="button"
            disabled={pending}
            onClick={() => run(() => retryPickupCourier(orderId))}
          >
            {pending ? 'Retrying…' : 'Retry pickup courier'}
          </button>
        )}
      </div>
    </div>
  );
}
