import type { FastifyInstance } from 'fastify';
import type { SupabaseClient } from '@supabase/supabase-js';
import type { OrderService } from './orders.js';
import type { PaymentService } from './payments.js';
import { config } from './config.js';

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
    try {
      const result = await payments.createDeliveryPaymentIntent(req.params.id);
      return { ok: true, ...result, publishableKey: config.stripePublishableKey };
    } catch (err) {
      req.log.error({ err, orderId: req.params.id }, 'customer payment intent failed');
      return reply.code(402).send({ ok: false, error: (err as Error).message });
    }
  });

  app.post<{ Params: { id: string } }>('/v1/me/orders/:id/cancel', async (req, reply) => {
    const order = await ownedOrder(req, reply);
    if (!order) return;

    // Cancelling is gated on custody, and the gate lives here rather than in
    // the app: a client check is a courtesy, not a control.
    if (!['draft', 'scheduled', 'pickup_dispatched'].includes(order.status)) {
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

  app.post<{ Params: { id: string } }>('/v1/me/orders/:id/dispatch-return', async (req, reply) => {
    const order = await ownedOrder(req, reply);
    if (!order) return;

    if (order.status !== 'ready') {
      return reply
        .code(409)
        .send({ ok: false, error: 'This order is not ready for delivery yet.' });
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
  });
}
