import { createHmac, timingSafeEqual } from 'node:crypto';
import type {
  AuthorizeRequest,
  CaptureRequest,
  PaymentProvider,
  PaymentState,
  PaymentStatus,
} from './types.js';
import { OverAuthorizationError, PaymentProviderError } from './types.js';

/**
 * Stripe, via authorize-then-capture.
 *
 * `capture_method: 'manual'` holds the funds at checkout; the capture happens
 * after the cleaner counts the bag. Stripe permits capturing *less* than the
 * authorized amount — the balance is released — but not more. That asymmetry
 * is the whole design constraint: under-capture is free, over-capture is a
 * second transaction and a second customer decision.
 *
 * Uses the REST API directly rather than the SDK to keep the droplet's
 * dependency footprint small; the surface used here is four endpoints.
 */

const API = 'https://api.stripe.com/v1';

const STATUS_MAP: Record<string, PaymentStatus> = {
  requires_payment_method: 'requires_payment_method',
  requires_confirmation: 'requires_payment_method',
  requires_action: 'requires_payment_method',
  // Not the same thing as the three above, and the column has no way to say
  // so: an intent Stripe is still settling has usually already charged the
  // card, and PaymentSheet reports .completed while it does — normal after
  // 3DS, Link, or any redirect method. Anything that would turn a customer
  // away, or hand out a second intent, must read providerStatus instead of
  // narrowing on this.
  processing: 'requires_payment_method',
  requires_capture: 'authorized',
  succeeded: 'captured',
  canceled: 'cancelled',
};

export interface StripeOptions {
  secretKey?: string;
  fetchImpl?: typeof fetch;
}

export class StripeProvider implements PaymentProvider {
  readonly name = 'stripe';
  private readonly fetchImpl: typeof fetch;

  constructor(private readonly opts: StripeOptions) {
    this.fetchImpl = opts.fetchImpl ?? fetch;
  }

  isConfigured(): boolean {
    return Boolean(this.opts.secretKey);
  }

  async authorize(req: AuthorizeRequest): Promise<PaymentState> {
    const body: Record<string, string> = {
      amount: String(req.amountCents),
      currency: req.currency,
      // Manual by default: the cleaning total is not known at checkout, so the
      // hold is placed first and captured after intake. A caller that already
      // knows the final amount — the delivery fee does — passes immediate.
      capture_method: req.captureMethod === 'immediate' ? 'automatic' : 'manual',
      description: req.description,
      'metadata[order_id]': req.orderId,
    };
    if (req.customerRef) body.customer = req.customerRef;
    if (req.paymentMethodRef) {
      body.payment_method = req.paymentMethodRef;
      body.confirm = 'true';
      // The customer is not at the keyboard when the dispatcher runs this.
      body.off_session = 'true';
    }

    // The order's leg id doubles as the idempotency key, so a retried request
    // after a timeout returns the original intent rather than a second hold.
    const res = await this.call('/payment_intents', body, req.externalId);
    return this.toState(res);
  }

  async capture(req: CaptureRequest): Promise<PaymentState> {
    const current = await this.get(req.paymentIntentRef);
    const authorized = current.authorizedCents ?? 0;

    // Check before calling Stripe so the caller gets a typed error it can
    // route into the approval flow, rather than a generic 400 from the API.
    if (req.amountCents > authorized) {
      throw new OverAuthorizationError(authorized, req.amountCents);
    }

    const res = await this.call(
      `/payment_intents/${req.paymentIntentRef}/capture?expand[]=latest_charge`,
      { amount_to_capture: String(req.amountCents) },
    );
    return this.toState(res);
  }

  /**
   * A second intent for the amount above the original hold.
   *
   * Stripe's incremental authorization is limited to card-present and a few
   * other flows, so for an online order the workable path is a fresh charge
   * on the saved payment method — which is correct anyway, because the
   * customer has by then explicitly approved the higher total.
   */
  async chargeDifference(req: AuthorizeRequest): Promise<PaymentState> {
    const body: Record<string, string> = {
      amount: String(req.amountCents),
      currency: req.currency,
      capture_method: 'automatic',
      confirm: 'true',
      off_session: 'true',
      description: req.description,
      'metadata[order_id]': req.orderId,
      'metadata[kind]': 'intake_difference',
    };
    if (req.customerRef) body.customer = req.customerRef;
    if (req.paymentMethodRef) body.payment_method = req.paymentMethodRef;

    const res = await this.call('/payment_intents', body, req.externalId);
    return this.toState(res);
  }

  async cancel(ref: string): Promise<PaymentState> {
    return this.toState(await this.call(`/payment_intents/${ref}/cancel`, {}));
  }

  async refund(ref: string, amountCents?: number): Promise<PaymentState> {
    const body: Record<string, string> = { payment_intent: ref };
    if (amountCents != null) body.amount = String(amountCents);
    await this.call('/refunds', body);
    return this.get(ref);
  }

  async get(ref: string): Promise<PaymentState> {
    // latest_charge must be expanded to see refunds — see toState.
    return this.toState(
      await this.call(`/payment_intents/${ref}?expand[]=latest_charge`, undefined, undefined, 'GET'),
    );
  }

  private toState(pi: any): PaymentState {
    // Refunds live on the charge, not the intent.
    //
    // Older API versions exposed `charges.data[]` inline on the PaymentIntent;
    // current ones (verified against 2026-07-29.dahlia) removed it in favour of
    // `latest_charge`, which is a bare id unless expanded. Reading the old
    // shape does not error — it silently yields 0, so a refunded payment would
    // keep reporting itself as fully captured and our records would disagree
    // with Stripe's about real money. Both shapes are handled so the adapter
    // survives an account on either version.
    const expandedCharge = typeof pi.latest_charge === 'object' ? pi.latest_charge : null;
    const refunded =
      expandedCharge?.amount_refunded ??
      pi.charges?.data?.reduce((n: number, c: any) => n + (c.amount_refunded ?? 0), 0) ??
      0;
    const captured = pi.amount_received ?? 0;

    let status = STATUS_MAP[pi.status] ?? 'failed';
    if (status === 'captured' && refunded > 0) {
      status = refunded >= captured ? 'refunded' : 'partially_refunded';
    }

    return {
      paymentIntentRef: pi.id,
      chargeRef: expandedCharge?.id ?? (typeof pi.latest_charge === 'string' ? pi.latest_charge : undefined),
      status,
      providerStatus: pi.status,
      // amount_capturable is what remains holdable; on a captured intent it
      // drops to zero, so fall back to the intent amount for the audit trail.
      authorizedCents: pi.amount_capturable || pi.amount,
      capturedCents: captured,
      refundedCents: refunded,
      clientSecret: pi.client_secret,
      requiresAction: pi.status === 'requires_action',
      error: pi.last_payment_error?.message,
    };
  }

  private async call(
    path: string,
    body?: Record<string, string>,
    idempotencyKey?: string,
    method: string = 'POST',
  ): Promise<any> {
    if (!this.isConfigured()) {
      throw new PaymentProviderError('stripe is not configured', { retryable: false });
    }

    const headers: Record<string, string> = {
      authorization: `Bearer ${this.opts.secretKey}`,
      'content-type': 'application/x-www-form-urlencoded',
    };
    if (idempotencyKey) headers['idempotency-key'] = idempotencyKey;

    const res = await this.fetchImpl(`${API}${path}`, {
      method,
      headers,
      body: body ? new URLSearchParams(body).toString() : undefined,
    });

    const json: any = await res.json().catch(() => ({}));
    if (!res.ok) {
      const err = json.error ?? {};
      throw new PaymentProviderError(err.message ?? `stripe ${method} ${path} ${res.status}`, {
        // A card decline is final; rate limits and 5xx are worth retrying.
        retryable: res.status >= 500 || res.status === 429,
        code: err.code,
        declineCode: err.decline_code,
      });
    }
    return json;
  }
}

/**
 * Is this callback really from Stripe?
 *
 * Stripe signs `${timestamp}.${rawBody}`, not the body on its own, and puts
 * the digest in a compound header that carries several v1 entries while a
 * secret is being rotated — so any one of them matching is a match.
 *
 * The timestamp is inside the signed payload for a reason, and checking its
 * age is not optional here: a captured payload otherwise stays valid forever,
 * and replaying a payment_intent.succeeded dispatches a courier we never
 * collected for.
 */
export function verifyStripeSignature(
  rawBody: Buffer,
  header: string,
  secret: string,
  toleranceSeconds = 300,
): boolean {
  const parts = header.split(',').map((p) => p.trim().split('='));
  const timestamp = parts.find((p) => p[0] === 't')?.[1];
  const sent = parts.filter((p) => p[0] === 'v1').map((p) => p[1]);
  if (!timestamp || !sent.length) return false;

  const age = Math.abs(Date.now() / 1000 - Number(timestamp));
  if (!Number.isFinite(age) || age > toleranceSeconds) return false;

  const expected = createHmac('sha256', secret).update(`${timestamp}.`).update(rawBody).digest('hex');
  return sent.some(
    (sig) => sig.length === expected.length && timingSafeEqual(Buffer.from(sig), Buffer.from(expected)),
  );
}
