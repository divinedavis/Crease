import { timingSafeEqual } from 'node:crypto';
import { e164 } from './doordashDrive.js';
import type {
  CreateDeliveryRequest,
  DeliveryProvider,
  DeliveryState,
  LegStatus,
  Quote,
  QuoteRequest,
  WebhookInput,
  WebhookResult,
} from './types.js';
import { DeliveryProviderError } from './types.js';

/**
 * Shipday.
 *
 * Shipday is dispatch software with its own DoorDash and Uber accounts behind
 * it: in the US it books their couriers for us, so Crease needs no DoorDash or
 * Uber account of its own (ours was disabled; DoorDash reviews quarterly).
 * Shipday adds its own small charge on top of the courier's fee.
 *
 * The flow, per leg:
 *  1. quote()          POST /on-demand/availability   price only, nothing booked
 *  2. createDelivery() POST /orders                    the order, numbered with
 *                                                      OUR leg id
 *                      GET  /on-demand/estimate/{id}   fresh prices for it
 *                      POST /on-demand/assign          books the cheapest
 *  3. getDelivery()    GET  /orders/{legId}            state, by our leg id
 *                      GET  /on-demand/details/{id}    courier, tracking, fee
 *  4. cancelDelivery() POST /on-demand/cancel/{id}, then DELETE /orders/{id}
 *
 * The provider delivery id is our leg id (Shipday's order number), the same
 * as DoorDash, so a replay after a timeout finds the order instead of
 * creating a second one.
 *
 * Shipday has no vehicle or weight field for on-demand couriers, so the bag's
 * weight goes into the pickup instructions. In Manhattan a courier can turn up
 * on an e-bike; check the first real legs before trusting it with heavy bags.
 *
 * Webhooks are UNSIGNED: Shipday sends back a fixed token (max 32 chars) in a
 * `token` header. That proves only that the sender knows the token, so the
 * payload never decides a leg's state: the order is re-read from the API.
 *
 * Docs: https://docs.shipday.com/
 */

const API_BASE = 'https://api.shipday.com';
const CALL_TIMEOUT_MS = 20_000;
/** Shipday gives no expiry on an availability answer; re-price after this. */
const QUOTE_TTL_MS = 5 * 60_000;
const MAX_FEE_CENTS = 50_000;
const MAX_TEXT = 280;
const TIMESTAMP_MAX_PAST_MS = 7 * 24 * 60 * 60 * 1000;
const TIMESTAMP_MAX_FUTURE_MS = 31 * 24 * 60 * 60 * 1000;

/** Shipday's order states (orderStatus.orderState / webhook order_status) -> ours. */
const ORDER_STATE_MAP: Record<string, LegStatus> = {
  NOT_ASSIGNED: 'dispatching',
  NOT_ACCEPTED: 'dispatching',
  NOT_STARTED_YET: 'courier_assigned',
  STARTED: 'en_route_to_pickup',
  PICKED_UP: 'picked_up',
  READY_TO_DELIVER: 'en_route_to_dropoff',
  ALREADY_DELIVERED: 'delivered',
  INCOMPLETE: 'failed',
  FAILED_DELIVERY: 'failed',
};

/** Webhook events worth a re-read. The rest (inserted, POD photo) change nothing for us. */
const STATUS_EVENTS = new Set([
  'ORDER_ASSIGNED',
  'ORDER_ACCEPTED_AND_STARTED',
  'ORDER_ONTHEWAY',
  'ORDER_COMPLETED',
  'ORDER_FAILED',
  'ORDER_INCOMPLETE',
  'ORDER_DELETE',
  'ORDER_PIKEDUP',
  'ORDER_UNASSIGNED',
  'ORDER_PIKEDUP_REMOVED',
  'ORDER_ONTHEWAY_REMOVED',
]);

export interface ShipdayOptions {
  apiKey?: string;
  /** The token set on the Shipday webhook (max 32 chars). Unset = every webhook refused. */
  webhookToken?: string;
  apiBase?: string;
  fetchImpl?: typeof fetch;
  now?: () => number;
}

export class ShipdayProvider implements DeliveryProvider {
  readonly name = 'shipday';
  readonly simulated = false;
  private readonly fetchImpl: typeof fetch;
  private readonly base: string;
  private readonly now: () => number;

  constructor(private readonly opts: ShipdayOptions) {
    this.fetchImpl = opts.fetchImpl ?? fetch;
    this.base = (opts.apiBase ?? API_BASE).replace(/\/+$/, '');
    this.now = opts.now ?? Date.now;
  }

  isConfigured(): boolean {
    return Boolean(this.opts.apiKey);
  }

  async quote(req: QuoteRequest): Promise<Quote> {
    const ready = Date.parse(req.pickupReadyAt ?? '');
    const answers = await this.call<any>('POST', '/on-demand/availability', {
      pickupAddress: req.pickup.address,
      deliveryAddress: req.dropoff.address,
      ...(Number.isFinite(ready) && ready > this.now() ? { pickUpTime: isoSeconds(ready) } : {}),
    });
    const best = cheapest(answers);
    if (!best) {
      return {
        quoteId: '',
        feeCents: NaN,
        currency: 'usd',
        expiresAt: new Date(this.now()).toISOString(),
        unavailableReason: failureText(answers),
      };
    }
    return {
      quoteId: best.name,
      feeCents: best.fee,
      currency: 'usd',
      expiresAt: new Date(this.now() + QUOTE_TTL_MS).toISOString(),
      estimatedPickupAt: this.plausible(best.a.pickupTime),
      estimatedDropoffAt: this.plausible(best.a.deliveryTime),
    };
  }

  async createDelivery(req: CreateDeliveryRequest): Promise<DeliveryState> {
    assertId(req.externalId);

    // A replay after a timeout: the order may already exist, and may already
    // have a courier. Never insert a second order or book a second courier.
    let order = await this.orderByNumber(req.externalId);
    const replayStatus = order ? ORDER_STATE_MAP[orderState(order) ?? ''] : undefined;
    if (replayStatus && replayStatus !== 'dispatching') {
      return this.getDelivery(req.externalId);
    }
    if (order) {
      const details = await this.details(order.orderId);
      if (details) return this.toState(req.externalId, order, details);
    }

    let orderId: number;
    if (order) {
      orderId = order.orderId;
    } else {
      const inserted = await this.call<any>('POST', '/orders', this.orderBody(req));
      orderId = Number(inserted?.orderId);
      if (!Number.isSafeInteger(orderId) || orderId <= 0) {
        throw new DeliveryProviderError('shipday: order inserted without an id', { retryable: true });
      }
    }

    const best = cheapest(await this.call<any>('GET', `/on-demand/estimate/${orderId}`));
    if (!best) {
      throw new DeliveryProviderError('shipday: no courier can take this leg', {
        retryable: false,
        providerCode: 'no_quotes',
      });
    }

    const assigned = await this.call<any>('POST', '/on-demand/assign', {
      name: best.name,
      orderId,
      ...(best.a.id ? { estimateReference: String(best.a.id) } : {}),
      ...(req.dropoff.verification === 'signature' ? { podType: 'SIGNATURE' } : {}),
    });
    order = await this.orderByNumber(req.externalId);
    return this.toState(req.externalId, order, assigned);
  }

  async getDelivery(providerDeliveryId: string): Promise<DeliveryState> {
    assertId(providerDeliveryId);
    const order = await this.orderByNumber(providerDeliveryId);
    // We only ask about legs we created, and cancelDelivery deletes the order:
    // gone means cancelled.
    if (!order) {
      return { providerDeliveryId, status: 'cancelled', providerStatus: 'deleted' };
    }
    return this.toState(providerDeliveryId, order, await this.details(order.orderId));
  }

  async cancelDelivery(providerDeliveryId: string): Promise<DeliveryState> {
    assertId(providerDeliveryId);
    const order = await this.orderByNumber(providerDeliveryId);
    if (!order) return { providerDeliveryId, status: 'cancelled', providerStatus: 'deleted' };

    const status = ORDER_STATE_MAP[orderState(order) ?? ''];
    if (status === 'picked_up' || status === 'en_route_to_dropoff' || status === 'delivered') {
      throw new DeliveryProviderError(`shipday: too late to cancel (${orderState(order)})`, {
        retryable: false,
        providerCode: 'too_late',
      });
    }

    try {
      await this.call<any>('POST', `/on-demand/cancel/${order.orderId}`, {});
    } catch (err) {
      // 400 = no courier was booked through on-demand; deleting is enough.
      if (!(err instanceof DeliveryProviderError && err.opts.status === 400)) throw err;
    }
    await this.call<any>('DELETE', `/orders/${order.orderId}`);
    return { providerDeliveryId, status: 'cancelled', providerStatus: 'deleted' };
  }

  async handleWebhook(input: WebhookInput): Promise<WebhookResult> {
    const expected = this.opts.webhookToken;
    if (!expected) return { signatureValid: false };
    const sent = header(input.headers, 'token');
    if (!sent || !safeEqual(sent, expected)) return { signatureValid: false };

    let body: any;
    try {
      body = JSON.parse(input.rawBody.toString('utf8'));
    } catch {
      return { signatureValid: true, ignored: 'unparseable body' };
    }
    const event = typeof body?.event === 'string' ? body.event.toUpperCase() : '';
    if (!STATUS_EVENTS.has(event)) return { signatureValid: true, ignored: `unhandled event: ${event}` };
    const legId = body?.order?.order_number;
    if (typeof legId !== 'string' || !ID_RE.test(legId)) {
      return { signatureValid: true, ignored: 'no usable order_number' };
    }

    // Shipday sends no event id. This is stable across its retries of the
    // same event, so redeliveries dedupe.
    const eventId = `${legId}:${event}:${body.timestamp ?? ''}`;

    // Unsigned payload: re-read, and fall back to it only when Shipday itself
    // cannot be reached, so a blip does not drop the event.
    let state: DeliveryState;
    try {
      state = await this.getDelivery(legId);
    } catch (err) {
      if (err instanceof DeliveryProviderError && !err.opts.retryable) {
        return { signatureValid: true, ignored: `order re-read failed: ${err.message}` };
      }
      const raw = typeof body.order_status === 'string' ? body.order_status.toUpperCase() : '';
      state = {
        providerDeliveryId: legId,
        status: event === 'ORDER_DELETE' ? 'cancelled' : ORDER_STATE_MAP[raw] ?? 'dispatching',
        providerStatus: raw || event,
      };
    }
    return { signatureValid: true, event: { ...state, eventId, eventType: event, externalId: legId } };
  }

  private orderBody(req: CreateDeliveryRequest) {
    const m = req.manifest;
    const load = [
      m.description,
      m.weightLbs && m.weightLbs > 0 ? `about ${Math.round(m.weightLbs)} lb` : undefined,
      m.itemCount > 1 ? `${m.itemCount} items` : undefined,
      m.requiresCar ? 'needs a car' : undefined,
    ]
      .filter(Boolean)
      .join(', ');
    const pickupNote = [load, req.pickup.notes?.trim()].filter(Boolean).join('. ');
    return {
      orderNumber: req.externalId,
      customerName: (req.dropoff.name || 'Customer').slice(0, 80),
      customerAddress: req.dropoff.address,
      customerPhoneNumber: e164(req.dropoff.phone) ?? '',
      restaurantName: (req.pickup.name || 'Pickup').slice(0, 80),
      restaurantAddress: req.pickup.address,
      restaurantPhoneNumber: e164(req.pickup.phone),
      ...coords('pickup', req.pickup.lat, req.pickup.lng),
      ...coords('delivery', req.dropoff.lat, req.dropoff.lng),
      orderItem: [{ name: m.description.slice(0, 80), quantity: Math.max(1, m.itemCount), unitPrice: 0 }],
      totalOrderCost: Math.max(0, Math.round(m.declaredValueCents)) / 100,
      pickupInstruction: pickupNote.slice(0, MAX_TEXT) || undefined,
      deliveryInstruction: req.dropoff.notes?.trim().slice(0, MAX_TEXT) || undefined,
      orderSource: 'Crease',
      additionalId: req.orderReference,
    };
  }

  private async orderByNumber(legId: string): Promise<any | undefined> {
    let found: any;
    try {
      found = await this.call<any>('GET', `/orders/${encodeURIComponent(legId)}`);
    } catch (err) {
      if (err instanceof DeliveryProviderError && err.opts.status === 404) return undefined;
      throw err;
    }
    const list = Array.isArray(found) ? found : found ? [found] : [];
    return list.find(
      (o) => o && String(o.orderNumber) === legId && Number.isSafeInteger(Number(o.orderId)),
    );
  }

  /** On-demand booking details, or undefined when no courier was booked through on-demand. */
  private async details(orderId: number): Promise<any | undefined> {
    try {
      const d = await this.call<any>('GET', `/on-demand/details/${Number(orderId)}`);
      return d && typeof d === 'object' && (d.thirdPartyName || d.id) ? d : undefined;
    } catch (err) {
      if (err instanceof DeliveryProviderError && (err.opts.status === 400 || err.opts.status === 404)) {
        return undefined;
      }
      throw err;
    }
  }

  private toState(legId: string, order: any, details: any): DeliveryState {
    const raw = orderState(order);
    const log = order?.activityLog ?? {};
    const name = details?.driverName ?? order?.assignedCarrier?.name;
    const phone = details?.driverPhone ?? order?.assignedCarrier?.phoneNumber;
    const fee = boundedCents(details?.totalBillableAmount ?? details?.thirdPartyFee);
    return {
      providerDeliveryId: legId,
      status: (raw && ORDER_STATE_MAP[raw]) || 'dispatching',
      providerStatus: [raw, details?.status].filter(Boolean).join('/') || undefined,
      trackingUrl: safeUrl(details?.trackingUrl) ?? safeUrl(order?.trackingLink),
      feeCents: fee,
      courier:
        name || phone || details?.driverLat !== undefined
          ? {
              name: typeof name === 'string' ? name : undefined,
              phone: typeof phone === 'string' ? phone : undefined,
              vehicle:
                typeof details?.driverVehicleDescription === 'string'
                  ? details.driverVehicleDescription
                  : undefined,
              lat: finite(details?.driverLat),
              lng: finite(details?.driverLng),
            }
          : undefined,
      pickedUpAt: this.plausible(log.pickedUpTime),
      completedAt: raw === 'ALREADY_DELIVERED' ? this.plausible(log.deliveryTime) : undefined,
    };
  }

  private async call<T>(method: string, path: string, body?: unknown): Promise<T> {
    if (!this.isConfigured()) {
      throw new DeliveryProviderError('shipday is not configured', { retryable: false });
    }
    let res: Response;
    try {
      res = await this.fetchImpl(`${this.base}${path}`, {
        method,
        headers: {
          authorization: `Basic ${this.opts.apiKey}`,
          'content-type': 'application/json',
        },
        body: body === undefined ? undefined : JSON.stringify(body),
        signal: AbortSignal.timeout(CALL_TIMEOUT_MS),
      });
    } catch (err) {
      const e = err as Error;
      throw new DeliveryProviderError(`shipday ${method} ${path} network failure: ${e.message}`, {
        retryable: true,
        providerCode: e.name === 'TimeoutError' ? 'timeout' : 'network',
      });
    }

    let text: string;
    try {
      text = await res.text();
    } catch (err) {
      throw new DeliveryProviderError(`shipday ${method} ${path} body read failed: ${(err as Error).message}`, {
        retryable: true,
        providerCode: 'network',
        status: res.status,
      });
    }

    if (!res.ok) {
      throw new DeliveryProviderError(`shipday ${method} ${path}: ${res.status} ${text}`.slice(0, 600), {
        retryable: res.status >= 500 || res.status === 429,
        status: res.status,
      });
    }
    try {
      return text ? (JSON.parse(text) as T) : ({} as T);
    } catch {
      throw new DeliveryProviderError(`shipday ${method} ${path}: unparseable success body`, {
        retryable: false,
        status: res.status,
      });
    }
  }

  /** Shipday mixes zoned and zone-less UTC timestamps; read zone-less ones as UTC. */
  private plausible(v: unknown): string | undefined {
    if (typeof v !== 'string' || !v) return undefined;
    const s = /[zZ]|[+-]\d\d:?\d\d$/.test(v) ? v : `${v}Z`;
    const ms = Date.parse(s);
    if (!Number.isFinite(ms)) return undefined;
    const now = this.now();
    if (ms < now - TIMESTAMP_MAX_PAST_MS || ms > now + TIMESTAMP_MAX_FUTURE_MS) return undefined;
    return new Date(ms).toISOString();
  }
}

const ID_RE = /^[A-Za-z0-9\-._~]{1,128}$/;

function assertId(id: string): void {
  if (!ID_RE.test(id ?? '')) {
    throw new DeliveryProviderError(`shipday: invalid id '${id}'`, { retryable: false });
  }
}

function orderState(order: any): string | undefined {
  const s = order?.orderStatus?.orderState;
  return typeof s === 'string' ? s.toUpperCase() : undefined;
}

/** Cheapest courier that actually answered, in cents, fees included. */
function cheapest(answers: unknown): { name: string; fee: number; a: any } | undefined {
  const list = Array.isArray(answers) ? answers : answers ? [answers] : [];
  let best: { name: string; fee: number; a: any } | undefined;
  for (const a of list) {
    if (!a || a.error === true || typeof a.name !== 'string' || !a.name) continue;
    const dollars = Number(a.fee);
    if (a.fee === null || a.fee === undefined || !Number.isFinite(dollars)) continue;
    const regulatory = Number(a.regulatoryFee);
    const fee = boundedCents(dollars + (Number.isFinite(regulatory) ? regulatory : 0));
    if (fee === undefined) continue;
    if (!best || fee < best.fee) best = { name: a.name, fee, a };
  }
  return best;
}

function failureText(answers: unknown): string {
  const list = Array.isArray(answers) ? answers : [];
  const reasons = list
    .filter((a: any) => a?.error)
    .map((a: any) => [a?.name, a?.errorDescription ?? a?.errorMessage].filter(Boolean).join(': '))
    .filter(Boolean)
    .slice(0, 3);
  return reasons.length ? reasons.join('; ') : 'no courier available';
}

function coords(side: 'pickup' | 'delivery', lat?: number, lng?: number) {
  return Number.isFinite(lat) && Number.isFinite(lng)
    ? { [`${side}Latitude`]: lat, [`${side}Longitude`]: lng }
    : {};
}

function isoSeconds(ms: number): string {
  return new Date(ms).toISOString().replace(/\.\d{3}Z$/, 'Z');
}

function header(h: WebhookInput['headers'], key: string): string | undefined {
  const v = h[key] ?? h[key.toLowerCase()];
  return Array.isArray(v) ? v[0] : v;
}

function safeEqual(a: string, b: string): boolean {
  const ab = Buffer.from(a);
  const bb = Buffer.from(b);
  return ab.length === bb.length && timingSafeEqual(ab, bb);
}

/** Dollars (Shipday's unit) to bounded whole cents. */
function boundedCents(v: unknown): number | undefined {
  const n = Number(v);
  if (v === undefined || v === null || !Number.isFinite(n) || n < 0) return undefined;
  const cents = Math.round(n * 100);
  return cents > MAX_FEE_CENTS ? undefined : cents;
}

function safeUrl(v: unknown): string | undefined {
  if (typeof v !== 'string') return undefined;
  try {
    return new URL(v).protocol === 'https:' ? v : undefined;
  } catch {
    return undefined;
  }
}

function finite(v: unknown): number | undefined {
  const n = Number(v);
  return v !== undefined && v !== null && Number.isFinite(n) ? n : undefined;
}
