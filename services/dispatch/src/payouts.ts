import type { SupabaseClient } from '@supabase/supabase-js';
import { PaymentProviderError, payoutCents, type ConnectProvider } from '@crease/payments';

/**
 * Paying the shop.
 *
 * Runs after the customer's money is captured, never before — paying a shop
 * out of money we have not collected turns a failed capture into a real loss.
 *
 * The amounts are snapshotted onto the payout row rather than recomputed on
 * read. A shop that renegotiates its commission must not retroactively change
 * what it was owed on orders already completed, and "why is this number
 * different from last month" is a conversation best answered with a stored
 * figure rather than a recomputation.
 */
export class PayoutService {
  constructor(
    private readonly db: SupabaseClient,
    private readonly connect: ConnectProvider,
    private readonly log: { info: Function; warn: Function; error: Function },
  ) {}

  /** Create the Connect account for a shop and return an onboarding link. */
  async startOnboarding(cleanerId: string, returnUrl: string, refreshUrl: string) {
    const { data: cleaner, error } = await this.db
      .from('cleaners')
      .select('id, name, email, stripe_account_id')
      .eq('id', cleanerId)
      .single();
    if (error || !cleaner) throw new Error(`cleaner ${cleanerId} not found`);

    let accountRef = cleaner.stripe_account_id;
    if (!accountRef) {
      const account = await this.connect.createAccount({
        businessName: cleaner.name,
        email: cleaner.email ?? undefined,
      });
      accountRef = account.accountRef;
      await this.db
        .from('cleaners')
        .update({ stripe_account_id: accountRef })
        .eq('id', cleanerId);
    }

    const url = await this.connect.onboardingLink(accountRef!, returnUrl, refreshUrl);
    this.log.info({ cleanerId, accountRef }, 'connect onboarding started');
    return { accountRef, url };
  }

  /** Re-read Stripe's view of the account and cache what the portal needs. */
  async refreshAccount(cleanerId: string) {
    const { data: cleaner } = await this.db
      .from('cleaners')
      .select('id, stripe_account_id')
      .eq('id', cleanerId)
      .single();
    if (!cleaner?.stripe_account_id) return null;

    const account = await this.connect.getAccount(cleaner.stripe_account_id);
    await this.db
      .from('cleaners')
      .update({
        payouts_enabled: account.payoutsEnabled,
        connect_requirements: account.requirements,
      })
      .eq('id', cleanerId);
    return account;
  }

  /**
   * Settle the shop's share for an order.
   *
   * Idempotent on the order: the unique index refuses a second payout row, and
   * the transfer itself is keyed on that row's id, so a retry after a timeout
   * cannot pay a shop twice for the same bag.
   */
  async payoutOrder(orderId: string) {
    const { data: order } = await this.db
      .from('orders')
      .select('id, short_code, cleaner_id, subtotal_cents, estimate_subtotal_cents, status, cleaner:cleaners(id, name, commission_bps, stripe_account_id, payouts_enabled)')
      .eq('id', orderId)
      .single();
    if (!order) throw new Error(`order ${orderId} not found`);

    const cleaner = order.cleaner as any;

    const { data: existing } = await this.db
      .from('payouts')
      .select('*')
      .eq('order_id', orderId)
      .maybeSingle();
    if (existing?.status === 'paid') return existing;

    // Only pay out of money we actually hold.
    // charge_ref must be in the select list — the transfer below funds itself
    // from that charge, and a silently-undefined column would fall back to
    // paying out of the platform balance instead.
    const { data: payments } = await this.db
      .from('payments')
      .select('status, captured_cents, provider_intent_ref, charge_ref, kind')
      .eq('order_id', orderId);

    const capturedTotal = (payments ?? [])
      .filter((p) => p.status === 'captured' || p.status === 'partially_refunded')
      .reduce((n, p) => n + (p.captured_cents ?? 0), 0);

    if (capturedTotal <= 0) {
      throw new Error(`order ${orderId} has no captured funds to pay out from`);
    }

    const subtotal = order.subtotal_cents ?? order.estimate_subtotal_cents;
    const amount = payoutCents(subtotal, cleaner.commission_bps);

    const row =
      existing ??
      (
        await this.db
          .from('payouts')
          .insert({
            order_id: orderId,
            cleaner_id: cleaner.id,
            provider: this.connect.name,
            subtotal_cents: subtotal,
            commission_bps: cleaner.commission_bps,
            amount_cents: amount,
            status: 'pending',
          })
          .select()
          .single()
      ).data;

    if (!row) throw new Error('could not create payout row');

    // A shop that has not finished onboarding cannot receive money yet. That
    // is not a failure — it is a pending payout and a nag in the portal.
    if (!cleaner.stripe_account_id || !cleaner.payouts_enabled) {
      await this.db
        .from('payouts')
        .update({ status: 'pending', last_error: 'cleaner has not completed payout onboarding' })
        .eq('id', row.id);
      this.log.warn({ orderId, cleanerId: cleaner.id }, 'payout held — onboarding incomplete');
      return { ...row, status: 'pending' };
    }

    if (amount <= 0) {
      await this.db.from('payouts').update({ status: 'skipped' }).eq('id', row.id);
      return { ...row, status: 'skipped' };
    }

    // Never transfer more than we actually captured, and never let a missing
    // source charge fund the transfer from the platform balance — Stripe does
    // exactly that when source_transaction is omitted. Either case holds the
    // payout as pending for the sweep/a human rather than paying out money we
    // cannot trace to this order's charge.
    const primary = (payments ?? []).find((p) => p.kind === 'primary');
    const sourceChargeRef: string | undefined = (primary as any)?.charge_ref ?? undefined;
    if (amount > capturedTotal) {
      await this.db
        .from('payouts')
        .update({ status: 'pending', last_error: `payout ${amount} exceeds captured ${capturedTotal}` })
        .eq('id', row.id);
      this.log.warn({ orderId, amount, capturedTotal }, 'payout held — exceeds captured funds');
      return { ...row, status: 'pending' };
    }
    if (!sourceChargeRef) {
      await this.db
        .from('payouts')
        .update({ status: 'pending', last_error: 'no source charge to fund the transfer' })
        .eq('id', row.id);
      this.log.warn({ orderId }, 'payout held — no source charge (would draw the platform balance)');
      return { ...row, status: 'pending' };
    }

    try {
      const transfer = await this.connect.transfer({
        accountRef: cleaner.stripe_account_id,
        amountCents: amount,
        transferGroup: `order_${order.short_code}`,
        sourceChargeRef,
        idempotencyKey: row.id,
      });

      const { data: paid } = await this.db
        .from('payouts')
        .update({
          status: 'paid',
          provider_transfer_ref: transfer.transferRef,
          paid_at: new Date().toISOString(),
          last_error: null,
        })
        .eq('id', row.id)
        .select()
        .single();

      this.log.info(
        { orderId, cleanerId: cleaner.id, amount, transfer: transfer.transferRef },
        'shop paid',
      );
      return paid;
    } catch (err) {
      const retryable = err instanceof PaymentProviderError ? err.opts.retryable : false;
      await this.db
        .from('payouts')
        .update({
          // Retryable failures stay pending so a sweep picks them up; a hard
          // rejection is terminal and needs a person to look at it.
          status: retryable ? 'pending' : 'failed',
          last_error: (err as Error).message,
        })
        .eq('id', row.id);
      this.log.error({ orderId, err }, 'payout failed');
      throw err;
    }
  }

  /** Retry payouts that are still owed — onboarding finished, transient errors. */
  async sweepPending(limit = 50) {
    const { data: pending } = await this.db
      .from('payouts')
      .select('order_id')
      .in('status', ['pending', 'failed'])
      .order('created_at')
      .limit(limit);

    const results = { attempted: 0, paid: 0, stillOwed: 0 };
    for (const p of pending ?? []) {
      results.attempted++;
      try {
        const out = await this.payoutOrder(p.order_id);
        if ((out as any)?.status === 'paid') results.paid++;
        else results.stillOwed++;
      } catch {
        results.stillOwed++;
      }
    }
    this.log.info(results, 'payout sweep complete');
    return results;
  }
}
