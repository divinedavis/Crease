import type { SupabaseClient } from '@supabase/supabase-js';
import {
  authorizationAmount,
  OverAuthorizationError,
  PaymentProviderError,
  type PaymentProvider,
  type PaymentState,
} from '@crease/payments';
import { deliveryFeeCents } from './pricing.js';

/**
 * `retainCents` value meaning "keep all of it".
 *
 * For orders where the service was substantially performed — the bag was
 * collected, cleaned, carried — there is no automatic refund to compute. What,
 * if anything, is owed back is a judgement a person makes.
 */
export const RETAIN_ALL = Number.POSITIVE_INFINITY;

/** Charges with money still sitting on them, which come back as a refund. */
const REFUNDABLE_STATUSES = ['captured', 'partially_refunded'];

/**
 * Payment rows a dying order still has something to do to.
 *
 * Everything not listed — 'refunded', 'cancelled' — is money that has already
 * been dealt with, and the provider rejects a second attempt on it.
 */
const VOIDABLE_STATUSES = [
  'requires_payment_method',
  'authorized',
  'failed',
  ...REFUNDABLE_STATUSES,
];

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

    // Never trust the fee on the row. The app writes delivery_fee_cents
    // directly into Supabase and RLS checks only ownership, so a customer can
    // set any price. Recompute from the (constrained) service_tier and, if the
    // stored value disagrees, overwrite it so this charge and every downstream
    // total use the real price.
    const amount = deliveryFeeCents(order.service_tier);
    if (order.delivery_fee_cents !== amount) {
      this.log.warn(
        { orderId, clientFee: order.delivery_fee_cents, serverFee: amount },
        'delivery fee on order did not match the tier price — using the server price',
      );
      await this.db.from('orders').update({ delivery_fee_cents: amount }).eq('id', orderId);
      order.delivery_fee_cents = amount;
    }

    // Ask before writing. The upsert below stamps 'requires_payment_method',
    // so a check made after it can only ever see that — which is how re-tapping
    // Book on a paid order used to reset its payment status — and the row's own
    // copy is stale anyway until something syncs it.
    const paid = await this.syncDeliveryPayment(orderId);
    if (paid) {
      const status: string = paid.row.status;
      // 'processing' belongs with the paid ones, not the unstarted ones: the
      // card is already charged and only the provider's last word is
      // outstanding. Handing out a second intent there charges twice, and the
      // sheet refuses to present a live one anyway — so return the same intent
      // and let the client skip to confirmation.
      if (['authorized', 'captured'].includes(status) || paid.state.providerStatus === 'processing') {
        // Don't hand back a live client secret for an already-settled intent —
        // the app only needs the alreadyPaid flag to skip to confirmation.
        return { clientSecret: '', amountCents: amount, alreadyPaid: true };
      }
      // Money that was taken and given back leaves a row whose refs point at a
      // real charge. Past the provider's idempotency window the upsert below
      // would mint a fresh intent over the top of them, orphaning the refund so
      // what came back can no longer be traced to the order it left.
      if (['refunded', 'partially_refunded', 'cancelled'].includes(status)) {
        throw new Error(
          `order ${orderId} has a ${status} payment — book a new order rather than re-charging this one`,
        );
      }
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

  /**
   * Re-read the provider's view of the primary intent and persist it.
   *
   * The row's status is written when the intent is created — before the
   * customer has so much as seen the sheet — and nothing on that path ever
   * revises it. The customer pays the provider directly from the phone, so the
   * provider is the only party that knows whether money moved; every decision
   * that turns on "is this paid" has to come through here first.
   *
   * Hands back the row and the provider's state together: the row for anything
   * that has to be durable, the state for the client secret, which we
   * deliberately never store. Null means no intent was ever started.
   */
  async syncDeliveryPayment(orderId: string): Promise<{ row: any; state: PaymentState } | null> {
    const { data: primary, error: readError } = await this.db
      .from('payments')
      .select('*')
      .eq('order_id', orderId)
      .eq('kind', 'primary')
      .maybeSingle();
    // A database that would not answer is not an order without a payment.
    // Swallowed, it returns null, the caller reads that as "never paid", and
    // the webhook that exists to catch exactly this answers 200 — so the event
    // is retired at the provider and a charged customer's courier is never
    // sent. Nothing downstream would ever notice. Throw instead.
    if (readError) {
      throw new Error(`could not read the payment for order ${orderId}: ${readError.message}`);
    }

    if (!primary?.provider_intent_ref) return null;

    const state = await this.provider.get(primary.provider_intent_ref);
    const { data: updated, error: writeError } = await this.db
      .from('payments')
      .update({
        status: state.status,
        captured_cents: state.capturedCents ?? primary.captured_cents,
        charge_ref: state.chargeRef ?? primary.charge_ref,
        last_error: state.error ?? null,
      })
      .eq('id', primary.id)
      .select()
      .single();
    // Same failure one step later: falling back to the unsynced row hands the
    // caller the status from before the customer paid.
    if (writeError) {
      throw new Error(`could not record the payment for order ${orderId}: ${writeError.message}`);
    }

    if (primary.status !== state.status) {
      this.log.info({ orderId, from: primary.status, to: state.status }, 'payment status synced');
    }
    return { row: updated, state };
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
   *
   * `nothingToSettle` says this call moved no money for the shop. It is not the
   * same as `captured: 0`: the figure reported alongside it is the delivery fee
   * taken at checkout, which is Crease's, and a caller that reads it as a
   * capture pays the shop its cleaning share out of the courier's money.
   */
  async settleOrder(
    orderId: string,
  ): Promise<{ captured: number; needsApproval: boolean; nothingToSettle?: boolean }> {
    // The cleaning subtotal is derived here, from the line items the shop
    // actually saved, rather than taken from a number a client sent. The
    // portal used to write orders.subtotal_cents itself; money columns are
    // service-role-only now, and recomputing is the stronger version of that
    // rule anyway — the bill always equals the visible lines added up.
    await this.recomputeSubtotal(orderId);

    const order = await this.loadOrder(orderId);
    const cleaning = order.subtotal_cents ?? order.estimate_subtotal_cents ?? 0;
    const total =
      cleaning +
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

    // Crease charges for transport, and that fee was taken in full at
    // checkout. When the shop counts nothing onto the order there is no
    // further money to move, and capturing again against an intent the
    // provider already settled comes back as an error — which the portal shows
    // the shop as a payment failure on a perfectly healthy order.
    if (cleaning <= 0) {
      const synced = await this.syncDeliveryPayment(orderId);
      await this.db.from('orders').update({ total_cents: total }).eq('id', orderId);
      return {
        captured: synced?.row.captured_cents ?? 0,
        needsApproval: false,
        nothingToSettle: true,
      };
    }

    // The fee was already taken at checkout, so there is nothing left to
    // capture — and the amount on the row is that fee, not a cleaning bill this
    // call collected.
    if (primary.status === 'captured') {
      await this.db.from('orders').update({ total_cents: total }).eq('id', orderId);
      return { captured: primary.captured_cents ?? 0, needsApproval: false, nothingToSettle: true };
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

    // Concurrency gate. Two approves arriving together (a double-tap, or the
    // app racing a retry) would both pass a plain status check and race the
    // capture, charging the customer twice. Claim the approval by atomically
    // moving the order out of 'awaiting_approval'; the winner proceeds, the
    // loser gets zero rows back and returns without moving any money.
    const { data: claimed } = await this.db
      .from('orders')
      .update({ status: 'cleaning', approved_at: new Date().toISOString() })
      .eq('id', orderId)
      .eq('status', 'awaiting_approval')
      .select('id');
    if (!claimed || claimed.length === 0) {
      this.log.info({ orderId }, 'approve ignored — order not awaiting approval (already handled)');
      return { total: order.total_cents ?? order.subtotal_cents ?? 0, remainder: 0, alreadyHandled: true };
    }

    // Everything past this line spends money, and the claim above has already
    // moved the order out of 'awaiting_approval' — which is what makes the
    // charge safe, and exactly what makes a failure dangerous. A declined card,
    // a dropped connection, a difference row that will not insert: any of them
    // used to leave the order sitting at 'cleaning', unpaid, with the shop's
    // approval banner gone from the portal and the app's retry answering
    // `alreadyHandled: true` — success-shaped, about money nobody ever took.
    // The balance is silently forfeited and nothing anywhere says so.
    //
    // So the claim is put back on the way out. Rolling back rather than
    // claiming into an intermediate status because order_status is a Postgres
    // enum with no value between 'awaiting_approval' and 'cleaning': an
    // in-between state would need a migration, and every reader — the portal's
    // banner, the app's approval screen, the RLS policy that only lets a
    // customer touch a draft or an awaiting_approval order — would need
    // teaching about a status they have never seen. The rollback needs none of
    // that. It restores precisely the state all of them were already built for,
    // and the retry that follows is safe because it re-reads the payment rows:
    // a primary already captured is skipped rather than captured twice.
    try {
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

      // What is still owed, net of any top-up already collected. Computing the
      // remainder from the primary hold alone re-billed the whole overage every
      // time this ran a second time: an order whose difference had already been
      // charged, coming back through here after a later recount, asked the
      // customer for money it had taken once already.
      //
      // This read has to be fatal when it fails. Everything below treats "no
      // row" as "nothing has been charged yet" and writes on that basis, so a
      // select that merely errored would look identical to a clean order and
      // walk straight into overwriting a real charge — the read failing is
      // exactly when the guard matters most.
      const { data: priorDifference, error: priorErr } = await this.db
        .from('payments')
        .select('*')
        .eq('order_id', orderId)
        .eq('kind', 'difference')
        .maybeSingle();
      if (priorErr) {
        throw new Error(`could not read the existing difference payment: ${priorErr.message}`);
      }

      // Money on the row rather than a status, because a charge whose provider
      // status has not landed yet has still been taken off the card.
      const differenceTaken = Math.max(
        0,
        (priorDifference?.captured_cents ?? 0) - (priorDifference?.refunded_cents ?? 0),
      );
      const remainder = total - held - differenceTaken;

      if (remainder > 0) {
        // A difference row that already carries a charge must never be written
        // over. (order_id, kind) is unique, and `kind` is checked against
        // ('primary', 'difference') — so there is exactly one difference row
        // per order and no second name to give another. Upserting across a
        // captured one replaces the provider_intent_ref and charge_ref of a
        // real Stripe charge: voidOrder can then no longer refund that money
        // and payoutOrder's capturedTotal no longer counts it, with nothing
        // anywhere saying a charge went missing.
        //
        // So the rare case that needs a second row — a shop recounting higher
        // again, after a top-up has already been collected — stops here and
        // asks for a person, rather than balancing the books by destroying the
        // record of the first charge. Supporting it properly means widening
        // that check constraint so a second top-up can have a row of its own.
        if (priorDifference && (differenceTaken > 0 || priorDifference.charge_ref)) {
          throw new Error(
            `order ${orderId} has already collected a top-up and owes ${remainder}c more — ` +
              'recording a second one would overwrite the first charge, so this needs a person',
          );
        }

        // Check the write error instead of blindly dereferencing row.id — a
        // failed insert used to throw a confusing "cannot read id of undefined"
        // mid-charge.
        //
        // Upsert rather than insert, because (order_id, kind) is unique again
        // as of 0026 and the rollback above makes a second pass through here
        // reachable: an approval whose difference charge was declined comes
        // back to 'awaiting_approval' to be tried again, and a plain insert
        // would then hit the unique index and fail the retry forever on a
        // constraint rather than on the card. The guard above is what keeps
        // that reuse honest — it only ever reuses a row that took no money.
        const { data: row, error: rowErr } = await this.db
          .from('payments')
          .upsert(
            {
              order_id: orderId,
              kind: 'difference',
              provider: this.provider.name,
              status: 'requires_payment_method',
              authorized_cents: remainder,
            },
            { onConflict: 'order_id,kind' },
          )
          .select()
          .single();
        if (rowErr || !row) {
          throw new Error(`could not create difference payment: ${rowErr?.message ?? 'no row returned'}`);
        }

        // The row id alone cannot be the idempotency key here. Reusing the row
        // (which the restored unique index forces) means a second approval
        // attempt would replay Stripe's stored response for the first — so a
        // customer whose card declined, then fixed it, gets the cached decline
        // back for 24 hours, and a shop that recounted in between gets a hard
        // 400 for reusing a key with different parameters. Both are permanent.
        //
        // Widening the key with the amount and a coarse time bucket keeps the
        // property the key exists for — a network retry of the SAME attempt,
        // seconds apart, still collapses to one charge — while letting a
        // genuinely new attempt reach the card.
        const attemptKey = `${row.id}:${remainder}:${Math.floor(Date.now() / 300_000)}`;
        const state = await this.provider.chargeDifference({
          orderId,
          externalId: attemptKey,
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

      // status + approved_at were already set atomically by the claim above.
      this.log.info({ orderId, total, remainder }, 'customer approved higher total');
      return { total, remainder };
    } catch (err) {
      await this.releaseApproval(orderId, err);
      throw err;
    }
  }

  /**
   * Hand the approval back, so a charge that did not happen can be tried again.
   *
   * Conditional on the claim still being ours. If something else has moved the
   * order since — a cancellation, a webhook — dragging it back into the
   * approval queue would be a second bug on top of the first, so the mismatch
   * is logged loudly instead: an order that took an approval, failed the
   * charge, and can no longer be put back is precisely the case that needs a
   * person, and it is invisible unless it is said here.
   */
  private async releaseApproval(orderId: string, err: unknown) {
    const { data: restored, error: rollbackErr } = await this.db
      .from('orders')
      .update({ status: 'awaiting_approval', approved_at: null })
      .eq('id', orderId)
      .eq('status', 'cleaning')
      .select('id');

    if (rollbackErr || !restored?.length) {
      this.log.error(
        { orderId, err, rollbackErr },
        'approval charge failed and the claim could not be handed back — order may be unpaid at cleaning',
      );
      return;
    }

    this.log.warn(
      { orderId, err: (err as Error).message },
      'approval charge failed — order returned to awaiting_approval so it can be retried',
    );
  }

  /**
   * Release or return money when an order dies.
   *
   * An uncaptured hold is cancelled outright; a captured one is refunded.
   * Getting this backwards leaves a customer's money sitting on a cancelled
   * order, which is the complaint that ends a young marketplace.
   *
   * `retainCents` is money Crease has already spent on the customer's behalf
   * and does not get back by cancelling — the carrier's cancellation charge
   * once a courier has been engaged, and the card fee on the original capture.
   * It is taken off the first captured payment; anything beyond it is returned.
   * Uncaptured holds are always released in full: keeping one costs the
   * customer their credit line and earns Crease nothing.
   */
  async voidOrder(
    orderId: string,
    reason: string,
    opts: { retainCents?: number } = {},
  ): Promise<{ voided: number; failed: string[]; retainedCents: number }> {
    const { data: payments } = await this.db
      .from('payments')
      .select('*')
      .eq('order_id', orderId)
      .not('provider_intent_ref', 'is', null)
      // Only intents there is still something to do to. A refunded or cancelled
      // one is money already handled, and asking the provider to cancel it
      // again throws — which lands in `failed` and makes the caller tell a
      // customer their "refund could not be completed automatically" about a
      // refund that completed days ago. That message is the whole reason this
      // filter exists.
      //
      // 'failed' stays in: a capture that failed leaves the row saying failed
      // while the hold is still very much live at the provider, and dropping
      // those would strand a customer's credit line for the week it takes the
      // authorization to lapse on its own. Those intents cancel cleanly.
      .in('status', VOIDABLE_STATUSES);

    const failed: string[] = [];
    let voided = 0;
    let retain = Math.max(0, opts.retainCents ?? 0);
    let retainedCents = 0;

    for (const p of payments ?? []) {
      try {
        let state: PaymentState;
        if (REFUNDABLE_STATUSES.includes(p.status)) {
          // Money already given back is not money we can give back again, so a
          // partially refunded charge is settled against what is left of it —
          // and a retention is taken out of that remainder, not out of the
          // original charge it has already been taken out of once.
          const captured = p.captured_cents ?? p.authorized_cents ?? 0;
          const alreadyBack = p.refunded_cents ?? 0;
          const remaining = Math.max(0, captured - alreadyBack);
          const keep = Math.min(retain, remaining);
          const giveBack = remaining - keep;
          retain -= keep;
          retainedCents += keep;

          if (giveBack <= 0) {
            // The whole charge is money already spent. Say so in the log —
            // a refund that never happened must not look like one that failed.
            this.log.info({ orderId, paymentId: p.id, keep }, 'charge retained, nothing to refund');
            continue;
          }
          // An amount, unless this really is "give all of it back". Asking for
          // a full refund of a charge that has already had part of it returned
          // is rejected by the provider, so anything already refunded makes
          // this an explicit-amount refund too.
          state =
            keep > 0 || alreadyBack > 0
              ? await this.provider.refund(p.provider_intent_ref, giveBack)
              : await this.provider.refund(p.provider_intent_ref);
        } else {
          state = await this.provider.cancel(p.provider_intent_ref);
        }
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
    this.log.info(
      { orderId, reason, voided, retainedCents, failed: failed.length },
      'order payments voided',
    );
    return { voided, failed, retainedCents };
  }

  /**
   * Derive orders.subtotal_cents from the saved line items.
   *
   * Each line is rounded before summing, matching what the intake screen and
   * the receipt show the customer — a total that does not equal the visible
   * lines added up is the discrepancy that becomes a chargeback.
   *
   * No rows means nothing was counted; leave the column alone rather than
   * writing a zero over an existing figure.
   */
  private async recomputeSubtotal(orderId: string): Promise<void> {
    const { data: items, error } = await this.db
      .from('order_items')
      .select('quantity, unit_price_cents')
      .eq('order_id', orderId);
    if (error) throw new Error(`could not read line items for order ${orderId}: ${error.message}`);
    if (!items?.length) return;

    const subtotal = items.reduce(
      (sum: number, i: { quantity: number | string; unit_price_cents: number }) =>
        sum + Math.round(Number(i.quantity) * i.unit_price_cents),
      0,
    );
    await this.db.from('orders').update({ subtotal_cents: subtotal }).eq('id', orderId);
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
