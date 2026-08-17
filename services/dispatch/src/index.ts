import Fastify from 'fastify';
import { timingSafeEqual, createHash } from 'node:crypto';
import { createClient } from '@supabase/supabase-js';
import WebSocketTransport from 'ws';
import { config } from './config.js';
import { buildChain } from './deps.js';
import { OrderService, type LegType } from './orders.js';
import { PaymentService } from './payments.js';
import { PayoutService } from './payouts.js';
import { registerCustomerRoutes } from './customer.js';
import { confirmAndDispatch } from './confirm.js';
import { PushService } from './push.js';
import { readyWindow } from './ready.js';
import { buildPaymentProvider, buildConnectProvider, verifyStripeSignature } from '@crease/payments';

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
// Pricing asks the dispatcher what the route costs before it charges for it.
// Passed as a closure rather than the service itself so payments keeps no
// dependency on couriers beyond this one question.
const payments = new PaymentService(db, paymentProvider, app.log, (id) =>
  orders.quoteRouteCostCents(id),
);
const connectProvider = buildConnectProvider(config.payments);
const payouts = new PayoutService(db, connectProvider, app.log);
const push = new PushService(db, app.log);

// Customer-facing routes, authenticated by the caller's own Supabase token.
// Deliberately separate from /v1/, which stays loopback-only and shared-secret
// guarded because it can dispatch and charge without an owner check.
registerCustomerRoutes(app, db, orders, payments, payouts, push);

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

/**
 * When an order may still be called off.
 *
 * Duplicated from customer.ts rather than imported: the two cancel routes have
 * to agree, so a change to one list is a change to both. Worth hoisting into a
 * shared module next time either route is opened.
 */
const CANCELLABLE_STATUSES = ['draft', 'scheduled', 'pickup_dispatched', 'failed'];

/** Constant-time compare so the shared secret can't be recovered by timing.
 *  Both sides are hashed to a fixed 32-byte digest first, so the comparison
 *  never returns early on a length mismatch (which would leak the length). */
function secretEquals(a: string, b: string): boolean {
  const ha = createHash('sha256').update(a).digest();
  const hb = createHash('sha256').update(b).digest();
  return timingSafeEqual(ha, hb);
}

/** Shared-secret guard for the portal and the iOS app. */
async function requireInternalKey(req: any, reply: any) {
  // A header can arrive as string | string[]; normalize before comparing.
  const raw = req.headers['x-crease-key'];
  const key = Array.isArray(raw) ? (raw[0] ?? '') : (raw ?? '');
  if (!secretEquals(key, config.internalApiKey)) {
    return reply.code(401).send({ error: 'unauthorized' });
  }
}

app.get('/healthz', async (req) => {
  // The provider/payment/push posture is useful to a deploy check and useless
  // to a stranger — knowing the mock provider is or isn't live is a recon
  // signal, nothing more. Only the direct-loopback caller sees it: the deploy's
  // probe hits 127.0.0.1:8011 so its Host is the loopback address, while nginx
  // rewrites Host to the public domain on every proxied request. (The /healthz
  // nginx block does not forward X-Forwarded-For, so Host is the reliable tell.)
  const host = req.headers.host ?? '';
  const loopback = host.startsWith('127.0.0.1') || host.startsWith('localhost') || host.startsWith('[::1]');
  if (!loopback) return { ok: true };
  return {
    ok: true,
    providers: chain.active().map((p) => p.name),
    payments: paymentProvider.name,
    connect: connectProvider.name,
    // Reported because a broken push config is otherwise invisible: sends become
    // no-ops and nothing errors. Health is the one place a deploy check looks.
    push: push.status(),
  };
});

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

      // Pay the shop out of money we now actually hold — money THIS settle
      // collected. `captured` on a settle that took nothing is the delivery fee
      // charged at checkout, which is ours to pay a courier with; paying the
      // shop's cleaning share against it hands them a bill we never collected,
      // out of a fee we still owe. A payout failure must not fail the settle
      // call — the customer has been charged correctly and the row is retried
      // by the sweep; conflating the two would make the portal show a payment
      // error for a bookkeeping problem.
      if (!result.needsApproval && !result.nothingToSettle && result.captured > 0) {
        try {
          await payouts.payoutOrder(req.params.id);
        } catch (err) {
          req.log.error({ err, orderId: req.params.id }, 'payout deferred');
        }
      }

      // The count is the first thing anyone knows about what is actually in the
      // bag, so it is also the first real answer to when it will be done — two
      // hours for wash & fold against the shop's dry cleaning default of days.
      // A failure here must not fail the settle: the money is correct, and an
      // estimate is re-derivable from the same rows on the next intake.
      let estimatedReadyAt: string | null = null;
      try {
        estimatedReadyAt = await orders.refineReadyEstimate(req.params.id);
      } catch (err) {
        req.log.error({ err, orderId: req.params.id }, 'ready estimate not refined');
      }

      // The count is also the first confirmable "we have your clothes" on
      // every tier, so the customer is told here — after settle has decided
      // whether the message is reassurance or an approval request. The ledger
      // dedupes recounts, and a push must never fail a settle that already
      // moved money correctly.
      let notified: { sent: number; skipped?: string } = { sent: 0, skipped: 'not_attempted' };
      try {
        notified = await push.notifyOrderReceived(req.params.id);
      } catch (err) {
        req.log.error({ err, orderId: req.params.id }, 'received notification not sent');
      }

      // The window is computed here rather than by each surface so the shop and
      // the customer are never looking at two different ranges.
      return {
        ok: true,
        ...result,
        estimatedReadyAt,
        readyWindow: estimatedReadyAt ? readyWindow(estimatedReadyAt) : null,
        notified,
      };
    } catch (err) {
      req.log.error({ err, orderId: req.params.id }, 'settle failed');
      return reply.code(402).send({ ok: false, error: (err as Error).message });
    }
  },
);

/**
 * The shop says the clothes are finished.
 *
 * The transition lives here rather than in the portal because of what hangs off
 * it: this is the moment the customer has to be told, hours after they stopped
 * looking at the app. A push fired from the portal would fire from whichever
 * render happened to handle the click, with no ledger to stop the second one
 * and no way to know a retry had already sent it.
 *
 * Idempotent from 'ready' — a double-click at the counter is a success, and the
 * notification ledger underneath refuses the second send on its own.
 */
app.post<{ Params: { id: string } }>(
  '/v1/orders/:id/ready',
  { preHandler: requireInternalKey },
  async (req, reply) => {
    const { data: order } = await db
      .from('orders')
      .select('status, ready_at')
      .eq('id', req.params.id)
      .maybeSingle();

    if (!order) return reply.code(404).send({ ok: false, error: 'order not found' });
    if (!['cleaning', 'awaiting_approval', 'ready'].includes(order.status)) {
      return reply
        .code(409)
        .send({ ok: false, error: `cannot mark ready from status '${order.status}'` });
    }

    // ready_at is a fact, not a promise: it is what unlocks the customer
    // choosing a delivery time, so it records when the shop actually said so and
    // is never rewritten by a repeat call.
    let readyAt: string | null = order.ready_at ?? null;
    if (order.status !== 'ready') {
      const stamp = new Date().toISOString();
      // Conditional on the status we read, so two simultaneous presses cannot
      // both write: the loser matches zero rows and keeps the winner's stamp.
      // Without it the second write silently replaced ready_at, contradicting
      // the guarantee above.
      const { data: marked, error } = await db
        .from('orders')
        .update({ status: 'ready', ready_at: stamp })
        .eq('id', req.params.id)
        .in('status', ['cleaning', 'awaiting_approval'])
        .select('ready_at')
        .maybeSingle();
      if (error) {
        req.log.error({ err: error, orderId: req.params.id }, 'could not mark ready');
        return reply.code(502).send({ ok: false, error: error.message });
      }
      if (marked) {
        readyAt = marked.ready_at ?? stamp;
      } else {
        // Someone else got there first. Report their stamp, not ours.
        const { data: current } = await db
          .from('orders')
          .select('ready_at')
          .eq('id', req.params.id)
          .maybeSingle();
        readyAt = current?.ready_at ?? null;
      }
    }

    // The clothes are done whether or not a phone could be told so. Never fail
    // this call over a notification.
    let notified: { sent: number; skipped?: string } = { sent: 0, skipped: 'not_attempted' };
    try {
      notified = await push.notifyOrderReady(req.params.id);
    } catch (err) {
      req.log.error({ err, orderId: req.params.id }, 'ready notification not sent');
    }

    return { ok: true, orderStatus: 'ready', readyAt, notified };
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
    // Claim before touching a carrier or Stripe, for the same reason the
    // customer route does: refunding first and writing 'cancelled' last left a
    // window the width of a Stripe round-trip in which confirm-payment could
    // read a live order and dispatch a courier against money already given
    // back. It also stopped this route "cancelling" an order that was already
    // delivered, which it would previously have tried to refund.
    const { data: prior } = await db
      .from('orders')
      .select('status, cancelled_reason')
      .eq('id', req.params.id)
      .maybeSingle();
    if (!prior) return reply.code(404).send({ ok: false, error: 'order not found' });

    const { data: claimed } = await db
      .from('orders')
      .update({ status: 'cancelled', cancelled_reason: 'cancelled by request' })
      .eq('id', req.params.id)
      .in('status', CANCELLABLE_STATUSES)
      .select('id')
      .maybeSingle();

    if (!claimed) {
      return reply
        .code(409)
        .send({ ok: false, error: `cannot cancel from status '${prior.status}'` });
    }

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
    if (errors.length) {
      // A courier still on the way outranks the claim: put the order back
      // exactly where it was, reason included, and refund nothing.
      await db
        .from('orders')
        .update({ status: prior.status, cancelled_reason: prior.cancelled_reason })
        .eq('id', req.params.id);
      return reply.code(409).send({ ok: false, errors });
    }

    // Release or refund the money too. Cancelling the couriers but leaving a
    // customer's money on a dead order is the complaint that ends a young
    // marketplace.
    const money = await payments.voidOrder(req.params.id, 'order cancelled');

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
 * Stripe's copy of news the app has usually already told us.
 *
 * The app calls confirm-payment the instant the sheet closes, but a phone that
 * is killed — or walks into a lift — between paying and telling us leaves a
 * charged customer whose courier was never sent, and nothing else in the
 * system would ever notice. This is that backstop, and it runs the identical
 * path so the two can never disagree about what a payment leads to.
 */
app.post('/webhooks/stripe', async (req, reply) => {
  if (!config.stripeWebhookSecret) {
    // With no secret there is nothing to verify against, and an unsigned POST
    // here dispatches couriers on demand. Refuse rather than trust.
    req.log.warn({ ip: req.ip }, 'stripe webhook received but no signing secret is configured');
    return reply.code(503).send({ ok: false, error: 'stripe webhooks are not configured' });
  }

  const rawBody: Buffer = (req as any).rawBody ?? Buffer.from('');
  const signature = String(req.headers['stripe-signature'] ?? '');
  if (!verifyStripeSignature(rawBody, signature, config.stripeWebhookSecret)) {
    req.log.warn({ ip: req.ip }, 'stripe webhook signature rejected');
    return reply.code(401).send({ ok: false, error: 'bad signature' });
  }

  const event = (req.body ?? {}) as any;

  // A test-mode event must never dispatch a real courier — but the mode that
  // matters is the KEY's, not NODE_ENV's. Gating on NODE_ENV meant a box
  // deployed as production while still holding an sk_test_ key rejected every
  // event it was capable of receiving, and 202'd it so Stripe never retried:
  // the whole backstop silently became a no-op. Compare like with like.
  const keyIsLive = (config.payments.STRIPE_SECRET_KEY ?? '').startsWith('sk_live_');
  if (typeof event.livemode === 'boolean' && event.livemode !== keyIsLive) {
    req.log.error(
      { id: event.id, type: event.type, eventLivemode: event.livemode, keyIsLive },
      'stripe webhook rejected: event mode does not match the configured key',
    );
    return reply.code(400).send({ ok: false, error: 'event/key mode mismatch' });
  }

  // Idempotency ledger, claimed in two phases.
  //
  // Recording the id and then doing the work meant any mid-flight failure was
  // unrecoverable: the route returns 500 to ask for a retry, but the retry hit
  // the unique violation and was told `deduped`, so Stripe retired an event
  // whose work never happened. `processed_at` is what separates "already done"
  // from "started and died" — claim the row now, stamp it only when the work
  // is finished.
  let ledgerId: string | undefined;
  if (event.id) {
    const { data: claimed, error: dedupErr } = await db
      .from('stripe_events')
      .insert({ event_id: event.id, type: event.type, livemode: event.livemode ?? null })
      .select('event_id')
      .maybeSingle();

    if (dedupErr) {
      if ((dedupErr as { code?: string }).code === '23505') {
        const { data: prior } = await db
          .from('stripe_events')
          .select('processed_at')
          .eq('event_id', event.id)
          .maybeSingle();
        // Finished before: genuinely a duplicate.
        if (prior?.processed_at) return { ok: true, deduped: true };
        // Claimed but never completed — a previous attempt died. Take it again.
        req.log.warn({ id: event.id }, 'reprocessing a stripe event whose prior attempt did not finish');
      } else {
        // Don't silently drop the event on a write failure — let Stripe retry.
        req.log.error({ err: dedupErr, id: event.id }, 'stripe_events insert failed');
        return reply.code(500).send({ ok: false });
      }
    }
    ledgerId = claimed?.event_id ?? event.id;
  }

  /** Close out the ledger row. Only a stamped row may be deduped away. */
  const settleLedger = async (error?: string) => {
    if (!ledgerId) return;
    await db
      .from('stripe_events')
      .update({ processed_at: new Date().toISOString(), error: error ?? null })
      .eq('event_id', ledgerId);
  };

  // Reconcile money that moved backwards, so the DB stops reporting captured
  // funds that were refunded/disputed (which would otherwise let a payout go
  // out on money we no longer hold).
  if (event.type === 'payment_intent.payment_failed') {
    const intentRef = event.data?.object?.id;
    if (intentRef) {
      await db
        .from('payments')
        .update({
          status: 'failed',
          last_error: event.data?.object?.last_payment_error?.message ?? 'payment failed',
        })
        .eq('provider', paymentProvider.name)
        .eq('provider_intent_ref', intentRef);
    }
    await settleLedger();
    return { ok: true, reconciled: event.type };
  }
  if (event.type === 'charge.refunded') {
    const charge = event.data?.object ?? {};
    const intentRef = charge.payment_intent;
    if (intentRef) {
      const fully = (charge.amount_refunded ?? 0) >= (charge.amount ?? 0);
      await db
        .from('payments')
        .update({
          status: fully ? 'refunded' : 'partially_refunded',
          refunded_cents: charge.amount_refunded ?? 0,
        })
        .eq('provider', paymentProvider.name)
        .eq('provider_intent_ref', intentRef);
    }
    await settleLedger();
    return { ok: true, reconciled: event.type };
  }
  if (event.type === 'charge.dispute.created') {
    const dispute = event.data?.object ?? {};
    if (dispute.charge) {
      await db
        .from('payments')
        .update({ last_error: `dispute ${dispute.id} (${dispute.reason ?? 'unknown'})` })
        .eq('provider', paymentProvider.name)
        .eq('charge_ref', dispute.charge);
    }
    await settleLedger();
    return { ok: true, reconciled: event.type };
  }

  if (event.type !== 'payment_intent.succeeded') {
    await settleLedger();
    return { ok: true, ignored: event.type };
  }

  const intentRef = event.data?.object?.id;
  const { data: payment, error: lookupError } = await db
    .from('payments')
    .select('order_id')
    .eq('provider', paymentProvider.name)
    .eq('provider_intent_ref', intentRef)
    .maybeSingle();

  // A lookup that failed is not an intent we do not know, and the 200 below
  // would retire this event at Stripe for good. 500 so it comes back — and
  // deliberately WITHOUT settling the ledger, so the retry re-claims the row
  // instead of being deduped away.
  if (lookupError) {
    req.log.error({ err: lookupError, intentRef }, 'stripe webhook lookup failed');
    return reply.code(500).send({ ok: false });
  }

  // An intent we do not know is not an error — the same Stripe account can be
  // signing for something else. Acknowledge it so Stripe stops retrying.
  if (!payment?.order_id) {
    req.log.warn({ intentRef }, 'stripe webhook for an unknown intent');
    await settleLedger('no matching payment');
    return { ok: true, ignored: 'no matching payment' };
  }

  try {
    const result = await confirmAndDispatch(db, orders, payments, payment.order_id, req.log);

    // Stripe is telling us this intent succeeded. If our own read of it says
    // there is no intent, or that it is not paid, the two disagree about real
    // money — and answering 200 is how Stripe is told to stop mentioning it.
    // The sweep (scripts/sweep.mjs) is the long-stop, but the retry is the
    // fast path — so leave the ledger unsettled and let Stripe come back.
    if (['no_intent', 'unpaid', 'processing'].includes(result.outcome)) {
      req.log.error(
        { orderId: payment.order_id, outcome: result.outcome },
        'stripe reports a succeeded intent we do not see as paid',
      );
      return reply.code(500).send({ ok: false, outcome: result.outcome });
    }

    // 'dispatch_failed' stays a 200: the payment records agree with Stripe, and
    // no amount of redelivery conjures courier coverage. It is the customer's
    // to cancel and the portal's to retry. Settled so a replay is a no-op —
    // the sweep, not Stripe, is what re-attempts the dispatch.
    req.log.info({ orderId: payment.order_id, result: result.outcome }, 'stripe webhook applied');
    await settleLedger(result.outcome === 'dispatch_failed' ? 'dispatch_failed' : undefined);
    return { ok: true, ...result };
  } catch (err) {
    // 500 so Stripe retries: a paid order with no courier is worth another go.
    // Ledger left unsettled on purpose — that is what makes the retry work.
    req.log.error({ err, orderId: payment.order_id }, 'stripe webhook could not be applied');
    return reply.code(500).send({ ok: false });
  }
});

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

  // Verify BEFORE persisting. This route is unauthenticated by design, so
  // storing the body before the signature check let anyone POST unbounded junk
  // straight into delivery_events (storage exhaustion / table pollution).
  if (!result.signatureValid) {
    req.log.warn({ provider: provider.name, ip: req.ip }, 'webhook signature rejected');
    return reply.code(401).send({ error: 'bad signature' });
  }

  // A handled status event with no id can't be deduped — the (provider,
  // event_id) unique index is partial on event_id IS NOT NULL, so a null id
  // never collides and would replay forever. Reject it.
  if (result.event && (result.event.eventId === undefined || result.event.eventId === null)) {
    req.log.warn({ provider: provider.name }, 'webhook event missing id; rejecting to prevent replay');
    return reply.code(400).send({ error: 'missing event id' });
  }

  let payload: unknown = {};
  try {
    payload = JSON.parse(rawBody.toString('utf8'));
  } catch {
    /* keep {} — the raw bytes are what matter for replay */
  }

  const { data: inserted } = await db
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

  // The unique index turning the insert into a no-op means we have SEEN this
  // event — not that we finished it. Treating those as the same thing made the
  // 500 below unreachable in practice: the provider retried, the retry was
  // deduped, and a leg stayed frozen wherever the failed attempt left it.
  // processed_at is the difference, so consult it before dropping a redelivery.
  let landed = inserted;
  if (!landed) {
    const { data: prior } = await db
      .from('delivery_events')
      .select('id, processed_at')
      .eq('provider', provider.name)
      .eq('event_id', result.event?.eventId ?? '')
      .maybeSingle();
    if (!prior || prior.processed_at) {
      return { ok: true, deduped: true };
    }
    req.log.warn(
      { provider: provider.name, eventId: result.event?.eventId },
      'reprocessing a carrier event whose prior attempt did not finish',
    );
    landed = { id: prior.id };
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
  .then(() => {
    // Check the APNs key at boot rather than on the first notification. A key
    // that cannot be read disables push silently, so the only signal would
    // otherwise be a customer never hearing their clothes were ready.
    const apns = push.status();
    if (!apns.configured) {
      app.log.error({ reason: apns.reason }, 'APNs is NOT usable — push notifications will not send');
    }
    app.log.info(
      { providers: chain.active().map((p) => p.name), push: apns.configured },
      'dispatch up',
    );
  })
  .catch((err) => {
    app.log.error(err);
    process.exit(1);
  });
