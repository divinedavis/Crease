import type { SupabaseClient } from '@supabase/supabase-js';
import {
  authorizationAmount,
  OverAuthorizationError,
  PaymentProviderError,
  type PaymentProvider,
} from '@crease/payments';

/**
 * Money for an order whose price is not known at checkout.
 *
 * The sequence is: hold at checkout against the estimate plus headroom, then
 * settle once the cleaner has counted the bag. Settling has three outcomes and
 * the middle one is the whole reason this class exists:
 *
 *   under the hold  -> capture the real total, release the rest
 *   over the hold   -> capture what we hold, ask the customer for the rest
 *   never approved  -> release the hold entirely
 *
 * Nothing here charges a customer more than they have agreed to. The headroom
 * on the hold is capped at the order's own approval threshold, so any amount
 * captured without asking is an amount we already decided was small enough not
 * to interrupt them over.
 */
export class PaymentService {
  constructor(
    private readonly db: SupabaseClient,
    private readonly provider: PaymentProvider,
    private readonly log: { info: Function; warn: Function; error: Function },
  ) {}

  /**
   * A PaymentIntent the app can settle with Apple Pay or a card.
   *
   * Crease charges for transport only — the cleaning bill is the shop's, and
   * the customer settles it directly. So this is a plain immediate charge for
   * the delivery fee, not the authorize-then-capture dance the cleaning total
   * needed: the fee is known the moment the tier is chosen, so there is
   * nothing to hold and reprice.
   *
   * Returns the client secret, which is the only thing the app needs and the
   * only thing it is allowed to have.
   */
  async createDeliveryPaymentIntent(orderId: string) {
    const order = await this.loadOrder(orderId);
    const amount = order.delivery_fee_cents;

    if (!amount || amount <= 0) {
      // A zero-price order is a bug, not a free ride. Refuse rather than
      // silently handing back a payable-for-nothing intent.
      throw new Error(`order ${orderId} has no delivery fee to charge`);
    }

    const { data: row, error } = await this.db
      .from('payments')
      .upsert(
        {
          order_id: orderId,
          kind: 'primary',
          provider: this.provider.name,
          status: 'requires_payment_method',
          authorized_cents: amount,
        },
        { onConflict: 'order_id,kind' },
      )
      .select()
      .single();
    if (error) throw new Error(`could not create payment row: ${error.message}`);

    // Already paid — hand back the same intent rather than making a second.
    if (row.status === 'captured' && row.provider_intent_ref) {
      const existing = await this.provider.get(row.provider_intent_ref);
      return { clientSecret: existing.clientSecret, amountCents: amount, alreadyPaid: true };
    }

    const state = await this.provider.authorize({
      orderId,
      externalId: row.id,
      customerRef: order.customer?.payment_customer_ref ?? undefined,
      amountCents: amount,
      currency: 'usd',
      description: `Crease ${order.service_tier ?? 'delivery'} — order ${order.short_code}`,
      captureMethod: 'immediate',
    });

    await this.db
      .from('payments')
      .update({
        status: state.status,
        provider_intent_ref: state.paymentIntentRef,
        authorized_cents: amount,
      })
      .eq('id', row.id);

    this.log.info({ orderId, amount }, 'delivery payment intent created');
    return { clientSecret: state.clientSecret, amountCents: amount, alreadyPaid: false };
  }

  /** Place the hold. Idempotent on the order. */
  async authorizeOrder(orderId: string) {
    const order = await this.loadOrder(orderId);

    const { data: existing } = await this.db
      .from('payments')
      .select('*')
      .eq('order_id', orderId)
      .eq('kind', 'primary')
      .maybeSingle();

    if (existing && ['authorized', 'captured'].includes(existing.status)) {
      return existing;
    }

    const amount = authorizationAmount(
      order.estimate_subtotal_cents + order.delivery_fee_cents + order.service_fee_cents,
      order.approval_threshold_cents,
    );

    // Insert first so the row id can be the idempotency key: a timeout on the
    // provider call then replays to the same hold rather than a second one.
    const { data: row, error } = await this.db
      .from('payments')
      .upsert(
        {
          order_id: orderId,
          kind: 'primary',
          provider: this.provider.name,
          status: 'requires_payment_method',
          authorized_cents: amount,
        },
        { onConflict: 'order_id,kind' },
      )
      .select()
      .single();
    if (error) throw new Error(`could not create payment row: ${error.message}`);

    try {
      const state = await this.provider.authorize({
        orderId,
        externalId: row.id,
        customerRef: order.customer?.payment_customer_ref ?? undefined,
        paymentMethodRef: order.customer?.default_payment_method_ref ?? undefined,
        amountCents: amount,
        currency: 'usd',
        description: `Crease order ${order.short_code}`,
      });

      const { data: updated } = await this.db
        .from('payments')
        .update({
          status: state.status,
          provider_intent_ref: state.paymentIntentRef,
          authorized_cents: state.authorizedCents ?? amount,
        })
        .eq('id', row.id)
        .select()
        .single();

      // A customer with no saved payment method yields an intent that is
      // created but unconfirmed — no funds are held. That is a legitimate
      // state (the app finishes it with the client secret), but it is NOT an
      // authorization, and treating it as one would let an order proceed to
      // dispatch with nothing secured. Say so explicitly rather than letting
      // a truthy row imply money is held.
      if (state.status !== 'authorized') {
        this.log.warn(
          { orderId, status: state.status, requiresAction: state.requiresAction },
          'payment intent created but funds are not held',
        );
        throw new PaymentProviderError(
          `payment not authorized (status '${state.status}') — customer must complete payment`,
          { retryable: false, code: 'not_authorized' },
        );
      }

      this.log.info({ orderId, amount }, 'payment authorized');
      return updated;
    } catch (err) {
      const decline =
        err instanceof PaymentProviderError ? (err.opts.declineCode ?? err.opts.code) : undefined;
      await this.db
        .from('payments')
        .update({ status: 'failed', last_error: (err as Error).message })
        .eq('id', row.id);
      this.log.warn({ orderId, decline }, 'authorization failed');
      throw err;
    }
  }

  /**
   * Settle against the intake total.
   *
   * Returns `{ needsApproval: true }` rather than throwing when the count comes
   * in above the hold — that is an ordinary business outcome, not an error, and
   * the caller turns it into a question for the customer.
   */
  async settleOrder(orderId: string): Promise<{ captured: number; needsApproval: boolean }> {
    const order = await this.loadOrder(orderId);
    const total =
      (order.subtotal_cents ?? order.estimate_subtotal_cents) +
      order.delivery_fee_cents +
      order.service_fee_cents +
      order.tax_cents +
      order.tip_cents;

    const { data: primary } = await this.db
      .from('payments')
      .select('*')
      .eq('order_id', orderId)
      .eq('kind', 'primary')
      .maybeSingle();

    if (!primary?.provider_intent_ref) {
      throw new Error(`order ${orderId} has no authorized payment to settle`);
    }
    if (primary.status === 'captured') {
      return { captured: primary.captured_cents ?? 0, needsApproval: false };
    }

    try {
      const state = await this.provider.capture({
        paymentIntentRef: primary.provider_intent_ref,
        amountCents: total,
      });
      await this.db
        .from('payments')
        .update({
          status: state.status,
          captured_cents: state.capturedCents,
          charge_ref: state.chargeRef,
        })
        .eq('id', primary.id);
      await this.db.from('orders').update({ total_cents: total }).eq('id', orderId);

      this.log.info({ orderId, captured: state.capturedCents }, 'payment captured');
      return { captured: state.capturedCents ?? total, needsApproval: false };
    } catch (err) {
      if (err instanceof OverAuthorizationError) {
        // Do NOT capture the partial amount here. Taking the held portion now
        // and the rest later would leave a customer who declines having paid
        // for a service they did not agree to the price of.
        await this.db
          .from('orders')
          .update({ status: 'awaiting_approval', total_cents: total })
          .eq('id', orderId);
        this.log.info(
          { orderId, authorized: err.authorizedCents, requested: err.requestedCents },
          'intake exceeds hold, awaiting customer approval',
        );
        return { captured: 0, needsApproval: true };
      }
      await this.db
        .from('payments')
        .update({ status: 'failed', last_error: (err as Error).message })
        .eq('id', primary.id);
      throw err;
    }
  }

  /**
   * The customer accepted the higher total: capture the hold in full, then
   * charge the remainder as a separate payment.
   */
  async approveAndCharge(orderId: string) {
    const order = await this.loadOrder(orderId);
    if (order.status !== 'awaiting_approval') {
      throw new Error(`order is not awaiting approval (status '${order.status}')`);
    }

    const { data: primary } = await this.db
      .from('payments')
      .select('*')
      .eq('order_id', orderId)
      .eq('kind', 'primary')
      .single();

    const total = order.total_cents ?? order.subtotal_cents;
    const held = primary.authorized_cents ?? 0;

    if (primary.status !== 'captured') {
      const state = await this.provider.capture({
        paymentIntentRef: primary.provider_intent_ref,
        amountCents: Math.min(total, held),
      });
      await this.db
        .from('payments')
        .update({
          status: state.status,
          captured_cents: state.capturedCents,
          charge_ref: state.chargeRef,
        })
        .eq('id', primary.id);
    }

    const remainder = total - held;
    if (remainder > 0) {
      const { data: row } = await this.db
        .from('payments')
        .insert({
          order_id: orderId,
          kind: 'difference',
          provider: this.provider.name,
          status: 'requires_payment_method',
          authorized_cents: remainder,
        })
        .select()
        .single();

      const state = await this.provider.chargeDifference({
        orderId,
        externalId: row.id,
        customerRef: order.customer?.payment_customer_ref ?? undefined,
        paymentMethodRef: order.customer?.default_payment_method_ref ?? undefined,
        amountCents: remainder,
        currency: 'usd',
        description: `Crease order ${order.short_code} — additional garments`,
      });

      await this.db
        .from('payments')
        .update({
          status: state.status,
          provider_intent_ref: state.paymentIntentRef,
          captured_cents: state.capturedCents,
          charge_ref: state.chargeRef,
        })
        .eq('id', row.id);
    }

    await this.db
      .from('orders')
      .update({ status: 'cleaning', approved_at: new Date().toISOString() })
      .eq('id', orderId);

    this.log.info({ orderId, total, remainder }, 'customer approved higher total');
    return { total, remainder };
  }

  /**
   * Release or return money when an order dies.
   *
   * An uncaptured hold is cancelled outright; a captured one is refunded.
   * Getting this backwards leaves a customer's money sitting on a cancelled
   * order, which is the complaint that ends a young marketplace.
   */
  async voidOrder(orderId: string, reason: string): Promise<{ voided: number; failed: string[] }> {
    const { data: payments } = await this.db
      .from('payments')
      .select('*')
      .eq('order_id', orderId)
      .not('provider_intent_ref', 'is', null);

    const failed: string[] = [];
    let voided = 0;

    for (const p of payments ?? []) {
      try {
        const state =
          p.status === 'captured'
            ? await this.provider.refund(p.provider_intent_ref)
            : await this.provider.cancel(p.provider_intent_ref);
        await this.db
          .from('payments')
          .update({
            status: state.status,
            refunded_cents: state.refundedCents ?? 0,
            last_error: null,
          })
          .eq('id', p.id);
        voided++;
      } catch (err) {
        // Surface rather than swallow: money stuck on a dead order needs a
        // human, and a silent failure here is invisible until someone calls.
        // The caller must be able to tell the customer their refund is
        // pending rather than implying it already happened.
        this.log.error({ orderId, paymentId: p.id, err }, 'could not void payment');
        failed.push((err as Error).message);
        await this.db
          .from('payments')
          .update({ last_error: (err as Error).message })
          .eq('id', p.id);
      }
    }
    this.log.info({ orderId, reason, voided, failed: failed.length }, 'order payments voided');
    return { voided, failed };
  }

  private async loadOrder(orderId: string) {
    const { data, error } = await this.db
      .from('orders')
      .select(
        `*, customer:profiles!orders_customer_profile_fkey(payment_customer_ref, default_payment_method_ref)`,
      )
      .eq('id', orderId)
      .single();
    if (error || !data) throw new Error(`order ${orderId} not found: ${error?.message}`);
    return data as any;
  }
}
