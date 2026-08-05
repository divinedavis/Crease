/**
 * Payment contract for an order whose price is not known at checkout.
 *
 * This is the part of dry cleaning that does not fit an e-commerce flow. The
 * customer checks out before anyone has seen the garments, so the amount at
 * checkout is an estimate and the real number arrives two hours later when
 * the cleaner counts the bag. The money model has to be authorize-then-capture,
 * and it has to survive the actual total landing above the authorized one.
 */

export type PaymentStatus =
  | 'requires_payment_method'
  | 'authorized'
  | 'captured'
  | 'partially_refunded'
  | 'refunded'
  | 'failed'
  | 'cancelled';

export interface AuthorizeRequest {
  orderId: string;
  /** Idempotency key. Replays must not double-authorize. */
  externalId: string;
  customerRef?: string;
  paymentMethodRef?: string;
  /** What we hold. Usually the estimate plus headroom, not the estimate. */
  amountCents: number;
  currency: string;
  description: string;
  /** 'immediate' when the final amount is already known at checkout. */
  captureMethod?: 'manual' | 'immediate';
}

export interface CaptureRequest {
  paymentIntentRef: string;
  /** The real total from intake. May be under or over the authorization. */
  amountCents: number;
}

export interface PaymentState {
  paymentIntentRef: string;
  /** The underlying charge. Transfers are funded from it directly, so a
   *  payout does not have to wait on the platform's available balance. */
  chargeRef?: string;
  status: PaymentStatus;
  /** The provider's own word, unmapped. `status` is squeezed into an enum with
   *  no value for "in flight", so it cannot tell a payment the bank is still
   *  settling from one that never started — and those two owe the customer
   *  opposite answers. Callers that must distinguish them read this. */
  providerStatus?: string;
  authorizedCents?: number;
  capturedCents?: number;
  refundedCents?: number;
  /** Set when the customer must act (3DS, or re-approving a higher total). */
  clientSecret?: string;
  requiresAction?: boolean;
  error?: string;
}

/**
 * Raised when the intake total exceeds what was authorized.
 *
 * Card networks do not let you capture more than you held. This is not an
 * edge case here — it is the normal consequence of a customer under-estimating
 * their own laundry — so it gets its own error type rather than a generic
 * failure, and the caller is expected to route it into the approval flow.
 */
export class OverAuthorizationError extends Error {
  constructor(
    readonly authorizedCents: number,
    readonly requestedCents: number,
  ) {
    super(
      `capture of ${requestedCents} exceeds authorization of ${authorizedCents}; ` +
        'customer must approve the difference',
    );
    this.name = 'OverAuthorizationError';
  }
}

export class PaymentProviderError extends Error {
  constructor(
    message: string,
    readonly opts: { retryable: boolean; code?: string; declineCode?: string },
  ) {
    super(message);
    this.name = 'PaymentProviderError';
  }
}

export interface PaymentProvider {
  readonly name: string;
  isConfigured(): boolean;
  /** Hold funds without taking them. */
  authorize(req: AuthorizeRequest): Promise<PaymentState>;
  /** Take up to the held amount. Throws OverAuthorizationError above it. */
  capture(req: CaptureRequest): Promise<PaymentState>;
  /** Charge a further amount once the customer has approved it. */
  chargeDifference(req: AuthorizeRequest): Promise<PaymentState>;
  /** Release an uncaptured hold — the order never happened. */
  cancel(paymentIntentRef: string): Promise<PaymentState>;
  refund(paymentIntentRef: string, amountCents?: number): Promise<PaymentState>;
  get(paymentIntentRef: string): Promise<PaymentState>;
}

/**
 * Headroom on the authorization.
 *
 * Authorizing exactly the estimate guarantees a second customer interaction
 * on almost every order, because people underestimate their own laundry. A
 * modest buffer absorbs the common small overage so the happy path stays one
 * tap, while anything larger still routes through explicit approval.
 *
 * Kept below the order's approval threshold on purpose: we never hold more
 * than we would be willing to charge without asking.
 */
export function authorizationAmount(estimateCents: number, thresholdCents: number): number {
  const buffered = Math.ceil(estimateCents * 1.25);
  return Math.min(buffered, estimateCents + thresholdCents);
}
