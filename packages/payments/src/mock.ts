import { randomUUID } from 'node:crypto';
import type {
  AuthorizeRequest,
  CaptureRequest,
  PaymentProvider,
  PaymentState,
} from './types.js';
import { OverAuthorizationError, PaymentProviderError } from './types.js';

/**
 * In-memory payment provider with the same rules as a card network.
 *
 * Enforces the constraints that actually matter — you cannot capture above
 * the authorization, you cannot capture twice, you cannot capture a cancelled
 * hold, you cannot refund more than you took — so the order flow can be
 * exercised end to end before a Stripe account exists, and so those rules are
 * covered by tests rather than discovered in production.
 *
 * `declineOn` makes failures reproducible: any authorization at exactly that
 * amount is declined.
 */
export interface MockPaymentOptions {
  declineOnCents?: number;
}

interface Record_ extends PaymentState {
  captured: boolean;
  cancelled: boolean;
}

export class MockPaymentProvider implements PaymentProvider {
  readonly name = 'mock';
  private readonly store = new Map<string, Record_>();
  private readonly byIdempotencyKey = new Map<string, string>();

  constructor(private readonly opts: MockPaymentOptions = {}) {}

  isConfigured(): boolean {
    return true;
  }

  async authorize(req: AuthorizeRequest): Promise<PaymentState> {
    // Replaying a request must return the original hold, not a second one.
    const seen = this.byIdempotencyKey.get(req.externalId);
    if (seen) return strip(this.store.get(seen)!);

    if (this.opts.declineOnCents != null && req.amountCents === this.opts.declineOnCents) {
      throw new PaymentProviderError('Your card was declined.', {
        retryable: false,
        code: 'card_declined',
        declineCode: 'generic_decline',
      });
    }

    const id = `mock_pi_${randomUUID()}`;
    const rec: Record_ = {
      paymentIntentRef: id,
      status: 'authorized',
      authorizedCents: req.amountCents,
      capturedCents: 0,
      refundedCents: 0,
      captured: false,
      cancelled: false,
    };
    this.store.set(id, rec);
    this.byIdempotencyKey.set(req.externalId, id);
    return strip(rec);
  }

  async capture(req: CaptureRequest): Promise<PaymentState> {
    const rec = this.need(req.paymentIntentRef);
    if (rec.cancelled) {
      throw new PaymentProviderError('cannot capture a cancelled authorization', {
        retryable: false,
      });
    }
    if (rec.captured) {
      throw new PaymentProviderError('already captured', { retryable: false });
    }
    if (req.amountCents > (rec.authorizedCents ?? 0)) {
      throw new OverAuthorizationError(rec.authorizedCents ?? 0, req.amountCents);
    }

    rec.captured = true;
    rec.capturedCents = req.amountCents;
    rec.status = 'captured';
    return strip(rec);
  }

  async chargeDifference(req: AuthorizeRequest): Promise<PaymentState> {
    const seen = this.byIdempotencyKey.get(req.externalId);
    if (seen) return strip(this.store.get(seen)!);

    const id = `mock_pi_${randomUUID()}`;
    const rec: Record_ = {
      paymentIntentRef: id,
      status: 'captured',
      authorizedCents: req.amountCents,
      capturedCents: req.amountCents,
      refundedCents: 0,
      captured: true,
      cancelled: false,
    };
    this.store.set(id, rec);
    this.byIdempotencyKey.set(req.externalId, id);
    return strip(rec);
  }

  async cancel(ref: string): Promise<PaymentState> {
    const rec = this.need(ref);
    if (rec.captured) {
      throw new PaymentProviderError('cannot cancel a captured payment; refund instead', {
        retryable: false,
      });
    }
    rec.cancelled = true;
    rec.status = 'cancelled';
    return strip(rec);
  }

  async refund(ref: string, amountCents?: number): Promise<PaymentState> {
    const rec = this.need(ref);
    if (!rec.captured) {
      throw new PaymentProviderError('cannot refund an uncaptured payment', { retryable: false });
    }
    const amount = amountCents ?? rec.capturedCents ?? 0;
    const alreadyRefunded = rec.refundedCents ?? 0;
    if (amount + alreadyRefunded > (rec.capturedCents ?? 0)) {
      throw new PaymentProviderError('refund exceeds captured amount', { retryable: false });
    }
    rec.refundedCents = alreadyRefunded + amount;
    rec.status = rec.refundedCents >= (rec.capturedCents ?? 0) ? 'refunded' : 'partially_refunded';
    return strip(rec);
  }

  async get(ref: string): Promise<PaymentState> {
    return strip(this.need(ref));
  }

  private need(ref: string): Record_ {
    const rec = this.store.get(ref);
    if (!rec) throw new PaymentProviderError(`unknown payment intent ${ref}`, { retryable: false });
    return rec;
  }
}

function strip(rec: Record_): PaymentState {
  const { captured, cancelled, ...state } = rec;
  return { ...state };
}
