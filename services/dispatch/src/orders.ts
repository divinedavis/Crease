import type { SupabaseClient } from '@supabase/supabase-js';
import {
  DeliveryProviderError,
  TERMINAL_STATUSES,
  type CreateDeliveryRequest,
  type DeliveryProvider,
  type LegStatus,
  type ProviderChain,
  type Quote,
  type QuoteRequest,
  type Waypoint,
} from './deps.js';
import { config } from './config.js';
import { deliveryFeeCents } from './pricing.js';
import { DEFAULT_TURNAROUND_HOURS, longestTurnaroundHours, readyAtFrom } from './ready.js';
import { parseWindow } from './windows.js';

export type LegType = 'pickup' | 'return';

/**
 * A failure whose message was written for the customer to read.
 *
 * Everything else thrown from here is written for us — it quotes short codes,
 * payment statuses and carrier vocabulary, and the customer routes deliberately
 * swallow it and answer something generic. That default is right, but it is too
 * blunt for the handful of refusals that ARE the answer ("this order has run
 * out of attempts, call support"), which are useless as a generic 502 and send
 * someone into a retry loop that can never succeed. Marking those explicitly is
 * how a route can pass one through without having to guess from the text.
 */
export class CustomerFacingError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'CustomerFacingError';
  }
}

/**
 * Leg status -> order status, per leg.
 *
 * The order lifecycle is two courier trips with a cleaning in between, so the
 * same leg status means different things depending on which trip it is. This
 * table is the single place that mapping lives.
 */
const ORDER_STATUS_BY_LEG: Record<LegType, Partial<Record<LegStatus, string>>> = {
  pickup: {
    dispatching: 'pickup_dispatched',
    courier_assigned: 'pickup_dispatched',
    en_route_to_pickup: 'pickup_dispatched',
    at_pickup: 'pickup_dispatched',
    picked_up: 'in_transit_to_cleaner',
    en_route_to_dropoff: 'in_transit_to_cleaner',
    at_dropoff: 'in_transit_to_cleaner',
    delivered: 'at_cleaner',
    // Courier could not hand the bag to the cleaner (closed, nobody there).
    // The garments are back with the customer; a human has to re-schedule.
    returned: 'failed',
    failed: 'failed',
    // A carrier cancelling is a failure to deliver, not somebody calling the
    // order off — Uber sends this for an unassigned courier with no
    // replacement, an undeliverable address, or a merchant-side abort. It used
    // to map to 'cancelled', which is the one order status neither cancel route
    // accepts: the customer was told "this order can no longer be cancelled"
    // about an order Crease itself had cancelled, whose fee was captured at
    // checkout, and voidOrder is reachable from nowhere else. 'failed' is the
    // state that already means exactly this — dead, and the customer can still
    // reach their money — and it is what the sibling 'returned' row maps to for
    // the same class of event. Nobody collected the bag, so the custody check
    // in the cancel route then refunds in full.
    //
    // 'cancelled' stays reserved for a deliberate call-off, which only the two
    // cancel routes write.
    cancelled: 'failed',
  },
  return: {
    dispatching: 'return_dispatched',
    courier_assigned: 'return_dispatched',
    en_route_to_pickup: 'return_dispatched',
    at_pickup: 'return_dispatched',
    picked_up: 'in_transit_to_customer',
    en_route_to_dropoff: 'in_transit_to_customer',
    at_dropoff: 'in_transit_to_customer',
    delivered: 'delivered',
    // Customer wasn't home. Garments went back to the cleaner, which is the
    // recoverable case: the order returns to 'ready' and we re-dispatch.
    returned: 'ready',
    failed: 'failed',
    // Same situation as 'returned' above, reached a different way: the delivery
    // was called off before anyone took the garments, so they are still on the
    // shop's rack. Terminating the order here was the worse of the two bugs —
    // it left clean, paid-for clothes at the shop with no way to send them
    // (dispatch-return requires 'ready') and no way to refund them ('cancelled'
    // is not cancellable). Back to 'ready' so it can simply go out again; the
    // attempt cap still bounds how many times, and lands it on 'failed' — which
    // is refundable — when it runs out.
    cancelled: 'ready',
  },
};

export class OrderService {
  constructor(
    private readonly db: SupabaseClient,
    private readonly chain: ProviderChain,
    private readonly log: { info: Function; warn: Function; error: Function },
  ) {}

  /** Carrier by name, for callers that need to cancel a specific leg. */
  providerFor(name: string) {
    return this.chain.get(name);
  }

  /**
   * Create and dispatch one courier leg.
   *
   * Idempotent on (order_id, leg). Two distinct guards, because they catch
   * different mistakes and both cost real money:
   *
   *  - a leg still in flight  -> return it, don't send a second courier
   *  - a leg already delivered -> return it, ever. Re-dispatching a completed
   *    pickup sends a courier to the customer's door for a bag that is
   *    already at the cleaner, and we pay the fee.
   *
   * Only a leg that failed, was cancelled, or came back undelivered may be
   * retried, and that retry gets a fresh attempt number.
   */
  async dispatchLeg(orderId: string, leg: LegType) {
    const order = await this.loadOrder(orderId);

    // A one-leg order paid for one courier. The other leg has no fee behind
    // it, so the refusal lives here rather than in each caller — the portal,
    // the app and the webhooks can all ask for a leg, and only this function
    // is below all of them.
    const tier = order.service_tier ?? 'round_trip';
    if ((leg === 'return' && tier === 'pickup_only') || (leg === 'pickup' && tier === 'return_only')) {
      throw new Error(`order ${order.short_code} is ${tier} — there is no ${leg} leg to dispatch`);
    }

    // Never send a paid-for courier for an order that hasn't paid. The customer
    // can flip status to 'ready' directly in Supabase (orders RLS constrains
    // ownership, not the status value), and the return route only checks
    // status — so the money gate has to live here, below every caller (app,
    // portal, webhooks). Mirrors the internal pickup route's check. Crease
    // charges the delivery fee immediately at booking, so a genuine order is
    // 'captured' by the time either leg dispatches.
    const { data: payment } = await this.db
      .from('payments')
      .select('status, captured_cents, authorized_cents')
      .eq('order_id', orderId)
      .eq('kind', 'primary')
      .maybeSingle();
    if (!payment || !['authorized', 'captured'].includes(payment.status)) {
      throw new Error(
        `order ${order.short_code} has no held funds (payment status '${payment?.status ?? 'none'}') — refusing to dispatch a courier`,
      );
    }

    // Held funds are not the same as enough of them. The fee is priced once,
    // when the intent is created, from whatever tier the order carried at that
    // moment — and service_tier stays customer-writable while the order is a
    // draft. So paying as pickup_only and then flipping the row to round_trip
    // buys a second courier leg for nothing, and the status gate above waves it
    // through because the payment really is captured. Re-check the price of the
    // tier being dispatched against the money actually taken.
    const paidCents = payment.captured_cents ?? payment.authorized_cents ?? 0;
    const tierPriceCents = deliveryFeeCents(tier);
    if (tierPriceCents > paidCents) {
      throw new Error(
        `order ${order.short_code} is ${tier} (${tierPriceCents}c) but only ${paidCents}c was taken — refusing to dispatch until it is repriced`,
      );
    }

    const { data: priorLegs } = await this.db
      .from('delivery_legs')
      .select('*')
      .eq('order_id', orderId)
      .eq('leg', leg)
      .order('attempt', { ascending: false });

    const completed = priorLegs?.find((l) => l.status === 'delivered');
    if (completed) {
      this.log.info({ orderId, leg, legId: completed.id }, 'leg already delivered, refusing re-dispatch');
      return completed;
    }

    const live = priorLegs?.find((l) => !TERMINAL_STATUSES.includes(l.status));
    if (live) {
      this.log.info({ orderId, leg, legId: live.id }, 'leg already live, skipping');
      return live;
    }

    // The window this leg hands the carrier as its dispatch time. The return
    // window is checked by the route that writes it; the pickup window is
    // INSERTed by the app straight into `orders` and reaches this line having
    // been looked at by nothing at all — a window years out buys a quote that
    // expires long before anyone drives.
    //
    // One asymmetry, and it is deliberate: an EXPIRED pickup window is not an
    // error. The app stamps `now -> now + 2h` when the draft is created, and a
    // customer who books, puts the phone down and pays three hours later has
    // done nothing wrong. That order is on-demand — "as soon as possible" is
    // what the window meant when it was written and it is still what the
    // customer wants — so it is re-anchored to now rather than refused. The
    // return leg keeps the strict rule, because there the customer picked a
    // specific time and a courier arriving at some other hour is a broken
    // promise rather than a prompt one.
    const isPickup = leg === 'pickup';
    let dispatchWindow = parseWindow(
      isPickup ? order.pickup_window_start : order.return_window_start,
      isPickup ? order.pickup_window_end : order.return_window_end,
      isPickup ? 'pickup' : 'delivery',
    );
    if ('error' in dispatchWindow && isPickup && Date.parse(order.pickup_window_end) < Date.now()) {
      const now = new Date();
      dispatchWindow = {
        start: now.toISOString(),
        end: new Date(now.getTime() + 2 * 60 * 60 * 1000).toISOString(),
      };
      this.log.info({ orderId, leg }, 'pickup window had lapsed; dispatching as on-demand');
    }
    if ('error' in dispatchWindow) {
      throw new Error(`order ${order.short_code} cannot be dispatched — ${dispatchWindow.error}`);
    }

    // The row number. It only ever goes up, it orders the legs, and it is how a
    // retry is recognised — it is NOT the retry budget. See below.
    const attempt = (priorLegs?.[0]?.attempt ?? 0) + 1;

    // Cap re-dispatch. A returned delivery resets the order to 'ready', and the
    // return route is customer-triggerable — without a cap a customer who is
    // repeatedly "unavailable" (or who scripts the endpoint) books a fresh
    // courier at Crease's cost on every loop for a single paid fee. Past the
    // cap, fail the leg (moving the order to a needs-attention state) and
    // refuse rather than dispatch yet another courier.
    //
    // Counted over the legs that actually reached a carrier, not over the row
    // numbers, because those two are not the same thing. A claim released
    // because the quote never came back (Uber 5xx, a timeout, our own write
    // losing) engaged nobody and cost the customer nothing — and counting it
    // meant three bad minutes at the carrier retired an order for good: the
    // third blip hit the cap, the order went to 'failed', and the retry button
    // the customer was left staring at could only ever burn attempt five. What
    // is worth rationing is couriers we asked to drive.
    const MAX_ATTEMPTS = 3;
    const engaged = (priorLegs ?? []).filter(reachedCarrier).length;
    if (engaged >= MAX_ATTEMPTS) {
      this.log.warn({ orderId, leg, attempt, engaged }, 'refusing dispatch — max attempts reached');
      await this.recordLegFailure(orderId, leg, `max ${leg} attempts reached (${MAX_ATTEMPTS})`);
      throw new CustomerFacingError(
        `This order has reached the maximum number of ${leg} attempts — please contact support.`,
      );
    }

    // A released claim is cheap, not free: each one bought a quote before it
    // was let go, and the return route is customer-triggerable, so cheap times
    // an unbounded retry loop is still a bill. The cap above no longer bounds
    // that — deliberately — so bound the released claims themselves.
    //
    // Two things it has to get right, and the first version got both wrong.
    // It counted every prior leg, so it double-counted the couriers
    // MAX_ATTEMPTS already rations and never isolated the quote spend it exists
    // for. And it counted them for all time: once ten rows existed the order
    // could never be dispatched again by anyone — not the customer, not the
    // portal, not an operator on the internal route — because the refusal
    // writes 'failed' without recording a leg, so the count it tripped on could
    // never come back down. A window is the difference between a rate limit and
    // a death sentence: a carrier having a bad afternoon should cost an order a
    // few hours, not its life.
    const MAX_CLAIMS_PER_DAY = 10;
    const claimWindowStart = Date.now() - 24 * 60 * 60 * 1000;
    const releasedRecently = (priorLegs ?? []).filter(
      (l) => !reachedCarrier(l) && Date.parse(l.created_at ?? '') > claimWindowStart,
    ).length;
    if (releasedRecently >= MAX_CLAIMS_PER_DAY) {
      this.log.warn({ orderId, leg, claims: releasedRecently }, 'refusing dispatch — too many claims');
      // Straight to the order, without recording another leg: ten rows already
      // say this, each with the carrier's own words on it, and an eleventh
      // written by the refusal itself adds nothing but a row per retry. Safe to
      // leave the count un-incremented now that it only looks at the last day —
      // the window is what lets the order recover on its own.
      await this.db
        .from('orders')
        .update({
          status: 'failed',
          cancelled_reason: `${releasedRecently} ${leg} dispatch attempts today without reaching a courier`,
        })
        .eq('id', orderId);
      throw new CustomerFacingError(
        'We could not reach a courier for this order — please contact support.',
      );
    }

    if (attempt > 1) {
      this.log.warn({ orderId, leg, attempt, engaged }, 're-dispatching after failed attempt');
    }

    const { pickup, dropoff } = this.waypoints(order, leg);
    const itemCount = order.order_items?.reduce((n: number, i: any) => n + i.quantity, 0) ?? 1;

    // Claim the leg before spending a penny on it.
    //
    // The row goes in first and the quote happens second, because the partial
    // unique index on (order_id, leg) is the only real mutex here — the
    // live-leg check above is a read, and every concurrent caller passes it.
    // Quoting first meant N simultaneous requests all asked Uber for a price
    // and all paid for the privilege, while N-1 of their inserts then lost to
    // the index and threw the quote away. The return route is
    // customer-triggerable, so "N" is whatever a phone with a stuck retry
    // loop decides it is.
    //
    // The claim doubles as the idempotency key it always was: the row's id is
    // the provider's external_id, so a create that times out replays the same
    // key and Uber hands back the original delivery instead of dispatching a
    // second courier. The provider is unknown until the quote comes back, so
    // it lands in the update below; 'pending' is a placeholder no chain entry
    // matches, which is exactly right for a leg no carrier has yet.
    const { data: claim, error: insertErr } = await this.db
      .from('delivery_legs')
      .insert({
        order_id: orderId,
        leg,
        attempt,
        status: 'pending',
        provider: 'pending',
        pickup_name: pickup.name,
        pickup_phone: pickup.phone,
        pickup_address: pickup.address,
        pickup_lat: pickup.lat,
        pickup_lng: pickup.lng,
        dropoff_name: dropoff.name,
        dropoff_phone: dropoff.phone,
        dropoff_address: dropoff.address,
        dropoff_lat: dropoff.lat,
        dropoff_lng: dropoff.lng,
        pickup_verification: pickup.verification,
        dropoff_verification: dropoff.verification,
      })
      .select()
      .single();

    if (insertErr) {
      // A unique-violation here means a concurrent dispatch (the app's
      // confirm-payment racing the Stripe webhook, seconds apart) already
      // created the live leg. That is success, not failure — returning the
      // winner's leg instead of throwing stops the loser's path from telling
      // the customer "we couldn't book a courier, cancel for a refund" about an
      // order that IS booked and en route.
      if ((insertErr as { code?: string }).code === '23505') {
        const { data: legs } = await this.db
          .from('delivery_legs')
          .select('*')
          .eq('order_id', orderId)
          .eq('leg', leg)
          .order('attempt', { ascending: false });
        const live = legs?.find((l: { status: LegStatus }) => !TERMINAL_STATUSES.includes(l.status));
        if (live) {
          this.log.info({ orderId, leg, legId: live.id }, 'concurrent dispatch won; returning live leg');
          return live;
        }
      }
      throw new Error(`could not create leg: ${insertErr.message}`);
    }

    // The claim is ours, so exactly one quote gets bought for this leg.
    const quoteReq: QuoteRequest = {
      pickup,
      dropoff,
      manifest: {
        description: `Dry cleaning — order ${order.short_code}`,
        // Carriers cap liability far below this; the declared value drives
        // their quote and their (small) coverage, not our actual exposure.
        declaredValueCents: Math.min(
          Math.max(order.subtotal_cents ?? order.estimate_subtotal_cents, config.declaredValueDefaultCents),
          config.declaredValueMaxCents,
        ),
        itemCount: Math.max(itemCount, 1),
        requiresCar: true,
      },
      pickupReadyAt: dispatchWindow.start,
      pickupDeadlineAt: dispatchWindow.end,
    };

    let { best, legRow } = await this.quoteLeg(orderId, leg, claim.id, quoteReq);

    // A quote is a price with a clock on it, and until now nothing read that
    // clock: `quote_expires_at` was written on the row and never looked at
    // again. Creating a delivery against a lapsed quote is either rejected by
    // the carrier — which lands in the catch below and marks a leg failed when
    // nothing was wrong with it — or honoured at whatever the carrier decides
    // the price is now, which is a fee nobody agreed to.
    //
    // The gap between quoting and creating is normally milliseconds. It is not
    // always: bestQuote waits on every carrier in the chain, so one of them
    // hanging spends the whole window before the winner is even known.
    //
    // Only a real timestamp that is genuinely nearly up buys a second quote. A
    // missing or unparseable one means the carrier published no clock, and
    // inventing one would re-quote every leg forever. Once, not in a loop: a
    // quote that arrives already expiring means the two clocks disagree, and
    // spinning on that just buys quotes.
    if (expiringWithin(legRow.quote_expires_at, QUOTE_MIN_REMAINING_MS)) {
      this.log.info(
        { orderId, leg, expiresAt: legRow.quote_expires_at },
        'quote is about to expire — re-quoting before dispatch',
      );
      ({ best, legRow } = await this.quoteLeg(orderId, leg, claim.id, quoteReq));
    }

    const createReq: CreateDeliveryRequest = {
      ...quoteReq,
      externalId: legRow.id,
      quoteId: best.quote.quoteId,
      orderReference: order.short_code,
    };

    try {
      const state = await best.provider.createDelivery(createReq);
      const { data: updated } = await this.db
        .from('delivery_legs')
        .update({
          status: state.status,
          provider_delivery_id: state.providerDeliveryId,
          provider_status: state.providerStatus,
          tracking_url: state.trackingUrl,
          fee_cents: state.feeCents ?? legRow.fee_cents,
          dropoff_pincode: state.dropoffPincode,
          courier_name: state.courier?.name,
          courier_phone: state.courier?.phone,
          courier_vehicle: state.courier?.vehicle,
          dispatched_at: new Date().toISOString(),
        })
        .eq('id', legRow.id)
        .select()
        .single();

      await this.applyOrderStatus(orderId, leg, state.status);
      this.log.info({ orderId, leg, provider: best.provider.name }, 'leg dispatched');
      return updated;
    } catch (err) {
      const retryable = err instanceof DeliveryProviderError ? err.opts.retryable : false;
      await this.db
        .from('delivery_legs')
        .update({
          // A retryable failure stays 'pending' so the reconciler picks it up
          // again; a hard rejection is terminal and needs a human.
          status: retryable ? 'pending' : 'failed',
          last_error: (err as Error).message,
        })
        .eq('id', legRow.id);
      if (!retryable) await this.applyOrderStatus(orderId, leg, 'failed');
      throw err;
    }
  }

  /**
   * Buy the price for a claimed leg and record it on the row.
   *
   * Split out because it is run twice on the legs whose first quote is about to
   * lapse, and both runs have to obey the same rule: every path out of here
   * that does not return a usable quote lets go of the claim. A carrier having
   * a bad minute must not leave a 'pending' row sitting in the mutex, because
   * that row would refuse every future dispatch of this leg — the outage would
   * outlive itself and the order could never be sent again.
   */
  private async quoteLeg(
    orderId: string,
    leg: LegType,
    claimId: string,
    quoteReq: QuoteRequest,
  ): Promise<{ best: { provider: DeliveryProvider; quote: Quote }; legRow: any }> {
    let best: { provider: DeliveryProvider; quote: Quote } | undefined;
    try {
      best = await this.chain.bestQuote(quoteReq);
    } catch (err) {
      await this.releaseClaim(claimId, (err as Error).message);
      throw err;
    }

    if (!best) {
      await this.recordLegFailure(orderId, leg, 'no courier coverage for this route', claimId);
      throw new Error('no courier coverage for this route');
    }

    const { data: quoted, error: quoteWriteErr } = await this.db
      .from('delivery_legs')
      .update({
        provider: best.provider.name,
        fee_cents: best.quote.feeCents,
        quoted_at: new Date().toISOString(),
        quote_expires_at: best.quote.expiresAt,
      })
      .eq('id', claimId)
      .select()
      .single();

    // Losing this write is not cosmetic: `provider` is how a cancellation and
    // an inbound webhook find the carrier that holds the delivery. Stop before
    // dispatching one we would not be able to call off.
    if (quoteWriteErr || !quoted) {
      await this.releaseClaim(claimId, `could not record quote: ${quoteWriteErr?.message}`);
      throw new Error(`could not record quote: ${quoteWriteErr?.message}`);
    }

    return { best, legRow: quoted };
  }

  /** Apply a normalized provider event to a leg and cascade to the order. */
  async applyEvent(legId: string, event: {
    status: LegStatus;
    providerStatus?: string;
    trackingUrl?: string;
    feeCents?: number;
    courier?: { name?: string; phone?: string; vehicle?: string; lat?: number; lng?: number };
    dropoffPincode?: string;
    pickedUpAt?: string;
    completedAt?: string;
    error?: string;
  }) {
    // Read, guard, write — with the write conditional on the row still being
    // where the read left it, and another go round when it is not.
    //
    // The guards below are only worth as much as the write they protect. Two
    // webhooks landing together both read 'at_dropoff', both decide their own
    // event is legal, and the slower one's unconditional UPDATE then lands
    // after the faster one's — walking the leg backwards off 'delivered',
    // re-stamping the ready estimate and re-opening the payout gate on an order
    // that had finished. Carriers batch and retry their callbacks, so this is
    // ordinary traffic, not a thought experiment. Pinning the UPDATE to the
    // status we read turns the loser into zero rows instead, and it re-decides
    // against whatever is actually on the row now. Bounded: a leg being
    // rewritten this hard is a fault to report, not a spin to sit in.
    for (let pass = 0; pass < 3; pass++) {
      const { data: leg } = await this.db
        .from('delivery_legs')
        .select('id, order_id, leg, status')
        .eq('id', legId)
        .single();
      if (!leg) return;

      // Webhooks arrive out of order. Never walk a leg backwards, and never
      // move it off a terminal state — a late 'en_route' after 'delivered'
      // would otherwise un-complete a finished order.
      if (TERMINAL_STATUSES.includes(leg.status)) {
        this.log.info({ legId, from: leg.status, to: event.status }, 'ignoring event on terminal leg');
        return;
      }
      if (rank(event.status) < rank(leg.status) && !TERMINAL_STATUSES.includes(event.status)) {
        this.log.info({ legId, from: leg.status, to: event.status }, 'ignoring out-of-order event');
        return;
      }

      // A bag cannot reach the dropoff side without first being picked up. The
      // rank guard above only stops backward moves, not a single event that
      // vaults a still-'pending' leg straight to delivered/returned — which,
      // cascaded, marks the order complete (or resets a return) and can release
      // the next leg. Reject any dropoff-side status on a leg that never reached
      // 'picked_up'. (Tolerates dropped intermediate en_route/at_* webhooks;
      // only the pickup itself is required.)
      const DROPOFF_SIDE: LegStatus[] = ['en_route_to_dropoff', 'at_dropoff', 'delivered', 'returned'];
      if (DROPOFF_SIDE.includes(event.status) && rank(leg.status) < rank('picked_up')) {
        this.log.warn(
          { legId, from: leg.status, to: event.status },
          'ignoring illegal transition: dropoff-side event before pickup',
        );
        return;
      }

      const { data: written } = await this.db
        .from('delivery_legs')
        .update({
          status: event.status,
          provider_status: event.providerStatus,
          tracking_url: event.trackingUrl,
          fee_cents: event.feeCents,
          dropoff_pincode: event.dropoffPincode,
          courier_name: event.courier?.name,
          courier_phone: event.courier?.phone,
          courier_vehicle: event.courier?.vehicle,
          courier_lat: event.courier?.lat,
          courier_lng: event.courier?.lng,
          picked_up_at: event.pickedUpAt,
          completed_at: event.completedAt,
          last_error: event.error,
        })
        .eq('id', legId)
        // The guard, made real. Without this the checks above are advisory.
        .eq('status', leg.status)
        .select('id');

      if (!written?.length) {
        this.log.info(
          { legId, expected: leg.status, to: event.status },
          'leg moved while the event was being applied — re-reading',
        );
        continue;
      }

      await this.applyOrderStatus(leg.order_id, leg.leg as LegType, event.status, event.completedAt);
      return;
    }

    this.log.warn({ legId, to: event.status }, 'gave up applying event — the leg kept moving underneath it');
  }

  private async applyOrderStatus(
    orderId: string,
    leg: LegType,
    legStatus: LegStatus,
    completedAt?: string,
  ) {
    const next = ORDER_STATUS_BY_LEG[leg][legStatus];
    if (!next) return;

    // Same read-guard-write shape as applyEvent, and for the same reason: these
    // two guards are the only thing standing between a straggling webhook and a
    // finished order, and an unconditional write makes them advisory. A cancel
    // committing between the read and the write, or a second event cascading
    // from the other leg, would be silently overwritten by a decision made
    // against a status that no longer exists — and 'at_cleaner' landing twice
    // re-stamps a ready estimate the shop has already beaten.
    for (let pass = 0; pass < 3; pass++) {
      const { data: order } = await this.db
        .from('orders')
        .select('status')
        .eq('id', orderId)
        .single();
      if (!order) return;

      // Never resurrect a finished order from a straggling event.
      if (['delivered', 'cancelled'].includes(order.status)) return;

      // Pickup completing means the bag is at the cleaner, awaiting intake —
      // don't stomp a cleaner who has already started counting.
      if (next === 'at_cleaner' && ['awaiting_approval', 'cleaning', 'ready'].includes(order.status)) {
        return;
      }

      const { data: written } = await this.db
        .from('orders')
        .update({ status: next })
        .eq('id', orderId)
        .eq('status', order.status)
        .select('id');

      if (!written?.length) {
        this.log.info(
          { orderId, expected: order.status, to: next },
          'order moved while its status was being advanced — re-checking',
        );
        continue;
      }

      this.log.info({ orderId, leg, legStatus, orderStatus: next }, 'order status advanced');

      if (next === 'at_cleaner') await this.stampReadyEstimate(orderId, completedAt);
      return;
    }

    this.log.warn(
      { orderId, leg, legStatus, to: next },
      'gave up advancing the order — its status kept moving underneath',
    );
  }

  /**
   * The first honest answer to "when will it be done", written the moment the
   * bag lands at the shop.
   *
   * Until this exists the only time on the order is the pickup window, which by
   * now is in the past and describes something that has already happened. The
   * clock runs from the courier's completion time rather than from now(), so a
   * webhook that arrives late — or is replayed hours afterwards — does not push
   * the estimate out past a shop that has been working on it since the handoff.
   */
  private async stampReadyEstimate(orderId: string, arrivedAt?: string) {
    const { data: order, error } = await this.db
      .from('orders')
      .select('cleaner:cleaners(turnaround_hours)')
      .eq('id', orderId)
      .maybeSingle();
    if (error || !order) {
      this.log.warn({ orderId, err: error }, 'could not stamp the ready estimate');
      return;
    }

    // The shop's own speed, and nothing finer: what is actually in the bag is
    // not known until somebody counts it, which is what refines this later.
    const hours = (order as any).cleaner?.turnaround_hours;
    const estimate = readyAtFrom(
      arrivedAt ?? new Date().toISOString(),
      hours ?? DEFAULT_TURNAROUND_HOURS,
    );
    await this.db.from('orders').update({ estimated_ready_at: estimate }).eq('id', orderId);
    this.log.info({ orderId, estimatedReadyAt: estimate, hours }, 'ready estimate set on arrival');
  }

  /**
   * Recompute the estimate from what the shop actually counted.
   *
   * Arrival could only assume the shop's default speed, and that default is a
   * dry cleaning number — days. A bag that turns out to be wash & fold is done
   * in about two hours, and a customer told Thursday for something ready this
   * afternoon has been given the wrong answer, not a cautious one.
   *
   * Still measured from arrival, never from intake: the clock started when the
   * clothes landed, and a shop that counts a bag at closing time has not thereby
   * added a day to the work.
   */
  async refineReadyEstimate(orderId: string): Promise<string | null> {
    const { data: order, error } = await this.db
      .from('orders')
      .select(
        `estimated_ready_at,
         cleaner:cleaners(turnaround_hours),
         order_items(service_item:service_items(turnaround_hours))`,
      )
      .eq('id', orderId)
      .maybeSingle();
    if (error || !order) return null;

    // An uncounted order keeps the arrival estimate. Recomputing from nothing
    // would hand back the shop default dressed up as a refined number.
    const counted = ((order as any).order_items ?? []) as any[];
    if (counted.length === 0) return (order as any).estimated_ready_at ?? null;

    // A line with no catalogue entry behind it inherits the shop's speed rather
    // than dropping out — one custom item must not halve the estimate.
    const hours = longestTurnaroundHours(
      counted.map((i) => i.service_item),
      (order as any).cleaner?.turnaround_hours,
    );
    const estimate = readyAtFrom(await this.arrivedAt(orderId), hours);

    const { error: writeError } = await this.db
      .from('orders')
      .update({ estimated_ready_at: estimate })
      .eq('id', orderId);
    if (writeError) {
      this.log.warn({ orderId, err: writeError }, 'could not refine the ready estimate');
      return (order as any).estimated_ready_at ?? null;
    }

    this.log.info({ orderId, estimatedReadyAt: estimate, hours }, 'ready estimate refined at intake');
    return estimate;
  }

  /** When the bag reached the shop. A return_only order has no courier leg to
   *  ask, and for that tier the bag arrives in the customer's own hands at the
   *  moment the shop counts it. */
  private async arrivedAt(orderId: string): Promise<string> {
    const { data: leg } = await this.db
      .from('delivery_legs')
      .select('completed_at, updated_at')
      .eq('order_id', orderId)
      .eq('leg', 'pickup')
      .eq('status', 'delivered')
      .order('attempt', { ascending: false })
      .limit(1)
      .maybeSingle();
    return leg?.completed_at ?? leg?.updated_at ?? new Date().toISOString();
  }

  /**
   * Let go of a claimed leg that never reached a carrier.
   *
   * A claim sits at 'pending', which the partial unique index reads as live, so
   * an abandoned one locks this leg out of dispatch permanently. Cancelled, not
   * failed: no courier was booked and no money moved, so the order itself is
   * still perfectly good and a retry may follow.
   *
   * That retry deliberately does NOT spend the courier budget — MAX_ATTEMPTS
   * counts only legs that reached a carrier, because a quote that never came
   * back engaged nobody. What the released row does spend is the rolling
   * per-day claim allowance above, which is what stops a stuck retry loop
   * running up billable quotes all afternoon.
   */
  private async releaseClaim(legId: string, message: string) {
    await this.db
      .from('delivery_legs')
      .update({ status: 'cancelled', last_error: message })
      .eq('id', legId);
  }

  /**
   * Record a leg that cannot be dispatched at all, and stop the order.
   *
   * Called with a claim id once dispatchLeg holds one — the claim row IS this
   * leg, and marking it terminal both writes the failure and frees the mutex.
   * Called without one from the paths that refuse before claiming, where there
   * is no row yet and the failure needs somewhere to live.
   */
  private async recordLegFailure(orderId: string, leg: LegType, message: string, claimedLegId?: string) {
    if (claimedLegId) {
      await this.db
        .from('delivery_legs')
        .update({ status: 'failed', last_error: message })
        .eq('id', claimedLegId);
    } else {
      await this.db.from('delivery_legs').insert({
        order_id: orderId,
        leg,
        status: 'failed',
        provider: 'none',
        pickup_name: '-',
        pickup_address: '-',
        dropoff_name: '-',
        dropoff_address: '-',
        last_error: message,
      });
    }
    await this.db.from('orders').update({ status: 'failed', cancelled_reason: message }).eq('id', orderId);
  }

  private async loadOrder(orderId: string) {
    const { data, error } = await this.db
      .from('orders')
      .select(
        `*,
         cleaner:cleaners(*),
         address:addresses(*),
         customer:profiles!orders_customer_profile_fkey(full_name, phone),
         order_items(quantity)`,
      )
      .eq('id', orderId)
      .single();
    if (error || !data) throw new Error(`order ${orderId} not found: ${error?.message}`);
    return data as any;
  }

  /** Legs run in opposite directions; this is the only place that flips them. */
  private waypoints(order: any, leg: LegType): { pickup: Waypoint; dropoff: Waypoint } {
    const customer: Waypoint = {
      name: order.customer?.full_name ?? 'Crease customer',
      phone: order.customer?.phone,
      address: formatAddress(order.address),
      lat: order.address.lat,
      lng: order.address.lng,
      notes: order.address.access_notes,
      // Signature on both customer-side touches. Garments are the highest
      // dispute-rate category in local delivery; a name on the handoff is
      // the cheapest evidence there is.
      verification: 'signature',
    };
    const cleaner: Waypoint = {
      name: order.cleaner.name,
      phone: order.cleaner.phone,
      address: formatAddress(order.cleaner),
      lat: order.cleaner.lat,
      lng: order.cleaner.lng,
      notes: `Crease order ${order.short_code}`,
      verification: 'signature',
    };
    return leg === 'pickup'
      ? { pickup: customer, dropoff: cleaner }
      : { pickup: cleaner, dropoff: customer };
  }
}

function formatAddress(a: any): string {
  return [a.line1, a.line2, a.city, `${a.state} ${a.postal_code}`].filter(Boolean).join(', ');
}

/**
 * Did this leg ever become somebody's job?
 *
 * 'pending' is the placeholder a claim carries until a quote comes back, and
 * 'none' is what a refusal made before any claim records — a row with either of
 * those was never dispatched to anyone and must not spend the retry budget.
 * provider_delivery_id is the belt to that braces: a create whose response we
 * lost may still have put a courier on the road, and a half-written row like
 * that has to count even though the carrier never got named on it.
 */
function reachedCarrier(l: { provider?: string | null; provider_delivery_id?: string | null }): boolean {
  if (l.provider_delivery_id) return true;
  return Boolean(l.provider) && l.provider !== 'pending' && l.provider !== 'none';
}

/**
 * How much life a quote needs left before we dare create against it.
 *
 * Generous, because what is being avoided is not a near miss but a carrier
 * rejection that fails an otherwise healthy leg. A wasted re-quote costs an API
 * call; a lapsed one costs the order.
 */
const QUOTE_MIN_REMAINING_MS = 30_000;

/** True only for a timestamp we can read that is genuinely nearly up. */
function expiringWithin(expiresAt: string | null | undefined, withinMs: number): boolean {
  const at = Date.parse(expiresAt ?? '');
  return Number.isFinite(at) && at - Date.now() < withinMs;
}

/** Progress ordering for out-of-order webhook suppression. */
const ORDER: LegStatus[] = [
  'pending',
  'dispatching',
  'courier_assigned',
  'en_route_to_pickup',
  'at_pickup',
  'picked_up',
  'en_route_to_dropoff',
  'at_dropoff',
  'delivered',
  'returned',
  'cancelled',
  'failed',
];
function rank(s: LegStatus): number {
  return ORDER.indexOf(s);
}
