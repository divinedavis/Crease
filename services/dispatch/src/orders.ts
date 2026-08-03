import type { SupabaseClient } from '@supabase/supabase-js';
import {
  DeliveryProviderError,
  TERMINAL_STATUSES,
  type CreateDeliveryRequest,
  type LegStatus,
  type ProviderChain,
  type Waypoint,
} from './deps.js';
import { config } from './config.js';

export type LegType = 'pickup' | 'return';

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
    cancelled: 'cancelled',
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
    cancelled: 'cancelled',
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

    const attempt = (priorLegs?.[0]?.attempt ?? 0) + 1;
    if (attempt > 1) {
      this.log.warn({ orderId, leg, attempt }, 're-dispatching after failed attempt');
    }

    const { pickup, dropoff } = this.waypoints(order, leg);
    const itemCount = order.order_items?.reduce((n: number, i: any) => n + i.quantity, 0) ?? 1;

    const quoteReq = {
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
      pickupReadyAt: leg === 'pickup' ? order.pickup_window_start : order.return_window_start,
      pickupDeadlineAt: leg === 'pickup' ? order.pickup_window_end : order.return_window_end,
    };

    const best = await this.chain.bestQuote(quoteReq);
    if (!best) {
      await this.recordLegFailure(orderId, leg, 'no courier coverage for this route');
      throw new Error('no courier coverage for this route');
    }

    // Insert first so we own an id to use as the provider's idempotency key.
    // If the provider call then times out, a retry replays the same key and
    // Uber returns the original delivery rather than dispatching a second.
    const { data: legRow, error: insertErr } = await this.db
      .from('delivery_legs')
      .insert({
        order_id: orderId,
        leg,
        attempt,
        status: 'pending',
        provider: best.provider.name,
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
        fee_cents: best.quote.feeCents,
        quoted_at: new Date().toISOString(),
        quote_expires_at: best.quote.expiresAt,
      })
      .select()
      .single();

    if (insertErr) throw new Error(`could not create leg: ${insertErr.message}`);

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

    await this.db
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
      .eq('id', legId);

    await this.applyOrderStatus(leg.order_id, leg.leg as LegType, event.status);
  }

  private async applyOrderStatus(orderId: string, leg: LegType, legStatus: LegStatus) {
    const next = ORDER_STATUS_BY_LEG[leg][legStatus];
    if (!next) return;

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

    await this.db.from('orders').update({ status: next }).eq('id', orderId);
    this.log.info({ orderId, leg, legStatus, orderStatus: next }, 'order status advanced');
  }

  private async recordLegFailure(orderId: string, leg: LegType, message: string) {
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
