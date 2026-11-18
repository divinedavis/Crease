import { createHmac, randomUUID, timingSafeEqual } from 'node:crypto';
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
 * DoorDash Drive (v2).
 *
 * DoorDash's delivery-as-a-service API: Dashers carrying our bags between
 * customer and cleaner, the same shape of job as Uber Direct. Unlike Uber it
 * is self-serve. Sign up in the DoorDash Developer Portal, make a sandbox
 * access key and test against it today, then ask for production from the same
 * portal. There is a public rate card instead of a negotiated one.
 *
 * Auth is a short-lived JWT we sign ourselves (HS256, the portal's signing
 * secret base64url-decoded), so there is no token endpoint to rate-limit us
 * and no cached credential to go stale.
 *
 * Deliveries are addressed by OUR id (`external_delivery_id`), not one
 * DoorDash mints. The leg id is that id, which makes `createDelivery` safe to
 * replay: a second create with the same id answers 409 and we read back the
 * original rather than sending a second Dasher.
 *
 * Field names follow DoorDash's published Drive v2 reference. Verify each one
 * against the sandbox on first connect, `dasher_allowed_vehicles` above all:
 * hanging garments need a car, and not every market honours the request.
 */

const API_BASE = 'https://openapi.doordash.com/drive/v2';

/** Same reasoning as Uber's bounds: a dead socket must fail fast and retryable. */
const CALL_TIMEOUT_MS = 15_000;
/** DoorDash caps JWT lifetime at 30 minutes; five is plenty for one call. */
const JWT_TTL_SEC = 300;
const TIMESTAMP_MAX_PAST_MS = 7 * 24 * 60 * 60 * 1000;
const TIMESTAMP_MAX_FUTURE_MS = 24 * 60 * 60 * 1000;
const MAX_FEE_CENTS = 50_000;
/** Drive quotes are held for five minutes once issued. */
const QUOTE_FALLBACK_TTL_MS = 5 * 60_000;

/** Drive's `delivery_status` -> ours. Unknown values fall back to dispatching. */
const STATUS_MAP: Record<string, LegStatus> = {
  quote: 'pending',
  created: 'dispatching',
  confirmed: 'courier_assigned',
  enroute_to_pickup: 'en_route_to_pickup',
  arrived_at_pickup: 'at_pickup',
  picked_up: 'picked_up',
  enroute_to_dropoff: 'en_route_to_dropoff',
  arrived_at_dropoff: 'at_dropoff',
  delivered: 'delivered',
  // A return is still a Dasher holding our garments. Keep it live until they
  // are actually back at the pickup, which is when DoorDash says `returned`.
  enroute_to_return: 'en_route_to_dropoff',
  arrived_at_return: 'at_dropoff',
  returned: 'returned',
  cancelled: 'cancelled',
  canceled: 'cancelled',
};

/**
 * Webhook `event_name` -> ours, for payloads that carry no `delivery_status`.
 * DoorDash includes the status on most events, and the status wins when it
 * does: it is the delivery's state, while the event name is only what changed.
 */
const EVENT_MAP: Record<string, LegStatus> = {
  DELIVERY_CREATED: 'dispatching',
  DASHER_CONFIRMED: 'courier_assigned',
  DASHER_ENROUTE_TO_PICKUP: 'en_route_to_pickup',
  DASHER_CONFIRMED_PICKUP_ARRIVAL: 'at_pickup',
  DASHER_PICKED_UP: 'picked_up',
  DASHER_ENROUTE_TO_DROPOFF: 'en_route_to_dropoff',
  DASHER_CONFIRMED_DROPOFF_ARRIVAL: 'at_dropoff',
  DASHER_DROPPED_OFF: 'delivered',
  DELIVERY_RETURN_INITIALIZED: 'en_route_to_dropoff',
  DASHER_ENROUTE_TO_RETURN: 'en_route_to_dropoff',
  DASHER_CONFIRMED_RETURN_ARRIVAL: 'at_dropoff',
  DELIVERY_RETURNED: 'returned',
  DELIVERY_CANCELLED: 'cancelled',
};

export interface DoorDashDriveOptions {
  /** Developer Portal: Developer ID. */
  developerId?: string;
  /** Developer Portal access key: Key ID. */
  keyId?: string;
  /** Developer Portal access key: Signing Secret (base64url, as shown). */
  signingSecret?: string;
  /**
   * The exact Authorization header value set on the webhook endpoint in the
   * Developer Portal. DoorDash does not HMAC its callbacks; it sends back the
   * header you configured, so this is a shared secret compared in constant time.
   */
  webhookSecret?: string;
  apiBase?: string;
  fetchImpl?: typeof fetch;
}

export class DoorDashDriveProvider implements DeliveryProvider {
  readonly name = 'doordash';
  /** A real courier network: quotes from here are allowed to win on price. */
  readonly simulated = false;
  private readonly fetchImpl: typeof fetch;
  private readonly base: string;

  constructor(private readonly opts: DoorDashDriveOptions) {
    this.fetchImpl = opts.fetchImpl ?? fetch;
    this.base = opts.apiBase ?? API_BASE;
  }

  isConfigured(): boolean {
    return Boolean(this.opts.developerId && this.opts.keyId && this.opts.signingSecret);
  }

  async quote(req: QuoteRequest): Promise<Quote> {
    // A quote needs an id of its own. The leg id is not known here, and it
    // must stay free for createDelivery: a quote that is never accepted would
    // otherwise occupy it. Unaccepted quotes simply lapse on DoorDash's side.
    const quoteId = `crease-q-${randomUUID()}`;
    const res = await this.call<any>('POST', '/quotes', this.deliveryBody(quoteId, req));
    return {
      quoteId,
      feeCents: Number(res?.fee),
      currency: String(res?.currency ?? 'usd').toLowerCase(),
      expiresAt:
        plausibleTimestamp(res?.quote_expiration_time) ??
        new Date(Date.now() + QUOTE_FALLBACK_TTL_MS).toISOString(),
      estimatedPickupAt: plausibleTimestamp(res?.pickup_time_estimated),
      estimatedDropoffAt: plausibleTimestamp(res?.dropoff_time_estimated),
      unavailableReason: unavailableReason(res),
    };
  }

  /**
   * Created directly under the leg id rather than by accepting the quote.
   *
   * Accepting would put the delivery under the quote's throwaway id, which a
   * retry after a lost response cannot find again. Creating under the leg id
   * keeps the one property that matters: replaying the same leg can never
   * dispatch a second Dasher. The price is the same rate card the quote read.
   */
  async createDelivery(req: CreateDeliveryRequest): Promise<DeliveryState> {
    try {
      const res = await this.call<any>('POST', '/deliveries', this.deliveryBody(req.externalId, req));
      return this.toState(res);
    } catch (err) {
      // 409: this leg already has a delivery, most likely from an earlier
      // attempt whose response never reached us. That delivery is the answer.
      if (err instanceof DeliveryProviderError && err.opts.status === 409) {
        return this.getDelivery(req.externalId);
      }
      throw err;
    }
  }

  async getDelivery(providerDeliveryId: string): Promise<DeliveryState> {
    const res = await this.call<any>('GET', `/deliveries/${encodeURIComponent(providerDeliveryId)}`);
    return this.toState(res);
  }

  async cancelDelivery(providerDeliveryId: string): Promise<DeliveryState> {
    const res = await this.call<any>(
      'PUT',
      `/deliveries/${encodeURIComponent(providerDeliveryId)}/cancel`,
      {},
    );
    return this.toState(res);
  }

  async handleWebhook(input: WebhookInput): Promise<WebhookResult> {
    if (!this.opts.webhookSecret) return { signatureValid: false };

    const sent = header(input.headers, 'authorization') ?? '';
    // Compare digests so the lengths always match and nothing leaks through
    // an early exit on a length mismatch.
    const valid = timingSafeEqual(digest(sent), digest(this.opts.webhookSecret));
    if (!valid) return { signatureValid: false };

    let body: any;
    try {
      body = JSON.parse(input.rawBody.toString('utf8'));
    } catch {
      return { signatureValid: true, ignored: 'unparseable body' };
    }
    const kind: string | undefined = body?.event_name;
    const hasStatus = typeof body?.delivery_status === 'string';
    if (!kind || (!hasStatus && !(kind in EVENT_MAP))) {
      return { signatureValid: true, ignored: `unhandled event: ${kind}` };
    }
    if (!body.external_delivery_id) {
      return { signatureValid: true, ignored: 'event carried no external_delivery_id' };
    }

    const state = this.toState(body);
    if (!hasStatus) state.status = EVENT_MAP[kind]!;
    return {
      signatureValid: true,
      event: {
        // DoorDash sends no event id. Delivery + event + timestamp is unique
        // per transition and identical on a redelivery, which is what dedupe
        // needs. Without a timestamp we cannot tell a retry from a repeat, so
        // fall back to delivery + event: a duplicate status is harmless.
        eventId: [body.external_delivery_id, kind, body.created_at].filter(Boolean).join(':'),
        eventType: kind,
        externalId: body.external_delivery_id,
        ...state,
      },
    };
  }

  /** One body for quote and create; DoorDash validates them identically. */
  private deliveryBody(externalDeliveryId: string, req: QuoteRequest) {
    const signature =
      req.dropoff.verification === 'signature' || req.pickup.verification === 'signature';
    return {
      external_delivery_id: externalDeliveryId,

      pickup_address: req.pickup.address,
      pickup_business_name: req.pickup.name,
      pickup_phone_number: e164(req.pickup.phone),
      pickup_instructions: req.pickup.notes,
      pickup_location:
        req.pickup.lat != null && req.pickup.lng != null
          ? { lat: req.pickup.lat, lng: req.pickup.lng }
          : undefined,

      dropoff_address: req.dropoff.address,
      dropoff_business_name: req.dropoff.name,
      dropoff_contact_given_name: req.dropoff.name,
      dropoff_phone_number: e164(req.dropoff.phone),
      dropoff_instructions: req.dropoff.notes,
      dropoff_location:
        req.dropoff.lat != null && req.dropoff.lng != null
          ? { lat: req.dropoff.lat, lng: req.dropoff.lng }
          : undefined,

      order_value: req.manifest.declaredValueCents,
      items: [
        {
          name: req.manifest.description,
          quantity: req.manifest.itemCount,
          price: req.manifest.declaredValueCents,
        },
      ],
      dasher_allowed_vehicles: req.manifest.requiresCar ? ['car'] : undefined,

      pickup_window:
        req.pickupReadyAt && req.pickupDeadlineAt
          ? { start_time: req.pickupReadyAt, end_time: req.pickupDeadlineAt }
          : undefined,
      dropoff_window:
        req.dropoffReadyAt && req.dropoffDeadlineAt
          ? { start_time: req.dropoffReadyAt, end_time: req.dropoffDeadlineAt }
          : undefined,

      // Never leave garments on a doorstep. Hand-to-hand with a signature,
      // and if nobody answers the Dasher brings them back.
      contactless_dropoff: false,
      dropoff_requires_signature: signature || undefined,
      action_if_undeliverable: 'return_to_pickup',
    };
  }

  /** Map a Drive payload onto our vocabulary, dropping anything implausible. */
  private toState(d: any): DeliveryState {
    const raw = d?.delivery_status;
    const vehicle = [d?.dasher_vehicle_make, d?.dasher_vehicle_model].filter(Boolean).join(' ');
    const hasDasher = d?.dasher_name || d?.dasher_location || d?.dasher_dropoff_phone_number;
    return {
      providerDeliveryId: d?.external_delivery_id,
      status: STATUS_MAP[raw] ?? 'dispatching',
      providerStatus: raw,
      trackingUrl: d?.tracking_url,
      feeCents: boundedFeeCents(d?.fee),
      courier: hasDasher
        ? {
            name: d.dasher_name,
            // The masked number DoorDash relays to the Dasher, not their own line.
            phone: d.dasher_dropoff_phone_number ?? d.dasher_pickup_phone_number,
            vehicle: vehicle || undefined,
            lat: d.dasher_location?.lat,
            lng: d.dasher_location?.lng,
          }
        : undefined,
      pickedUpAt: plausibleTimestamp(d?.pickup_time_actual),
      completedAt: plausibleTimestamp(d?.dropoff_time_actual),
      error: d?.cancellation_reason ?? d?.cancellation_reason_message,
    };
  }

  /** A fresh JWT per call: cheap, local, and never stale after a key rotation. */
  private jwt(): string {
    const now = Math.floor(Date.now() / 1000);
    const head = b64url(JSON.stringify({ alg: 'HS256', typ: 'JWT', 'dd-ver': 'DD-JWT-V1' }));
    const payload = b64url(
      JSON.stringify({
        aud: 'doordash',
        iss: this.opts.developerId,
        kid: this.opts.keyId,
        iat: now,
        exp: now + JWT_TTL_SEC,
      }),
    );
    const sig = createHmac('sha256', Buffer.from(this.opts.signingSecret!, 'base64url'))
      .update(`${head}.${payload}`)
      .digest('base64url');
    return `${head}.${payload}.${sig}`;
  }

  private async call<T>(method: string, path: string, body?: unknown): Promise<T> {
    if (!this.isConfigured()) {
      throw new DeliveryProviderError('doordash is not configured', { retryable: false });
    }

    let res: Response;
    try {
      res = await this.fetchImpl(`${this.base}${path}`, {
        method,
        headers: { authorization: `Bearer ${this.jwt()}`, 'content-type': 'application/json' },
        body: body === undefined ? undefined : JSON.stringify(body),
        signal: AbortSignal.timeout(CALL_TIMEOUT_MS),
      });
    } catch (err) {
      // We cannot know whether the request landed. Retryable, and safe to
      // replay because the leg id is the delivery id.
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
      let code: string | undefined;
      let message = text;
      try {
        const parsed = JSON.parse(text);
        code = parsed.code;
        message = parsed.message ?? text;
        // Validation errors name the offending field here, not in `message`.
        if (Array.isArray(parsed.field_errors) && parsed.field_errors.length > 0) {
          const fields = parsed.field_errors
            .map((f: any) => `${f.field}: ${f.error}`)
            .join('; ');
          message = `${message} (${fields})`;
        }
      } catch {
        /* non-JSON error body; keep the raw text */
      }
      throw new DeliveryProviderError(`doordash ${method} ${path}: ${message}`, {
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
}

function b64url(s: string): string {
  return Buffer.from(s, 'utf8').toString('base64url');
}

function digest(s: string): Buffer {
  return createHmac('sha256', 'crease-webhook-compare').update(s).digest();
}

function header(h: WebhookInput['headers'], key: string): string | undefined {
  const v = h[key] ?? h[key.toLowerCase()];
  return Array.isArray(v) ? v[0] : v;
}

/**
 * DoorDash rejects anything but E.164. Our rows hold whatever the customer
 * typed, so normalise US numbers and leave the rest for DoorDash to judge.
 */
export function e164(phone: string | undefined): string | undefined {
  if (!phone) return undefined;
  const trimmed = phone.trim();
  const digits = trimmed.replace(/\D/g, '');
  if (trimmed.startsWith('+')) return `+${digits}`;
  if (digits.length === 10) return `+1${digits}`;
  if (digits.length === 11 && digits.startsWith('1')) return `+${digits}`;
  return trimmed;
}

/** Why a 200 quote can still be unusable: no fee is nothing to book against. */
function unavailableReason(res: any): string | undefined {
  if (!res || typeof res !== 'object') return 'empty quote response';
  if (!Number.isFinite(Number(res.fee))) return 'quote carried no fee';
  if (boundedFeeCents(res.fee) === undefined) return `implausible fee: ${res.fee}`;
  return undefined;
}

function boundedFeeCents(v: unknown): number | undefined {
  if (v === undefined || v === null || v === '') return undefined;
  const n = Number(v);
  if (!Number.isFinite(n) || n < 0 || n > MAX_FEE_CENTS) return undefined;
  return Math.round(n);
}

function plausibleTimestamp(v: unknown): string | undefined {
  if (typeof v !== 'string' && typeof v !== 'number') return undefined;
  const ms = new Date(v).getTime();
  if (!Number.isFinite(ms)) return undefined;
  const now = Date.now();
  if (ms < now - TIMESTAMP_MAX_PAST_MS || ms > now + TIMESTAMP_MAX_FUTURE_MS) return undefined;
  return new Date(ms).toISOString();
}
