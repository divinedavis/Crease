'use client';

import { useState, useTransition } from 'react';
import { confirmReturnOrder } from '@/app/actions';

/**
 * The counter's whole job on a return.
 *
 * There are no garments to count: the customer already paid for this cleaning
 * — at the counter, or on an earlier order they meant to collect themselves —
 * and all they have bought here is the trip home. So the shop is asked the one
 * question it can answer, rather than being handed a price list for work it
 * has already been paid for.
 */
export function ConfirmReturn({ orderId, shortCode }: { orderId: string; shortCode: string }) {
  const [pending, start] = useTransition();
  const [error, setError] = useState<string | null>(null);

  return (
    <div className="card">
      <p>
        This customer says their order is already here. Check the rack, then confirm — it
        tells them their clothes are ready and lets them book a delivery time.
      </p>
      {error && <div className="notice danger">{error}</div>}
      <button
        type="button"
        disabled={pending}
        onClick={() =>
          start(async () => {
            setError(null);
            const result = await confirmReturnOrder(orderId);
            if (result?.error) setError(result.error);
          })
        }
      >
        {pending ? 'Confirming…' : `Confirm ${shortCode} is here and finished`}
      </button>
    </div>
  );
}
