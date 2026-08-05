import type { FastifyInstance } from 'fastify';
import type { SupabaseClient } from '@supabase/supabase-js';
import type { OrderService } from './orders.js';
import type { PaymentService } from './payments.js';
import { confirmAndDispatch } from './confirm.js';
import { config } from './config.js';

/**
 * When a customer may still call an order off themselves.
 *
 * 'failed' is in the list because a courier that could never be booked leaves a
 * paid order nobody is coming for. Without it the only route back to their own
 * money is a phone call to a shop that never saw the bag.
 */
const CANCELLABLE_STATUSES = ['draft', 'scheduled', 'pickup_dispatched', 'failed'];

/** How far ahead a delivery window may be booked. Long enough for a week away,
 *  short enough that a mistyped year cannot park a courier in 2036. */
const RETURN_WINDOW_HORIZON_DAYS = 30;

/**
 * The customer's chosen delivery window, or the reason it is not one.
 *
 * Checked rather than trusted: this is the one field the app hands us that goes
 * straight to a carrier as a dispatch time. A window that has already closed
 * quotes as "send someone now", and a far-future one holds an order open
 * indefinitely against a quote that expired months earlier.
 */
function returnWindow(
  start?: string,
  end?: string,
): { start: string; end: string } | { error: string } {
  if (!start || !end) return { error: 'A delivery window needs both a start and an end time.' };

  const from = Date.parse(start);
  const to = Date.parse(end);
  if (Number.isNaN(from) || Number.isNaN(to)) return { error: 'That delivery time is not a date.' };
  if (from >= to) return { error: 'A delivery window has to end after it starts.' };

  // The end, not the start: "as soon as possible" legitimately opens a minute
  // ago, but a window that has already closed is not a time anyone can be sent.
  const now = Date.now();
  if (to <= now) return { error: 'That delivery time has already passed.' };
  if (from > now + RETURN_WINDOW_HORIZON_DAYS * 24 * 60 * 60 * 1000) {
    return { error: `Deliveries can be booked up to ${RETURN_WINDOW_HORIZON_DAYS} days ahead.` };
  }

  return { start: new Date(from).toISOString(), end: new Date(to).toISOString() };
}

/**
 * Endpoints the customer app is allowed to call.
 *
 * Everything under /v1/ is loopback-only and guarded by a shared secret,
 * because it can dispatch couriers and move money. A phone must never hold
 * that secret: an IPA is a zip file, and anything in Info.plist or the binary
 * belongs to whoever downloads the app.
 *
 * So these routes authenticate with the customer's own Supabase access token
 * — the same credential the app already holds to read its orders — and every
 * one of them re-checks that the order belongs to the caller. A stolen token
 * gets you your own orders and nothing else, and revoking it revokes this too.
 */
export function registerCustomerRoutes(
  app: FastifyInstance,
  db: SupabaseClient,
  orders: OrderService,
  payments: PaymentService,
) {
  /**
   * Resolve the bearer token to a user id.
   *
   * Asks Supabase rather than verifying the signature locally: it needs no
   * extra secret on this box, and it honours revocation and expiry that a
   * local signature check would happily ignore.
   */
  async function userIdFrom(req: any): Promise<string | null> {
    const header = String(req.headers.authorization ?? '');
    const token = header.startsWith('Bearer ') ? header.slice(7) : '';
    if (!token) return null;

    try {
      const res = await fetch(`${config.supabaseUrl}/auth/v1/user`, {
        headers: {
          apikey: config.supabaseAnonKey,
          authorization: `Bearer ${token}`,
        },
      });
      if (!res.ok) return null;
      const user: any = await res.json();
      return typeof user?.id === 'string' ? user.id : null;
    } catch {
      return null;
    }
  }

  /** The caller must own the order. Checked per request, never assumed. */
  async function ownedOrder(req: any, reply: any): Promise<any | null> {
    const userId = await userIdFrom(req);
    if (!userId) {
      reply.code(401).send({ ok: false, error: 'Please sign in again.' });
      return null;
    }
    const { data: order } = await db
      .from('orders')
      .select('id, customer_id, status, delivery_fee_cents, return_window_start')
      .eq('id', req.params.id)
      .maybeSingle();

    // Same answer for "does not exist" and "not yours", so this cannot be
    // used to discover which order ids are real.
    if (!order || order.customer_id !== userId) {
      reply.code(404).send({ ok: false, error: 'Order not found.' });
      return null;
    }
    return order;
  }

  app.post<{ Params: { id: string } }>('/v1/me/orders/:id/payment-intent', async (req, reply) => {
    const order = await ownedOrder(req, reply);
    if (!order) return;

    // Only a draft can be armed for payment. Anything further along has either
    // been paid for or has ended, and both of those already own a charge —
    // arming a cancelled-and-refunded order mints a second live intent against
    // it and overwrites the reference to the charge that was given back.
    if (order.status !== 'draft') {
      return reply.code(409).send({ ok: false, error: 'This order is no longer awaiting payment.' });
    }

    try {
      const result = await payments.createDeliveryPaymentIntent(req.params.id);
      return { ok: true, ...result, publishableKey: config.stripePublishableKey };
    } catch (err) {
      req.log.error({ err, orderId: req.params.id }, 'customer payment intent failed');
      return reply.code(402).send({ ok: false, error: (err as Error).message });
    }
  });

  /**
   * The app calls this the moment the payment sheet reports success.
   *
   * This is the only thing that turns a paid order into a moving one — there
   * is no scheduler behind it — so it re-reads the intent from the provider
   * and dispatches in the same breath. Retrying it is expected and cheap; the
   * shared path underneath refuses to send a second courier.
   */
  app.post<{ Params: { id: string } }>('/v1/me/orders/:id/confirm-payment', async (req, reply) => {
    const order = await ownedOrder(req, reply);
    if (!order) return;

    let result;
    try {
      result = await confirmAndDispatch(db, orders, payments, req.params.id, req.log);
    } catch (err) {
      req.log.error({ err, orderId: req.params.id }, 'confirm payment failed');
      return reply.code(502).send({ ok: false, error: (err as Error).message });
    }

    if (result.outcome === 'no_intent') {
      return reply.code(409).send({ ok: false, error: 'No payment has been started for this order.' });
    }
    // Nothing is wrong and nothing is booked yet: the bank still has the
    // payment, and the webhook dispatches when it lands. Answering an error
    // here would send a customer whose card is already charged back to the
    // sheet for a second go.
    if (result.outcome === 'processing') {
      return { ok: true, outcome: result.outcome, dispatched: false, paymentStatus: result.paymentStatus };
    }
    if (result.outcome === 'unpaid') {
      return reply.code(402).send({
        ok: false,
        error: 'Your payment has not completed. Please try again.',
        paymentStatus: result.paymentStatus,
      });
    }
    // Paid, and no courier is coming. Reported as a booking this is the failure
    // that leaves someone waiting in all afternoon for nobody; the order is
    // cancellable from here precisely so they can take their money back.
    if (result.outcome === 'dispatch_failed') {
      req.log.error(
        { orderId: req.params.id, reason: result.error, orderStatus: result.orderStatus },
        'paid but no courier could be booked',
      );
      return reply.code(409).send({
        ok: false,
        code: 'no_courier',
        error: 'We took your payment but could not book a courier. Cancel the order for a refund.',
        paymentStatus: result.paymentStatus,
        orderStatus: result.orderStatus,
        dispatched: false,
        cancellable: CANCELLABLE_STATUSES.includes(result.orderStatus),
      });
    }

    // `outcome` is on the wire because `dispatched: false` cannot carry this on
    // its own: it is the ordinary answer for a return-only order, which is
    // booked and fine, and also the answer while the bank is still settling,
    // which is neither. The app has to say different things about those two.
    return {
      ok: true,
      outcome: result.outcome,
      paymentStatus: result.paymentStatus,
      orderStatus: result.orderStatus,
      dispatched: result.dispatched,
      leg: result.leg,
    };
  });

  app.post<{ Params: { id: string } }>('/v1/me/orders/:id/cancel', async (req, reply) => {
    const order = await ownedOrder(req, reply);
    if (!order) return;

    // Cancelling is gated on custody, and the gate lives here rather than in
    // the app: a client check is a courtesy, not a control.
    if (!CANCELLABLE_STATUSES.includes(order.status)) {
      return reply.code(409).send({
        ok: false,
        error: 'This order can no longer be cancelled. Please call the shop.',
      });
    }

    const { data: legs } = await db
      .from('delivery_legs')
      .select('id, provider, provider_delivery_id, status')
      .eq('order_id', req.params.id)
      .not('status', 'in', '(delivered,returned,cancelled,failed)');

    const errors: string[] = [];
    for (const leg of legs ?? []) {
      const provider = orders.providerFor(leg.provider);
      if (!provider || !leg.provider_delivery_id) continue;
      try {
        await provider.cancelDelivery(leg.provider_delivery_id);
      } catch (err) {
        errors.push((err as Error).message);
      }
    }
    if (errors.length) return reply.code(409).send({ ok: false, errors });

    const money = await payments.voidOrder(req.params.id, 'cancelled by customer');
    await db
      .from('orders')
      .update({ status: 'cancelled', cancelled_reason: 'cancelled by customer' })
      .eq('id', req.params.id);

    if (money.failed.length > 0) {
      req.log.error({ orderId: req.params.id, failed: money.failed }, 'cancelled but refund pending');
      return {
        ok: true,
        refundPending: true,
        message:
          'Your pickup is cancelled. The refund could not be completed automatically and is being processed manually.',
      };
    }
    return { ok: true, refundPending: false };
  });

  app.post<{ Params: { id: string }; Body: { start?: string; end?: string } }>(
    '/v1/me/orders/:id/dispatch-return',
    async (req, reply) => {
      const order = await ownedOrder(req, reply);
      if (!order) return;

      if (order.status !== 'ready') {
        return reply
          .code(409)
          .send({ ok: false, error: 'This order is not ready for delivery yet.' });
      }

      // The window is written here rather than by the app because the app
      // cannot write it: orders_customer_update only matches 'draft' and
      // 'awaiting_approval', so the same UPDATE at 'ready' matches zero rows,
      // PostgREST answers 204, and supabase-swift reports success. The phone
      // then believes it saved a time that was never stored, and the two tiers
      // that end at the return leg can never reach 'delivered'. Optional, so an
      // order whose window is already set still dispatches with no body at all.
      const { start, end } = req.body ?? {};
      if (start || end) {
        const chosen = returnWindow(start, end);
        if ('error' in chosen) return reply.code(400).send({ ok: false, error: chosen.error });

        const { error } = await db
          .from('orders')
          .update({ return_window_start: chosen.start, return_window_end: chosen.end })
          .eq('id', req.params.id);
        if (error) {
          req.log.error({ err: error, orderId: req.params.id }, 'could not save delivery window');
          return reply.code(502).send({ ok: false, error: 'Could not save that delivery time.' });
        }
        order.return_window_start = chosen.start;
      }

      if (!order.return_window_start) {
        return reply.code(409).send({ ok: false, error: 'Choose a delivery time first.' });
      }

      try {
        const leg = await orders.dispatchLeg(req.params.id, 'return');
        return { ok: true, leg };
      } catch (err) {
        req.log.error({ err, orderId: req.params.id }, 'customer return dispatch failed');
        return reply.code(502).send({ ok: false, error: (err as Error).message });
      }
    },
  );
}
