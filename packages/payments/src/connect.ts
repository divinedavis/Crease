import { PaymentProviderError } from './types.js';

/**
 * Paying partner cleaners.
 *
 * Crease is the merchant of record: the customer pays us, we pay the shop.
 * That is the right structure — it means one card charge, one refund path, and
 * the customer never sees a stranger's business name on their statement — but
 * it also means chargebacks land on us, not on the cleaner.
 *
 * Payouts use **separate transfers** rather than destination charges, for
 * three reasons specific to this business:
 *
 *  - The final amount is unknown at authorization. A destination charge fixes
 *    the split when the intent is created, which is before anyone has counted
 *    the bag.
 *  - An order can end up with two payments (the original hold plus an approved
 *    difference). One transfer per order settles the whole thing cleanly.
 *  - The shop's cut applies to the cleaning subtotal only. Delivery and
 *    service fees stay with us because they pay the courier.
 */

export interface ConnectAccount {
  accountRef: string;
  /** Stripe has everything it needs; the shop can be paid. */
  payoutsEnabled: boolean;
  chargesEnabled: boolean;
  detailsSubmitted: boolean;
  /** Outstanding onboarding requirements, if any. */
  requirements: string[];
}

export interface TransferResult {
  transferRef: string;
  amountCents: number;
}

export interface ConnectProvider {
  readonly name: string;
  isConfigured(): boolean;
  createAccount(input: { email?: string; businessName: string; country?: string }): Promise<ConnectAccount>;
  /** Hosted onboarding. Links are single-use and short-lived. */
  onboardingLink(accountRef: string, returnUrl: string, refreshUrl: string): Promise<string>;
  getAccount(accountRef: string): Promise<ConnectAccount>;
  transfer(input: {
    accountRef: string;
    amountCents: number;
    /** Groups every movement for one order. */
    transferGroup: string;
    /**
     * The charge this transfer is funded by. Without it Stripe pays out of the
     * platform's available balance, which on a new account is zero and on any
     * account lags settlement — so transfers would fail for reasons that have
     * nothing to do with the order.
     */
    sourceChargeRef?: string;
    idempotencyKey: string;
  }): Promise<TransferResult>;
}

/**
 * The shop's share of an order.
 *
 * Commission applies to the cleaning subtotal only. Delivery and service fees
 * are ours because they fund the couriers — taking a commission on money that
 * is already spoken for would quietly under-pay the shop on every order.
 */
export function payoutCents(subtotalCents: number, commissionBps: number): number {
  const commission = Math.round((subtotalCents * commissionBps) / 10_000);
  return Math.max(0, subtotalCents - commission);
}

const API = 'https://api.stripe.com/v1';

export class StripeConnect implements ConnectProvider {
  readonly name = 'stripe';

  constructor(
    private readonly opts: { secretKey?: string; fetchImpl?: typeof fetch },
  ) {}

  isConfigured(): boolean {
    return Boolean(this.opts.secretKey);
  }

  async createAccount(input: { email?: string; businessName: string; country?: string }) {
    const body: Record<string, string> = {
      type: 'express',
      country: input.country ?? 'US',
      'business_profile[name]': input.businessName,
      // 7211 is the card-network code for laundry and dry cleaning services.
      'business_profile[mcc]': '7211',
      'capabilities[transfers][requested]': 'true',
    };
    if (input.email) body.email = input.email;
    return this.toAccount(await this.call('/accounts', body));
  }

  async onboardingLink(accountRef: string, returnUrl: string, refreshUrl: string) {
    const res = await this.call('/account_links', {
      account: accountRef,
      type: 'account_onboarding',
      return_url: returnUrl,
      refresh_url: refreshUrl,
    });
    return res.url as string;
  }

  async getAccount(accountRef: string) {
    return this.toAccount(await this.call(`/accounts/${accountRef}`, undefined, undefined, 'GET'));
  }

  async transfer(input: {
    accountRef: string;
    amountCents: number;
    transferGroup: string;
    sourceChargeRef?: string;
    idempotencyKey: string;
  }): Promise<TransferResult> {
    const body: Record<string, string> = {
      amount: String(input.amountCents),
      currency: 'usd',
      destination: input.accountRef,
      transfer_group: input.transferGroup,
    };
    if (input.sourceChargeRef) body.source_transaction = input.sourceChargeRef;

    const res = await this.call('/transfers', body, input.idempotencyKey);
    return { transferRef: res.id, amountCents: res.amount };
  }

  private toAccount(a: any): ConnectAccount {
    return {
      accountRef: a.id,
      payoutsEnabled: Boolean(a.payouts_enabled),
      chargesEnabled: Boolean(a.charges_enabled),
      detailsSubmitted: Boolean(a.details_submitted),
      requirements: [
        ...(a.requirements?.currently_due ?? []),
        ...(a.requirements?.past_due ?? []),
      ],
    };
  }

  private async call(
    path: string,
    body?: Record<string, string>,
    idempotencyKey?: string,
    method = 'POST',
  ): Promise<any> {
    if (!this.isConfigured()) {
      throw new PaymentProviderError('stripe connect is not configured', { retryable: false });
    }
    const headers: Record<string, string> = {
      authorization: `Bearer ${this.opts.secretKey}`,
      'content-type': 'application/x-www-form-urlencoded',
    };
    if (idempotencyKey) headers['idempotency-key'] = idempotencyKey;

    const res = await (this.opts.fetchImpl ?? fetch)(`${API}${path}`, {
      method,
      headers,
      body: body ? new URLSearchParams(body).toString() : undefined,
    });
    const json: any = await res.json().catch(() => ({}));
    if (!res.ok) {
      const err = json.error ?? {};
      throw new PaymentProviderError(err.message ?? `stripe ${method} ${path} ${res.status}`, {
        retryable: res.status >= 500 || res.status === 429,
        code: err.code,
      });
    }
    return json;
  }
}

/** In-memory Connect, enforcing the same preconditions Stripe does. */
export class MockConnect implements ConnectProvider {
  readonly name = 'mock';
  private accounts = new Map<string, ConnectAccount>();
  private transfers = new Map<string, TransferResult>();
  private seq = 0;

  isConfigured(): boolean {
    return true;
  }

  async createAccount(input: { businessName: string }): Promise<ConnectAccount> {
    const id = `mock_acct_${++this.seq}`;
    // A fresh account cannot be paid yet — the shop still has to onboard.
    const account: ConnectAccount = {
      accountRef: id,
      payoutsEnabled: false,
      chargesEnabled: false,
      detailsSubmitted: false,
      requirements: ['external_account', 'individual.verification.document'],
    };
    this.accounts.set(id, account);
    return account;
  }

  async onboardingLink(accountRef: string): Promise<string> {
    return `https://connect.crease.local/onboard/${accountRef}`;
  }

  async getAccount(accountRef: string): Promise<ConnectAccount> {
    const a = this.accounts.get(accountRef);
    if (!a) throw new PaymentProviderError(`unknown account ${accountRef}`, { retryable: false });
    return a;
  }

  /** Test hook: pretend the shop finished onboarding. */
  completeOnboarding(accountRef: string) {
    const a = this.accounts.get(accountRef);
    if (a) {
      a.payoutsEnabled = true;
      a.chargesEnabled = true;
      a.detailsSubmitted = true;
      a.requirements = [];
    }
  }

  async transfer(input: {
    accountRef: string;
    amountCents: number;
    transferGroup: string;
    idempotencyKey: string;
  }): Promise<TransferResult> {
    const replay = this.transfers.get(input.idempotencyKey);
    if (replay) return replay;

    const account = await this.getAccount(input.accountRef);
    if (!account.payoutsEnabled) {
      throw new PaymentProviderError('destination account cannot receive payouts yet', {
        retryable: false,
        code: 'account_not_onboarded',
      });
    }
    if (input.amountCents <= 0) {
      throw new PaymentProviderError('transfer amount must be positive', { retryable: false });
    }

    const result = { transferRef: `mock_tr_${++this.seq}`, amountCents: input.amountCents };
    this.transfers.set(input.idempotencyKey, result);
    return result;
  }
}

export function buildConnectProvider(env: {
  STRIPE_SECRET_KEY?: string;
  ENABLE_MOCK_PAYMENTS?: string;
}): ConnectProvider {
  const stripe = new StripeConnect({ secretKey: env.STRIPE_SECRET_KEY });
  if (stripe.isConfigured() && env.ENABLE_MOCK_PAYMENTS !== 'true') return stripe;
  return new MockConnect();
}
