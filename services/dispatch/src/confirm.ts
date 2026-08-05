import type { SupabaseClient } from '@supabase/supabase-js';
import type { OrderService } from './orders.js';
import type { PaymentService } from './payments.js';
import { TERMINAL_STATUSES } from './deps.js';

export type ConfirmOutcome =
  | { outcome: 'no_intent' }
  | { outcome: 'unpaid'; paymentStatus: string }
  /** Charged, most likely, but the provider has not finished deciding. */
  | { outcome: 'processing'; paymentStatus: string }
  /** Paid, and nobody is coming. Its own outcome because it is the one result
   *  that must never leave the caller free to answer a bare ok. */
  | {
      outcome: 'dispatch_failed';
      paymentStatus: string;
      orderStatus: string;
      error: string;
      leg?: any;
    }
  | {
      outcome: 'confirmed';
      paymentStatus: string;
      orderStatus: string;
      dispatched: boolean;
      leg?: any;
    };

/**
 * Everything that must happen the moment a delivery fee is actually paid.
 *
 * Two things arrive here: the app, immediately after the payment sheet closes,
 * and the provider's webhook, for the phone that is killed in between. They
 * have to do exactly the same thing — an order whose money moved but whose
 * courier did not is invisible until the customer rings the shop about a bag
 * nobody came for — so they share this function rather than each having their
 * own idea of what "paid" leads to.
 *
 * Safe to call repeatedly. It is called repeatedly.
 */
export async function confirmAndDispatch(
  db: SupabaseClient,
  orders: OrderService,
  payments: PaymentService,
  orderId: string,
  log: { info: Function; warn: Function; error: Function },
): Promise<ConfirmOutcome> {
  // The app saying "paid" is a claim; the provider is the authority. Nothing
  // below this line runs on the client's word.
  const synced = await payments.syncDeliveryPayment(orderId);
  if (!synced) return { outcome: 'no_intent' };

  const paymentStatus: string = synced.row.status;
  if (!['authorized', 'captured'].includes(paymentStatus)) {
    // In flight is not the same as never started, and the column cannot tell
    // them apart. A payment the bank is still settling has usually taken the
    // money already; sending that customer back to the sheet charges them
    // twice. Leave the order alone and let the webhook finish it.
    if (synced.state.providerStatus === 'processing') {
      return { outcome: 'processing', paymentStatus: synced.state.providerStatus };
    }
    return { outcome: 'unpaid', paymentStatus };
  }

  const { data: order } = await db
    .from('orders')
    .select('status, service_tier')
    .eq('id', orderId)
    .single();
  if (!order) throw new Error(`order ${orderId} not found`);

  // Money landing on an order that has already ended is a refund problem, not
  // a dispatch one. Never send a courier for a bag nobody is expecting.
  if (['cancelled', 'delivered'].includes(order.status)) {
    return { outcome: 'confirmed', paymentStatus, orderStatus: order.status, dispatched: false };
  }

  // Only ever promote out of 'draft'. Both entry points can land at once, and
  // the loser of that race must not walk a moving order backwards.
  if (order.status === 'draft') {
    await db.from('orders').update({ status: 'scheduled' }).eq('id', orderId);
  }
  const orderStatus = order.status === 'draft' ? 'scheduled' : order.status;

  // return_only is paid for and going nowhere by courier: the customer carries
  // the bag in themselves. Jumping it to 'at_cleaner' here would tell them
  // their items are being counted while the bag is still in their hallway, and
  // it would spend the one honest arrival event the tier has — the shop's own
  // intake, which is the only proof the clothes ever turned up.
  const tier: string = order.service_tier ?? 'round_trip';
  if (tier === 'return_only') {
    return { outcome: 'confirmed', paymentStatus, orderStatus, dispatched: false };
  }

  // dispatchLeg refuses to duplicate a leg it can see, but it is reached here
  // by two callers that can arrive seconds apart, and a duplicate courier is
  // real money the moment Uber is live. Check for any pickup at all first: a
  // retry of one that failed belongs to the portal's retry button, which a
  // person is looking at, not to an app replaying a dropped response.
  const { data: existingLeg } = await db
    .from('delivery_legs')
    .select('*')
    .eq('order_id', orderId)
    .eq('leg', 'pickup')
    .order('attempt', { ascending: false })
    .limit(1)
    .maybeSingle();

  if (existingLeg) {
    // A leg that ended without delivering is not a courier on the way. The
    // retry still belongs to the portal's button, but answering 'confirmed'
    // here would make a stranded order look fine on the second call when it
    // looked broken on the first.
    if (TERMINAL_STATUSES.includes(existingLeg.status) && existingLeg.status !== 'delivered') {
      return {
        outcome: 'dispatch_failed',
        paymentStatus,
        orderStatus,
        error: existingLeg.last_error ?? 'no courier was assigned to this pickup',
        leg: existingLeg,
      };
    }
    return { outcome: 'confirmed', paymentStatus, orderStatus, dispatched: false, leg: existingLeg };
  }

  let leg: any;
  try {
    leg = await orders.dispatchLeg(orderId, 'pickup');
  } catch (err) {
    // The charge is real whether or not a courier accepted, so this cannot
    // throw: the order has to exist for the customer to see and cancel. It must
    // not read as a booking either — dispatchLeg has by now written a terminal
    // failed leg and put the order in 'failed', and no coverage is the routine
    // answer once Uber Direct is live (outside the zone, outside hours,
    // oversize). Paid-and-nobody-is-coming gets its own outcome so no caller
    // can report it as a success.
    log.error({ err, orderId }, 'pickup dispatch failed after payment');
    const { data: stranded } = await db
      .from('orders')
      .select('status')
      .eq('id', orderId)
      .maybeSingle();
    return {
      outcome: 'dispatch_failed',
      paymentStatus,
      orderStatus: stranded?.status ?? orderStatus,
      error: (err as Error).message,
    };
  }

  // dispatchLeg cascades the leg's own status onto the order, so the truthful
  // answer is whatever is on the row now, not what we set a moment ago.
  const { data: after } = await db
    .from('orders')
    .select('status')
    .eq('id', orderId)
    .maybeSingle();

  return {
    outcome: 'confirmed',
    paymentStatus,
    orderStatus: after?.status ?? orderStatus,
    dispatched: true,
    leg,
  };
}
