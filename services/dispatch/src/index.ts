import Fastify from 'fastify';
import { createClient } from '@supabase/supabase-js';
import WebSocketTransport from 'ws';
import { config } from './config.js';
import { buildChain } from './deps.js';
import { OrderService, type LegType } from './orders.js';
import { PaymentService } from './payments.js';
import { PayoutService } from './payouts.js';
import { registerCustomerRoutes } from './customer.js';
import { buildPaymentProvider, buildConnectProvider } from '@crease/payments';

const app = Fastify({
  logger: { level: config.logLevel },
  // Webhook signatures are HMACs over the exact bytes received. Keep them.
  bodyLimit: 1024 * 512,
});

const db = createClient(config.supabaseUrl, config.supabaseServiceKey, {
  auth: { persistSession: false, autoRefreshToken: false },
  // supabase-js constructs a RealtimeClient eagerly even though the
  // dispatcher only ever makes REST calls. Node 20 has no global WebSocket,
  // so without an explicit transport createClient throws at import time. The
  // droplet is shared with five other sites — supplying `ws` is the safe fix;
  // upgrading Node globally there is not.
  // Cast: supabase-js types the transport against the DOM WebSocket, whose
  // event types are narrower than `ws`'s. They are structurally compatible at
  // runtime, and nothing here ever subscribes to a channel — this exists only
  // so the eager RealtimeClient construction does not throw on Node 20.
  realtime: { transport: WebSocketTransport as any },
});

const chain = buildChain({ ...config.providers, PUBLIC_URL: config.publicUrl } as any);
const orders = new OrderService(db, chain, app.log);
const paymentProvider = buildPaymentProvider(config.payments);
const payments = new PaymentService(db, paymentProvider, app.log);
const connectProvider = buildConnectProvider(config.payments);
const payouts = new PayoutService(db, connectProvider, app.log);

// Customer-facing routes, authenticated by the caller's own Supabase token.
// Deliberately separate from /v1/, which stays loopback-only and shared-secret
// guarded because it can dispatch and charge without an owner check.
registerCustomerRoutes(app, db, orders, payments);

// Capture the raw body for every request so signature verification never has
// to re-serialize a parsed object (key order changes break the HMAC).
app.addContentTypeParser('application/json', { parseAs: 'buffer' }, (req, body, done) => {
  (req as any).rawBody = body as Buffer;
  try {
    done(null, body.length ? JSON.parse(body.toString('utf8')) : {});
  } catch (err) {
    done(err as Error, undefined);
  }
});

/** Shared-secret guard for the portal and the iOS app. */
async function requireInternalKey(req: any, reply: any) {
  const key = req.headers['x-crease-key'];
  if (key !== config.internalApiKey) {
    return reply.code(401).send({ error: 'unauthorized' });
  }
}

app.get('/healthz', async () => ({
  ok: true,
  providers: chain.active().map((p) => p.name),
  payments: paymentProvider.name,
  connect: connectProvider.name,
}));

/**
 * A PaymentIntent for the delivery fee, for the app to settle with Apple Pay
 * or a card. Returns the client secret and the publishable key, which is all
 * a client is allowed to hold.
 */
app.post<{ Params: { id: string } }>(
  '/v1/orders/:id/payment-intent',
  { preHandler: requireInternalKey },
  async (req, reply) => {
    try {
      const result = await payments.createDeliveryPaymentIntent(req.params.id);
      return { ok: true, ...result, publishableKey: config.stripePublishableKey };
    } catch (err) {
      req.log.error({ err, orderId: req.params.id }, 'payment intent failed');
      return reply.code(402).send({ ok: false, error: (err as Error).message });
    }
  },
);

/** Hold funds at checkout, against the estimate plus capped headroom. */
app.post<{ Params: { id: string } }>(
  '/v1/orders/:id/authorize',
  { preHandler: requireInternalKey },
  async (req, reply) => {
    try {
      return { ok: true, payment: await payments.authorizeOrder(req.params.id) };
    } catch (err) {
      req.log.warn({ err, orderId: req.params.id }, 'authorize failed');
      return reply.code(402).send({ ok: false, error: (err as Error).message });
    }
  },
);

/**
 * Settle against the counted total. An intake above the hold is not an
 * error — it returns needsApproval so the caller can ask the customer.
 */
app.post<{ Params: { id: string } }>(
  '/v1/orders/:id/settle',
  { preHandler: requireInternalKey },
  async (req, reply) => {
    try {
      const result = await payments.settleOrder(req.params.id);

      // Pay the shop out of money we now actually hold. A payout failure must
      // not fail the settle call — the customer has been charged correctly and
      // the row is retried by the sweep; conflating the two would make the
      // portal show a payment error for a bookkeeping problem.
      if (!result.needsApproval && result.captured > 0) {
        try {
          await payouts.payoutOrder(req.params.id);
        } catch (err) {
          req.log.error({ err, orderId: req.params.id }, 'payout deferred');
        }
      }

      return { ok: true, ...result };
    } catch (err) {
      req.log.error({ err, orderId: req.params.id }, 'settle failed');
      return reply.code(402).send({ ok: false, error: (err as Error).message });
    }
  },
);

/** Customer accepted a total above the hold: capture it and charge the rest. */
app.post<{ Params: { id: string } }>(
  '/v1/orders/:id/approve',
  { preHandler: requireInternalKey },
  async (req, reply) => {
    try {
      const result = await payments.approveAndCharge(req.params.id);
      try {
        await payouts.payoutOrder(req.params.id);
      } catch (err) {
        req.log.error({ err, orderId: req.params.id }, 'payout deferred');
      }
      return { ok: true, ...result };
    } catch (err) {
      req.log.error({ err, orderId: req.params.id }, 'approve failed');
      return reply.code(402).send({ ok: false, error: (err as Error).message });
    }
  },
);

/** Start (or resume) a shop's payout onboarding. */
app.post<{ Params: { id: string }; Body: { returnUrl?: string; refreshUrl?: string } }>(
  '/v1/cleaners/:id/connect-onboarding',
  { preHandler: requireInternalKey },
  async (req, reply) => {
    try {
      const base = config.publicUrl;
      return {
        ok: true,
        ...(await payouts.startOnboarding(
          req.params.id,
          req.body?.returnUrl ?? `${base}/settings/payouts?done=1`,
          req.body?.refreshUrl ?? `${base}/settings/payouts?retry=1`,
        )),
      };
    } catch (err) {
      req.log.error({ err, cleanerId: req.params.id }, 'connect onboarding failed');
      return reply.code(502).send({ ok: false, error: (err as Error).message });
    }
  },
);

/** Re-read Stripe's view of a shop's account. */
app.post<{ Params: { id: string } }>(
  '/v1/cleaners/:id/connect-refresh',
  { preHandler: requireInternalKey },
  async (req, reply) => {
    try {
      const account = await payouts.refreshAccount(req.params.id);
      if (!account) return reply.code(404).send({ ok: false, error: 'no connect account' });
      return { ok: true, account };
    } catch (err) {
      return reply.code(502).send({ ok: false, error: (err as Error).message });
    }
  },
);

/**
 * Development only: pretend a shop finished Stripe's hosted onboarding.
 *
 * Refuses outright unless the mock Connect provider is active, so it can never
 * mark a real Stripe account payable. Exists because the alternative — setting
 * `payouts_enabled` directly in the database — produces a shop the database
 * thinks is payable and Stripe does not, which is precisely the disagreement
 * that makes payout bugs hard to see.
 */
app.post<{ Params: { id: string } }>(
  '/v1/cleaners/:id/connect-complete-mock',
  { preHandler: requireInternalKey },
  async (req, reply) => {
    if (connectProvider.name !== 'mock') {
      return reply.code(403).send({ ok: false, error: 'only available with the mock provider' });
    }
    const { data: cleaner } = await db
      .from('cleaners')
      .select('stripe_account_id')
      .eq('id', req.params.id)
      .single();
    if (!cleaner?.stripe_account_id) {
      return reply.code(409).send({ ok: false, error: 'no connect account yet' });
    }
    (connectProvider as any).completeOnboarding(cleaner.stripe_account_id);
    const account = await payouts.refreshAccount(req.params.id);
    return { ok: true, account };
  },
);

/** Retry payouts still owed — onboarding finished, or a transient failure. */
app.post('/v1/payouts/sweep', { preHandler: requireInternalKey }, async (req, reply) => {
  try {
    return { ok: true, ...(await payouts.sweepPending()) };
  } catch (err) {
    return reply.code(502).send({ ok: false, error: (err as Error).message });
  }
});

/**
 * Leg 1 — customer to cleaner. Called when the pickup window opens
 * (by the scheduler) or immediately for an on-demand order.
 */
app.post<{ Params: { id: string } }>(
  '/v1/orders/:id/dispatch-pickup',
  { preHandler: requireInternalKey },
  async (req, reply) => {
    // Never send a courier for an order with no money held. An intent that
    // was created but never confirmed looks like a payment row and is not one,
    // so check the status rather than the existence of the row.
    const { data: payment } = await db
      .from('payments')
      .select('status')
      .eq('order_id', req.params.id)
      .eq('kind', 'primary')
      .maybeSingle();

    if (!payment || !['authorized', 'captured'].includes(payment.status)) {
      return reply.code(402).send({
        ok: false,
        error: `order has no held funds (payment status '${payment?.status ?? 'none'}')`,
      });
    }

    try {
      const leg = await orders.dispatchLeg(req.params.id, 'pickup');
      return { ok: true, leg };
    } catch (err) {
      req.log.error({ err, orderId: req.params.id }, 'pickup dispatch failed');
      return reply.code(502).send({ ok: false, error: (err as Error).message });
    }
  },
);

/**
 * Leg 2 — cleaner to customer. Called when the cleaner marks the order ready.
 * Guarded on order status so a mis-click cannot send a courier for garments
 * that are still on the rack.
 */
app.post<{ Params: { id: string } }>(
  '/v1/orders/:id/dispatch-return',
  { preHandler: requireInternalKey },
  async (req, reply) => {
    const { data: order } = await db
      .from('orders')
      .select('status, return_window_start')
      .eq('id', req.params.id)
      .single();

    if (!order) return reply.code(404).send({ error: 'order not found' });
    if (order.status !== 'ready') {
      return reply
        .code(409)
        .send({ error: `order must be 'ready' to dispatch return, is '${order.status}'` });
    }
    // The customer picks the delivery window once the shop says the clothes
    // are done. Dispatching without one would send a courier at whatever
    // moment the shop happened to press a button, which is not a time anybody
    // agreed to.
    if (!order.return_window_start) {
      return reply
        .code(409)
        .send({ error: 'no delivery window chosen yet — the customer schedules this' });
    }

    try {
      const leg = await orders.dispatchLeg(req.params.id, 'return');
      return { ok: true, leg };
    } catch (err) {
      req.log.error({ err, orderId: req.params.id }, 'return dispatch failed');
      return reply.code(502).send({ ok: false, error: (err as Error).message });
    }
  },
);

app.post<{ Params: { id: string } }>(
  '/v1/orders/:id/cancel',
  { preHandler: requireInternalKey },
  async (req, reply) => {
    const { data: legs } = await db
      .from('delivery_legs')
      .select('id, provider, provider_delivery_id, status')
      .eq('order_id', req.params.id)
      .not('status', 'in', '(delivered,returned,cancelled,failed)');

    const errors: string[] = [];
    for (const leg of legs ?? []) {
      const provider = chain.get(leg.provider);
      if (!provider || !leg.provider_delivery_id) continue;
      try {
        await provider.cancelDelivery(leg.provider_delivery_id);
      } catch (err) {
        // Carriers refuse cancellation once the goods are aboard. Surface it
        // rather than pretending the order stopped.
        errors.push(`${leg.id}: ${(err as Error).message}`);
      }
    }
    if (errors.length) return reply.code(409).send({ ok: false, errors });

    // Release or refund the money too. Cancelling the couriers but leaving a
    // customer's money on a dead order is the complaint that ends a young
    // marketplace.
    const money = await payments.voidOrder(req.params.id, 'order cancelled');

    await db
      .from('orders')
      .update({ status: 'cancelled', cancelled_reason: 'cancelled by request' })
      .eq('id', req.params.id);

    // The couriers are stopped either way, so the cancellation itself stands.
    // But a failed refund must not be reported as a clean cancellation — the
    // customer is still out of pocket and needs to be told so.
    if (money.failed.length > 0) {
      req.log.error({ orderId: req.params.id, failed: money.failed }, 'cancelled but refund pending');
      return {
        ok: true,
        refundPending: true,
        message: 'Your pickup is cancelled. The refund could not be completed automatically and is being processed manually.',
      };
    }

    return { ok: true, refundPending: false };
  },
);

/**
 * Provider callbacks. One route per provider; each verifies its own signature
 * and hands back a normalized event.
 *
 * Every payload is landed in delivery_events before it is applied, valid or
 * not — an invalid signature is a security signal, and a mis-parsed event can
 * be replayed from the raw row instead of being lost.
 */
app.post<{ Params: { provider: string } }>('/webhooks/:provider', async (req, reply) => {
  const provider = chain.get(req.params.provider);
  if (!provider) return reply.code(404).send({ error: 'unknown provider' });

  const rawBody: Buffer = (req as any).rawBody ?? Buffer.from('');
  const result = await provider.handleWebhook({ headers: req.headers as any, rawBody });

  let payload: unknown = {};
  try {
    payload = JSON.parse(rawBody.toString('utf8'));
  } catch {
    /* keep {} — the raw bytes are what matter for replay */
  }

  const { data: landed } = await db
    .from('delivery_events')
    .insert({
      provider: provider.name,
      event_id: result.event?.eventId,
      event_type: result.event?.eventType,
      provider_delivery_id: result.event?.providerDeliveryId,
      payload,
      signature_valid: result.signatureValid,
    })
    .select('id')
    .maybeSingle();

  if (!result.signatureValid) {
    req.log.warn({ provider: provider.name, ip: req.ip }, 'webhook signature rejected');
    return reply.code(401).send({ error: 'bad signature' });
  }
  // Dedupe: the unique index made the insert a no-op, so we have seen this one.
  if (!landed) {
    return { ok: true, deduped: true };
  }
  if (!result.event) {
    await db
      .from('delivery_events')
      .update({ processed_at: new Date().toISOString(), error: result.ignored })
      .eq('id', landed.id);
    return { ok: true, ignored: result.ignored };
  }

  // Our leg id round-trips as the provider's external_id; fall back to a
  // lookup by provider delivery id when a provider omits it on some events.
  let legId = result.event.externalId;
  if (!legId && result.event.providerDeliveryId) {
    const { data } = await db
      .from('delivery_legs')
      .select('id')
      .eq('provider', provider.name)
      .eq('provider_delivery_id', result.event.providerDeliveryId)
      .maybeSingle();
    legId = data?.id;
  }

  if (!legId) {
    await db
      .from('delivery_events')
      .update({ processed_at: new Date().toISOString(), error: 'no matching leg' })
      .eq('id', landed.id);
    return { ok: true, ignored: 'no matching leg' };
  }

  try {
    await orders.applyEvent(legId, result.event);
    await db
      .from('delivery_events')
      .update({ processed_at: new Date().toISOString(), delivery_leg_id: legId })
      .eq('id', landed.id);
  } catch (err) {
    // 500 so the provider retries; the raw row is already durable either way.
    await db.from('delivery_events').update({ error: (err as Error).message }).eq('id', landed.id);
    req.log.error({ err, legId }, 'failed to apply webhook event');
    return reply.code(500).send({ ok: false });
  }

  return { ok: true };
});

app
  .listen({ port: config.port, host: config.host })
  .then(() => app.log.info({ providers: chain.active().map((p) => p.name) }, 'dispatch up'))
  .catch((err) => {
    app.log.error(err);
    process.exit(1);
  });
