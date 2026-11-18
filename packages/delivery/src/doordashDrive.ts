import { createHmac, randomUUID, timingSafeEqual } from 'node:crypto';
import type {
  CreateDeliveryRequest,
  DeliveryProvider,
  DeliveryState,
  LegStatus,
  Quote,
  QuoteRequest,
  Waypoint,
  WebhookInput,
  WebhookResult,
} from './types.js';
import { DeliveryProviderError } from './types.js';

/**
 * DoorDash Drive (v2).
 *
 * DoorDash's delivery-as-a-service API: Dashers carry a package from one
 * address to another for a merchant that is not on the DoorDash marketplace.
 * It replaced Uber Direct here after Uber disabled the Crease account
 * (2026-10) and never reinstated it.
 *
 * Shape differences from Uber that the rest of this file is built around:
 *
 *  - Auth is a short-lived JWT we sign ourselves (HS256, `dd-ver: DD-JWT-V1`),
 *    not an OAuth token we fetch. No auth round trip, nothing to rate-limit.
 *  - Every delivery is addressed by OUR id (`external_delivery_id`), so the
 *    leg id is both the idempotency key and the provider delivery id.
 *  - A quote has to be accepted within 5 minutes and is tied to the id it was
 *    quoted under. Route pricing quotes before any leg exists, so quotes go
 *    out under a throwaway id and the delivery is created directly against
 *    the leg id. The fee on the created delivery is what we record.
 *  - Webhooks are NOT signed. DoorDash sends a static Authorization header
 *    configured in the Developer Portal, and nothing else. So the header is
 *    checked, and then the delivery is re-read from the API: the payload is a
 *    nudge, the API is the truth.
 *
 * Docs: https://developer.doordash.com/en-US/api/drive/
 */

const API_BASE = 'https://openapi.doordash.com/drive/v2';

/** DoorDash allows up to 30 minutes; short keeps a leaked token near-useless. */
const JWT_TTL_SEC = 300;
/** Re-sign this long before expiry so a token cannot lapse mid-flight. */
const JWT_REFRESH_SLACK_SEC = 60;

const CALL_TIMEOUT_MS = 15_000;

/** DoorDash: "the quote must be accepted within 5 minutes". */
const QUOTE_TTL_MS = 5 * 60 * 1000;

/**
 * A scheduled pickup must be sent at least an hour before it starts. Anything
 * sooner goes out as on-demand (ASAP), which is what "Standard" means anyway.
 */
const SCHEDULE_MIN_LEAD_MS = 60 * 60 * 1000;

const TIMESTAMP_MAX_PAST_MS = 7 * 24 * 60 * 60 * 1000;
const TIMESTAMP_MAX_FUTURE_MS = 24 * 60 * 60 * 1000;
/** No local courier leg costs $500. Above that it is a unit mix-up. */
const MAX_FEE_CENTS = 50_000;
const MAX_INSTRUCTIONS = 500;

/** `delivery_status` on a GET / create response -> ours. */
const STATUS_MAP: Record<string, LegStatus> = {
  quote: 'dispatching',
  created: 'dispatching',
  confirmed: 'courier_assigned',
  enroute_to_pickup: 'en_route_to_pickup',
  arrived_at_pickup: 'at_pickup',
  picked_up: 'picked_up',
  enroute_to_dropoff: 'en_route_to_dropoff',
  arrived_at_dropoff: 'at_dropoff',
  delivered: 'delivered',
  // A return is the bag coming back after nobody took it at dropoff. Our
  // vocabulary has no "returning", and at_dropoff is the furthest progress
  // that is still true; `returned` lands when the bag is back.
  enroute_to_return: 'at_dropoff',
  arrived_at_return: 'at_dropoff',
  returned: 'returned',
  cancelled: 'cancelled',
  canceled: 'cancelled',
};

/** Webhook `event_name` -> ours. Used only when the API re-read fails. */
const EVENT_MAP: Record<string, LegStatus> = {
  DELIVERY_CREATED: 'dispatching',
  DASHER_CONFIRMED: 'courier_assigned',
  DASHER_ENROUTE_TO_PICKUP: 'en_route_to_pickup',
  DASHER_CONFIRMED_PICKUP_ARRIVAL: 'at_pickup',
  DASHER_PICKED_UP: 'picked_up',
  DASHER_ENROUTE_TO_DROPOFF: 'en_route_to_dropoff',
  DASHER_CONFIRMED_DROPOFF_ARRIVAL: 'at_dropoff',
  DASHER_DROPPED_OFF: 'delivered',
  DELIVERY_RETURN_INITIALIZED: 'at_dropoff',
  DASHER_ENROUTE_TO_RETURN: 'at_dropoff',
  DASHER_CONFIRMED_RETURN_ARRIVAL: 'at_dropoff',
  DELIVERY_RETURNED: 'returned',
  DELIVERY_CANCELLED: 'cancelled',
};

/** Statuses before the Dasher has the bag: the customer-facing number is the pickup one. */
const BEFORE_PICKUP = new Set<LegStatus>([
  'pending',
  'dispatching',
  'courier_assigned',
  'en_route_to_pickup',
  'at_pickup',
]);

export interface DoorDashDriveOptions {
  developerId?: string;
  keyId?: string;
  /** Base64 (or base64url) signing secret from the Developer Portal. */
  signingSecret?: string;
  /**
   * The exact Authorization header value DoorDash is configured to send on
   * webhooks (Developer Portal -> Webhooks -> Basic Auth). Unset = every
   * webhook is refused.
   */
  webhookAuth?: string;
  apiBase?: string;
  fetchImpl?: typeof fetch;
  /** For tests. */
  now?: () => number;
}

export class DoorDashDriveProvider implements DeliveryProvider {
  readonly name = 'doordash';
  /** A real courier network: quotes from here are allowed to win on price. */
  readonly simulated = false;
  private jwt?: { value: string; expiresAt: number };
  private readonly fetchImpl: typeof fetch;
  private readonly base: string;
  private readonly now: () => number;

  constructor(private readonly opts: DoorDashDriveOptions) {
    this.fetchImpl = opts.fetchImpl ?? fetch;
    this.base = (opts.apiBase ?? API_BASE).replace(/\/+$/, '');
    this.now = opts.now ?? Date.now;
  }

  isConfigured(): boolean {
    return Boolean(this.opts.developerId && this.opts.keyId && this.opts.signingSecret);
  }

  async quote(req: QuoteRequest): Promise<Quote> {
    // Quotes are bound to the id they were asked under and cannot be re-used
    // for a different one, so they go out under a throwaway id. Nothing is
    // booked by a quote.
    const body = {
      external_delivery_id: `crease-quote-${randomUUID()}`,
      ...this.routeFields(req),
    };
    const res = await this.call<any>('POST', '/quotes', body);
    const reason = unavailableReason(res);
    return {
      quoteId: String(res?.external_delivery_id ?? ''),
      feeCents: Number(res?.fee),
      currency: String(res?.currency ?? 'usd').toLowerCase(),
      expiresAt: new Date(this.now() + QUOTE_TTL_MS).toISOString(),
      estimatedPickupAt: this.plausibleTimestamp(res?.pickup_time_estimated),
      estimatedDropoffAt: this.plausibleTimestamp(res?.dropoff_time_estimated),
      unavailableReason: reason,
    };
  }

  async createDelivery(req: CreateDeliveryRequest): Promise<DeliveryState> {
    assertExternalId(req.externalId);
    const body = {
      // Our leg id. DoorDash refuses a second delivery under the same id, which
      // is what makes replaying a create after a timeout safe.
      external_delivery_id: req.externalId,
      ...this.routeFields(req),
      pickup_reference_tag: req.orderReference,
      items: [
        {
          name: req.manifest.description,
          description: req.manifest.description,
          quantity: req.manifest.itemCount,
          ...(req.manifest.weightLbs ? { weight: req.manifest.weightLbs } : {}),
        },
      ],
      // Never leave garments on a doorstep: a Dasher who cannot hand the bag
      // over brings it back, and the leg ends 'returned' instead of in a claim.
      action_if_undeliverable: 'return_to_pickup',
      contactless_dropoff: false,
      dropoff_requires_signature: req.dropoff.verification === 'signature',
      ...contactName(req.dropoff),
    };

    try {
      return this.toState(await this.call<any>('POST', '/deliveries', body));
    } catch (err) {
      // 409 = this id already exists: an earlier attempt landed and we lost the
      // answer. Read it back rather than fail a leg that has a Dasher on it.
      if (err instanceof DeliveryProviderError && err.opts.status === 409) {
        return this.getDelivery(req.externalId);
      }
      throw err;
    }
  }

  async getDelivery(providerDeliveryId: string): Promise<DeliveryState> {
    assertExternalId(providerDeliveryId);
    return this.toState(
      await this.call<any>('GET', `/deliveries/${encodeURIComponent(providerDeliveryId)}`),
    );
  }

  async cancelDelivery(providerDeliveryId: string): Promise<DeliveryState> {
    assertExternalId(providerDeliveryId);
    // DoorDash refuses (409) once a Dasher is assigned. That surfaces as an
    // error, and the cancel route keeps the order where it was.
    return this.toState(
      await this.call<any>(
        'PUT',
        `/deliveries/${encodeURIComponent(providerDeliveryId)}/cancel`,
        {},
      ),
    );
  }

  async handleWebhook(input: WebhookInput): Promise<WebhookResult> {
    // No signature exists on DoorDash webhooks; the configured header is the
    // whole of the authentication. Compare in constant time.
    if (!this.opts.webhookAuth) return { signatureValid: false };
    const sent = header(input.headers, 'authorization');
    if (!sent || !safeEqual(sent, this.opts.webhookAuth)) return { signatureValid: false };

    let body: any;
    try {
      body = JSON.parse(input.rawBody.toString('utf8'));
    } catch {
      return { signatureValid: true, ignored: 'unparseable body' };
    }

    const eventName = typeof body?.event_name === 'string' ? body.event_name : undefined;
    const externalId =
      typeof body?.external_delivery_id === 'string' ? body.external_delivery_id : undefined;
    if (!eventName) return { signatureValid: true, ignored: 'no event_name' };
    const fromEvent = EVENT_MAP[eventName.toUpperCase()];
    if (!fromEvent) return { signatureValid: true, ignored: `unhandled event: ${eventName}` };
    if (!externalId || !EXTERNAL_ID_RE.test(externalId)) {
      return { signatureValid: true, ignored: 'no usable external_delivery_id' };
    }

    // DoorDash sends no event id. Build one that is stable across its retries
    // (same delivery, same event, same timestamp) so redeliveries dedupe.
    const eventId = `${externalId}:${eventName}:${body.created_at ?? body.updated_at ?? ''}`;

    // The payload is unsigned, so it does not get to decide the leg's state.
    // Re-read the delivery; only fall back to the payload when DoorDash itself
    // cannot be reached, so a blip does not drop the event.
    let state: DeliveryState;
    try {
      state = await this.getDelivery(externalId);
    } catch (err) {
      if (err instanceof DeliveryProviderError && !err.opts.retryable) {
        // A 404 for an id the header-authenticated sender named is not
        // something to apply.
        return { signatureValid: true, ignored: `delivery re-read failed: ${err.message}` };
      }
      state = { ...this.toState(body), status: fromEvent, providerStatus: eventName };
    }

    return {
      signatureValid: true,
      event: { ...state, eventId, eventType: eventName, externalId },
    };
  }

  /** Fields shared by quote and create. */
  private routeFields(req: QuoteRequest) {
    return {
      pickup_address: req.pickup.address,
      pickup_business_name: req.pickup.name,
      pickup_phone_number: e164(req.pickup.phone),
      pickup_instructions: instructions(req.pickup.notes),
      dropoff_address: req.dropoff.address,
      dropoff_business_name: req.dropoff.name,
      dropoff_phone_number: e164(req.dropoff.phone),
      dropoff_instructions: instructions(req.dropoff.notes),
      ...(isFinite2(req.dropoff.lat, req.dropoff.lng)
        ? { dropoff_location: { lat: req.dropoff.lat, lng: req.dropoff.lng } }
        : {}),
      order_value: Math.max(0, Math.round(req.manifest.declaredValueCents)),
      // Hanging garments do not go on a bike.
      ...(req.manifest.requiresCar ? { dasher_allowed_vehicles: ['car'] } : {}),
      ...this.timing(req),
    };
  }

  /**
   * On-demand unless the window starts at least an hour out. DoorDash takes
   * either pickup_time or dropoff_time for a scheduled delivery, not both;
   * pickup_time is the one we know, since a window is when the bag is ready.
   */
  private timing(req: QuoteRequest): { pickup_time?: string } {
    const ready = Date.parse(req.pickupReadyAt ?? '');
    if (!Number.isFinite(ready) || ready - this.now() < SCHEDULE_MIN_LEAD_MS) return {};
    return { pickup_time: new Date(ready).toISOString() };
  }

  /** Map a DoorDash delivery onto our vocabulary, dropping anything implausible. */
  private toState(d: any): DeliveryState {
    const raw = typeof d?.delivery_status === 'string' ? d.delivery_status : undefined;
    const status: LegStatus = (raw && STATUS_MAP[raw.toLowerCase()]) || 'dispatching';
    const before = BEFORE_PICKUP.has(status);
    // DoorDash hands out a masked number per party. Before pickup the customer
    // who needs to reach the Dasher is the one handing the bag over (pickup
    // leg); after pickup it is the one receiving it (return leg).
    const phone = before
      ? d?.dasher_pickup_phone_number ?? d?.dasher_dropoff_phone_number
      : d?.dasher_dropoff_phone_number ?? d?.dasher_pickup_phone_number;
    const vehicle = [d?.dasher_vehicle_make, d?.dasher_vehicle_model]
      .filter((v) => typeof v === 'string' && v)
      .join(' ');
    const hasDasher = d?.dasher_name || phone || d?.dasher_location;
    return {
      providerDeliveryId: String(d?.external_delivery_id ?? ''),
      status,
      providerStatus: raw,
      trackingUrl: safeUrl(d?.tracking_url),
      feeCents: boundedFeeCents(d?.fee),
      courier: hasDasher
        ? {
            name: typeof d.dasher_name === 'string' ? d.dasher_name : undefined,
            phone: typeof phone === 'string' ? phone : undefined,
            vehicle: vehicle || undefined,
            lat: finiteOrUndefined(d.dasher_location?.lat),
            lng: finiteOrUndefined(d.dasher_location?.lng),
          }
        : undefined,
      dropoffPincode: validPincode(d?.dropoff_pin_code_verification_metadata?.pin_code_value),
      pickedUpAt: this.plausibleTimestamp(d?.pickup_time_actual),
      completedAt: this.plausibleTimestamp(d?.dropoff_time_actual ?? d?.return_time_actual),
      error: d?.cancellation_reason ? String(d.cancellation_reason) : undefined,
    };
  }

  /** HS256 JWT per DoorDash's spec, cached until a minute before it expires. */
  private token(): string {
    const nowSec = Math.floor(this.now() / 1000);
    if (this.jwt && this.jwt.expiresAt - JWT_REFRESH_SLACK_SEC > nowSec) return this.jwt.value;

    const head = b64url(JSON.stringify({ alg: 'HS256', typ: 'JWT', 'dd-ver': 'DD-JWT-V1' }));
    const claims = b64url(
      JSON.stringify({
        aud: 'doordash',
        iss: this.opts.developerId,
        kid: this.opts.keyId,
        iat: nowSec,
        exp: nowSec + JWT_TTL_SEC,
      }),
    );
    // Node's base64 decoder also accepts the URL-safe alphabet, so either
    // form of the portal's secret decodes to the same key bytes.
    const key = Buffer.from(this.opts.signingSecret!, 'base64');
    const sig = createHmac('sha256', key).update(`${head}.${claims}`).digest('base64url');
    this.jwt = { value: `${head}.${claims}.${sig}`, expiresAt: nowSec + JWT_TTL_SEC };
    return this.jwt.value;
  }

  /**
   * The only place this provider touches the network. A dropped socket or a
   * timeout is retryable: the request may have landed, and replaying it under
   * the same external_delivery_id is exactly what makes asking again safe.
   */
  private async call<T>(method: string, path: string, body?: unknown, retriedAuth = false): Promise<T> {
    if (!this.isConfigured()) {
      throw new DeliveryProviderError('doordash is not configured', { retryable: false });
    }

    let res: Response;
    try {
      res = await this.fetchImpl(`${this.base}${path}`, {
        method,
        headers: {
          authorization: `Bearer ${this.token()}`,
          'content-type': 'application/json',
        },
        body: body === undefined ? undefined : JSON.stringify(body),
        signal: AbortSignal.timeout(CALL_TIMEOUT_MS),
      });
    } catch (err) {
      const e = err as Error;
      throw new DeliveryProviderError(`doordash ${method} ${path} network failure: ${e.message}`, {
        retryable: true,
        providerCode: e.name === 'TimeoutError' ? 'timeout' : 'network',
      });
    }

    let text: string;
    try {
      text = await res.text();
    } catch (err) {
      throw new DeliveryProviderError(
        `doordash ${method} ${path} body read failed: ${(err as Error).message}`,
        { retryable: true, providerCode: 'network', status: res.status },
      );
    }

    if (!res.ok) {
      // A clock-skewed or stale JWT answers 401. Re-sign once; an
      // unauthenticated call was never processed, so replaying it is safe.
      if (res.status === 401 && !retriedAuth) {
        this.jwt = undefined;
        return this.call<T>(method, path, body, true);
      }
      let code: string | undefined;
      let message = text;
      try {
        const parsed = JSON.parse(text);
        code = parsed.code ?? parsed.reason;
        message = parsed.message ?? text;
        // Validation failures put the real reason in field_errors.
        if (Array.isArray(parsed.field_errors) && parsed.field_errors.length) {
          const fields = parsed.field_errors
            .map((f: any) => `${f?.field ?? '?'}: ${f?.error ?? f?.message ?? '?'}`)
            .join('; ');
          message = `${message} (${fields})`;
        }
      } catch {
        /* non-JSON error body; keep the raw text */
      }
      throw new DeliveryProviderError(`doordash ${method} ${path}: ${res.status} ${message}`.slice(0, 600), {
        retryable: res.status >= 500 || res.status === 429,
        status: res.status,
        providerCode: code,
      });
    }

    try {
      return text ? (JSON.parse(text) as T) : ({} as T);
    } catch {
      throw new DeliveryProviderError(`doordash ${method} ${path}: unparseable success body`, {
        retryable: false,
        status: res.status,
      });
    }
  }

  private plausibleTimestamp(v: unknown): string | undefined {
    if (typeof v !== 'string' && typeof v !== 'number') return undefined;
    const ms = new Date(v).getTime();
    if (!Number.isFinite(ms)) return undefined;
    const now = this.now();
    if (ms < now - TIMESTAMP_MAX_PAST_MS || ms > now + TIMESTAMP_MAX_FUTURE_MS) return undefined;
    return new Date(ms).toISOString();
  }
}

/** DoorDash's allowed id alphabet. Also keeps a path segment a path segment. */
const EXTERNAL_ID_RE = /^[A-Za-z0-9\-._~]{1,128}$/;

function assertExternalId(id: string): void {
  if (!EXTERNAL_ID_RE.test(id ?? '')) {
    throw new DeliveryProviderError(`doordash: invalid external_delivery_id '${id}'`, {
      retryable: false,
    });
  }
}

/**
 * E.164 for US numbers, which is all Crease serves. Anything we cannot read
 * is sent as nothing rather than as a malformed number: a quote does not need
 * it, and a create without one fails loudly, naming the field.
 */
export function e164(phone: string | undefined): string | undefined {
  if (!phone) return undefined;
  const digits = phone.replace(/\D/g, '');
  if (phone.trim().startsWith('+')) {
    return digits.length >= 8 && digits.length <= 15 ? `+${digits}` : undefined;
  }
  if (digits.length === 10) return `+1${digits}`;
  if (digits.length === 11 && digits.startsWith('1')) return `+${digits}`;
  return undefined;
}

function instructions(notes: string | undefined): string | undefined {
  const s = notes?.trim();
  return s ? s.slice(0, MAX_INSTRUCTIONS) : undefined;
}

/** Split a display name into the given/family pair DoorDash asks for. */
function contactName(w: Waypoint): { dropoff_contact_given_name?: string; dropoff_contact_family_name?: string } {
  const parts = (w.name ?? '').trim().split(/\s+/).filter(Boolean);
  if (parts.length === 0) return {};
  return {
    dropoff_contact_given_name: parts[0],
    ...(parts.length > 1 ? { dropoff_contact_family_name: parts.slice(1).join(' ') } : {}),
  };
}

function unavailableReason(res: any): string | undefined {
  if (!res || typeof res !== 'object') return 'empty quote response';
  if (!res.external_delivery_id) return 'quote carried no id';
  const fee = Number(res.fee);
  if (!Number.isFinite(fee) || fee < 0 || fee > MAX_FEE_CENTS) return 'quote carried no usable fee';
  return undefined;
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

function b64url(s: string): string {
  return Buffer.from(s, 'utf8').toString('base64url');
}

function boundedFeeCents(v: unknown): number | undefined {
  const n = Number(v);
  if (v === undefined || v === null || !Number.isFinite(n) || n < 0 || n > MAX_FEE_CENTS) return undefined;
  return Math.round(n);
}

function validPincode(v: unknown): string | undefined {
  const s = typeof v === 'number' ? String(v) : v;
  return typeof s === 'string' && /^\d{4,8}$/.test(s) ? s : undefined;
}

/** Only https links go in front of a customer. */
function safeUrl(v: unknown): string | undefined {
  if (typeof v !== 'string') return undefined;
  try {
    return new URL(v).protocol === 'https:' ? v : undefined;
  } catch {
    return undefined;
  }
}

function finiteOrUndefined(v: unknown): number | undefined {
  const n = Number(v);
  return v !== undefined && v !== null && Number.isFinite(n) ? n : undefined;
}

function isFinite2(a: unknown, b: unknown): boolean {
  return Number.isFinite(a as number) && Number.isFinite(b as number);
}
