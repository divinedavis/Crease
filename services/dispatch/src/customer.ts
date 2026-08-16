import type { FastifyInstance } from 'fastify';
import type { SupabaseClient } from '@supabase/supabase-js';
import type { OrderService } from './orders.js';
import type { PaymentService } from './payments.js';
import type { PayoutService } from './payouts.js';
import type { PushEnvironment, PushService } from './push.js';
import { confirmAndDispatch } from './confirm.js';
import { config } from './config.js';
import { DeliveryProviderError, TERMINAL_STATUSES } from './deps.js';
import { CustomerFacingError } from './orders.js';
import { RETAIN_ALL } from './payments.js';
import { CANCELLATION_FEE_CENTS } from './pricing.js';
import { parseWindow } from './windows.js';

/**
 * When a customer may still call an order off themselves.
 *
 * 'failed' is in the list because a courier that could never be booked leaves a
 * paid order nobody is coming for. Without it the only route back to their own
 * money is a phone call to a shop that never saw the bag.
 */
const CANCELLABLE_STATUSES = ['draft', 'scheduled', 'pickup_dispatched', 'failed'];

/**
 * Leg states that mean a courier is actually on the job.
 *
 * 'pending' and 'dispatching' are the only two where nobody has been engaged
 * yet and calling the job off costs nothing. Everything past them — including
 * the terminal ones, which is the point — means a carrier was assigned and will
 * bill for the abort.
 */
const COURIER_ENGAGED_STATUSES = [
  'courier_assigned',
  'en_route_to_pickup',
  'at_pickup',
  'picked_up',
  'en_route_to_dropoff',
  'at_dropoff',
  'delivered',
  'returned',
];

/**
 * A carrier saying "there is no such delivery", as opposed to "we could not
 * cancel it".
 *
 * The two answers look alike and mean opposite things. Nothing is on the road
 * for a delivery the provider has never heard of, so there is nothing to call
 * off and the cancellation can proceed; a delivery it knows about but will not
 * cancel is a courier holding real garments and has to block.
 *
 * This is not hypothetical. The simulator keeps its deliveries in memory, so
 * every in-flight order dispatched before a deploy answers 404 here for the
 * rest of its life — and the rollback below then refuses the customer their own
 * cancellation, permanently, on an order with no courier behind it at all.
 *
 * 404 is the signal the carriers and the simulator both send. The code and
 * message checks are for a provider that answers 400-with-a-body instead, and
 * they are deliberately narrow: a 409 'cannot cancel after pickup' must not
 * match.
 */
function isUnknownDelivery(err: unknown): boolean {
  if (err instanceof DeliveryProviderError) {
    if (err.opts.status === 404) return true;
    if (err.opts.providerCode && /not_?found|unknown/i.test(err.opts.providerCode)) return true;
  }
  const message = err instanceof Error ? err.message : '';
  return /(not found|unknown (mock )?delivery|no such delivery)/i.test(message);
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
  payouts: PayoutService,
  push: PushService,
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
      // cancelled_reason comes along because the cancel route may have to put
      // it back: it is the only record of why a leg died, and it is read here,
      // before anything overwrites it.
      .select('id, customer_id, status, cancelled_reason, delivery_fee_cents, return_window_start')
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

  /**
   * Where to reach this customer when their laundry is done.
   *
   * The app posts its APNs token here on every launch, which is also how a
   * token that moved between accounts on a shared phone gets reassigned rather
   * than left pointing at whoever was signed in last.
   *
   * The environment comes from the device because only the device knows it: a
   * TestFlight build registers against production APNs and a Debug build
   * against sandbox, and a server that guesses gets it wrong for exactly one of
   * them — silently, since Apple accepts the send and delivers nothing.
   */
  app.post<{ Body: { token?: string; environment?: string } }>(
    '/v1/me/push-tokens',
    async (req, reply) => {
      const userId = await userIdFrom(req);
      if (!userId) return reply.code(401).send({ ok: false, error: 'Please sign in again.' });

      // Shape, not length: APNs tokens are 64 hex characters today and Apple
      // has changed that before. Lowercased because iOS hands the same device
      // back in either case, and the token is a unique key — two cases means
      // two rows and two notifications.
      const token = String(req.body?.token ?? '').trim().toLowerCase();
      if (!/^[0-9a-f]{32,200}$/.test(token)) {
        return reply.code(400).send({ ok: false, error: 'That is not a device token.' });
      }

      const environment = String(req.body?.environment ?? '');
      if (environment !== 'sandbox' && environment !== 'production') {
        return reply
          .code(400)
          .send({ ok: false, error: "environment must be 'sandbox' or 'production'." });
      }

      try {
        await push.registerToken(userId, token, environment as PushEnvironment);
        return { ok: true };
      } catch (err) {
        req.log.error({ err }, 'device token registration failed');
        return reply.code(502).send({ ok: false, error: 'Could not register this device.' });
      }
    },
  );

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
      // Log the raw provider message server-side; never return it to the
      // customer — it leaks Stripe intent/charge ids and config internals.
      req.log.error({ err, orderId: req.params.id }, 'customer payment intent failed');
      return reply.code(402).send({ ok: false, error: 'Could not start payment. Please try again.' });
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
      // Generic on the wire, detailed in the log — the same rule the
      // payment-intent route above states, and for the same reason. What throws
      // out of here is written for us: it quotes the order's short code, the
      // payment status verbatim ("has no held funds (payment status
      // 'requires_payment_method')") and whatever Stripe said, none of which
      // means anything to a customer and all of which describes our internals
      // to anyone holding a token.
      req.log.error({ err, orderId: req.params.id }, 'confirm payment failed');
      return reply
        .code(502)
        .send({ ok: false, error: 'We could not confirm your payment just now. Please try again.' });
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

  /**
   * The customer accepted a total that came in above their hold.
   *
   * This route exists because the approval had no server side at all. The only
   * thing that captures the hold and charges the difference is
   * `approveAndCharge`, and its single caller in the whole repo was an e2e
   * script — the portal never approves, and the app wrote `orders.approved_at`
   * straight through PostgREST, a column nothing reads. So the customer tapped
   * Approve, the sheet dismissed, the shop's banner stayed up, and the balance
   * was never taken. Both ends reported success because nothing had run.
   *
   * The write could not even fail loudly: `orders_customer_update` matches only
   * 'draft' and 'awaiting_approval', so once the shop moved the order the UPDATE
   * matched zero rows, PostgREST answered 204, and supabase-swift called that a
   * success. Same shape as the delivery-window bug that route above documents.
   *
   * The status check here is a courtesy that produces a better message; the real
   * gate is the atomic claim inside approveAndCharge, which is what stops a
   * double-tap charging twice.
   */
  app.post<{ Params: { id: string } }>('/v1/me/orders/:id/approve', async (req, reply) => {
    const order = await ownedOrder(req, reply);
    if (!order) return;

    if (order.status !== 'awaiting_approval') {
      return reply
        .code(409)
        .send({ ok: false, error: 'This order is not waiting for your approval.' });
    }

    let result;
    try {
      result = await payments.approveAndCharge(req.params.id);
    } catch (err) {
      // A decline is the expected failure here, and approveAndCharge has already
      // rolled the order back to 'awaiting_approval' so the customer can fix
      // their card and come back. Generic on the wire for the usual reason: what
      // throws quotes Stripe verbatim.
      req.log.error({ err, orderId: req.params.id }, 'customer approve failed');
      const message =
        err instanceof CustomerFacingError
          ? err.message
          : 'We could not take that payment. Check your card details and try again.';
      return reply.code(402).send({ ok: false, error: message });
    }

    // Paying the shop is bookkeeping, not part of the customer's transaction —
    // the same rule the settle route states. A payout that fails must not tell
    // someone their approved payment did not go through; the pending row is
    // swept later.
    try {
      await payouts.payoutOrder(req.params.id);
    } catch (err) {
      req.log.error({ err, orderId: req.params.id }, 'payout deferred');
    }

    // `alreadyHandled` distinguishes "we just took the money" from "somebody
    // else already had" — a retry after a dropped response is a success, and the
    // app should not announce a second charge for it.
    return {
      ok: true,
      totalCents: result.total,
      chargedCents: result.remainder,
      alreadyHandled: result.alreadyHandled ?? false,
    };
  });

  app.post<{ Params: { id: string } }>('/v1/me/orders/:id/cancel', async (req, reply) => {
    const order = await ownedOrder(req, reply);
    if (!order) return;

    // Claim the cancellation in the same operation that checks it is allowed.
    // Reading the status here and writing 'cancelled' at the end left a window
    // several hundred milliseconds wide — the length of a Stripe refund — in
    // which confirm-payment could read a still-live order and dispatch a
    // courier. The customer then has their money back and a driver at the door.
    // A conditional update means only one of the two paths can win.
    const { data: claimed } = await db
      .from('orders')
      .update({ status: 'cancelled', cancelled_reason: 'cancelled by customer' })
      .eq('id', req.params.id)
      .in('status', CANCELLABLE_STATUSES)
      .select('id')
      .maybeSingle();

    if (!claimed) {
      return reply.code(409).send({
        ok: false,
        error: 'This order can no longer be cancelled. Please call the shop.',
      });
    }

    // Every leg, not just the live ones: the live ones have to be called off at
    // the carrier, and the finished ones decide what money comes back.
    const { data: legs } = await db
      .from('delivery_legs')
      .select('id, leg, provider, provider_delivery_id, status')
      .eq('order_id', req.params.id);

    const errors: string[] = [];
    for (const leg of legs ?? []) {
      if (TERMINAL_STATUSES.includes(leg.status)) continue;
      const provider = orders.providerFor(leg.provider);
      if (!provider || !leg.provider_delivery_id) continue;
      try {
        await provider.cancelDelivery(leg.provider_delivery_id);
      } catch (err) {
        // A delivery the carrier cannot find is not a courier we failed to
        // stop — it is one that does not exist. Treat it as already called off
        // rather than as a reason to refuse the customer their cancellation
        // forever.
        if (isUnknownDelivery(err)) {
          req.log.warn(
            { orderId: req.params.id, legId: leg.id, provider: leg.provider, err },
            'carrier does not know this delivery — nothing to call off',
          );
          continue;
        }
        errors.push((err as Error).message);
      }
    }
    if (errors.length) {
      // A courier we could not call off is still on the way. Put the order back
      // where the claim found it rather than leaving a cancelled row with a live
      // delivery against it, and refund nothing.
      //
      // With the reason it arrived with, not with a null. The claim overwrote
      // cancelled_reason with 'cancelled by customer' a few lines up, and
      // rolling that back to nothing destroyed the message recordLegFailure had
      // written there — which on a 'failed' order is the entire explanation of
      // why it failed, and the only thing support has to go on when the
      // customer rings about the cancel that would not take.
      await db
        .from('orders')
        .update({ status: order.status, cancelled_reason: order.cancelled_reason ?? null })
        .eq('id', req.params.id);
      // `errors` are the carrier's own words, written for our logs. Send a
      // sentence the customer can act on alongside them, or the app has nothing
      // to show but its own generic retry copy — and retrying is exactly the
      // wrong advice when a courier really is on the way.
      return reply.code(409).send({
        ok: false,
        error: 'A courier is already on the way and we could not call them off. Please contact support.',
        errors,
      });
    }

    // What comes back depends on custody, not on the status the order is in.
    // 'failed' is cancellable so a customer whose courier never showed can
    // reach their own money — but it is also where an order lands after the
    // return leg runs out of attempts, by which point Crease has paid for up to
    // three couriers and a shop has cleaned the garments. Refunding that in full
    // turns "be unavailable four times" into a free service.
    const bagCollected = (legs ?? []).some((l) => l.leg === 'pickup' && l.status === 'delivered');
    const courierEngaged = (legs ?? []).some((l) => COURIER_ENGAGED_STATUSES.includes(l.status));

    const money = bagCollected
      ? await payments.voidOrder(req.params.id, 'cancelled by customer after pickup', {
          retainCents: RETAIN_ALL,
        })
      : courierEngaged
        ? await payments.voidOrder(req.params.id, 'cancelled by customer after courier assigned', {
            retainCents: CANCELLATION_FEE_CENTS,
          })
        : await payments.voidOrder(req.params.id, 'cancelled by customer');

    if (money.failed.length > 0) {
      req.log.error({ orderId: req.params.id, failed: money.failed }, 'cancelled but refund pending');
      return {
        ok: true,
        refundPending: true,
        message:
          'Your pickup is cancelled. The refund could not be completed automatically and is being processed manually.',
      };
    }

    if (bagCollected) {
      return {
        ok: true,
        refundPending: false,
        refunded: false,
        message:
          'Your order is cancelled. Because your items were already collected, the fee has not been refunded automatically — contact support and we will sort it out.',
      };
    }
    if (courierEngaged) {
      // A fee that swallowed the whole charge refunded nothing, and telling
      // someone "the rest has been refunded" when no money moved is the message
      // that becomes a chargeback.
      const refunded = money.voided > 0;
      return {
        ok: true,
        refundPending: false,
        refunded,
        retainedCents: money.retainedCents,
        message: refunded
          ? 'Your pickup is cancelled. A driver had already been assigned, so a cancellation fee was kept and the rest has been refunded.'
          : 'Your pickup is cancelled. A driver had already been assigned, so the fee covers the cancellation charge and has not been refunded.',
      };
    }
    return { ok: true, refundPending: false, refunded: true };
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
        const chosen = parseWindow(start, end, 'delivery');
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
        // Same rule as the payment routes: the dispatcher's own failures name
        // short codes, tiers, cent amounts and carrier internals, and none of
        // that belongs in a reply to a phone. The exception is the refusal that
        // was written FOR the customer — "this order is out of attempts, call
        // support" — which is the answer rather than a leak, and which as a
        // generic 502 just sends someone back into a retry that cannot work.
        const message =
          err instanceof CustomerFacingError
            ? err.message
            : 'We could not book your delivery just now. Please try again.';
        return reply.code(502).send({ ok: false, error: message });
      }
    },
  );
}
