import Fastify from 'fastify';
import { createClient } from '@supabase/supabase-js';
import WebSocketTransport from 'ws';
import { config } from './config.js';
import { buildChain } from './deps.js';
import { OrderService, type LegType } from './orders.js';
import { PaymentService } from './payments.js';
import { buildPaymentProvider } from '@crease/payments';

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
}));

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
      return { ok: true, ...(await payments.settleOrder(req.params.id)) };
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
      return { ok: true, ...(await payments.approveAndCharge(req.params.id)) };
    } catch (err) {
      req.log.error({ err, orderId: req.params.id }, 'approve failed');
      return reply.code(402).send({ ok: false, error: (err as Error).message });
    }
  },
);

/**
 * Leg 1 — customer to cleaner. Called when the pickup window opens
 * (by the scheduler) or immediately for an on-demand order.
 */
app.post<{ Params: { id: string } }>(
  '/v1/orders/:id/dispatch-pickup',
  { preHandler: requireInternalKey },
  async (req, reply) => {
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
      .select('status')
      .eq('id', req.params.id)
      .single();

    if (!order) return reply.code(404).send({ error: 'order not found' });
    if (order.status !== 'ready') {
      return reply
        .code(409)
        .send({ error: `order must be 'ready' to dispatch return, is '${order.status}'` });
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

    // Release the hold too. Cancelling the couriers but leaving a customer's
    // money on a dead order is the complaint that ends a young marketplace.
    await payments.voidOrder(req.params.id, 'order cancelled');
    await db
      .from('orders')
      .update({ status: 'cancelled', cancelled_reason: 'cancelled by request' })
      .eq('id', req.params.id);
    return { ok: true };
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
