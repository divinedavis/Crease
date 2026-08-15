import { createHmac, timingSafeEqual } from 'node:crypto';
import type {
  CreateDeliveryRequest,
  DeliveryProvider,
  DeliveryState,
  LegStatus,
  Quote,
  QuoteRequest,
  VerificationMode,
  Waypoint,
  WebhookInput,
  WebhookResult,
} from './types.js';
import { DeliveryProviderError } from './types.js';

/**
 * Uber Direct.
 *
 * Uber's delivery-as-a-service network — NOT the rideshare fleet. Uber's
 * public Ride Request API was withdrawn from third parties years ago, so
 * "hire an Uber driver to run an errand" is not a thing you can build.
 * Uber Direct dispatches Uber Eats couriers, which is the same supply pool
 * minus the passenger seat, and it explicitly supports non-food items up to
 * roughly a large suitcase / 50 lb.
 *
 * Access is gated: sandbox -> pilot with real stores -> production, and
 * production needs Uber's written approval under an Uber for Business
 * agreement. There is no self-serve tier and no public rate card. Until those
 * credentials land, `isConfigured()` returns false and the dispatcher falls
 * through to the next provider in the chain.
 *
 * Field names below follow Uber's published v1 Direct API. Verify each one
 * against the sandbox on first connect — Uber has renamed fields between
 * revisions and the errors are not always obvious.
 */

const AUTH_URL = 'https://auth.uber.com/oauth/v2/token';
const API_BASE = 'https://api.uber.com/v1';

/**
 * Every outbound call is bounded.
 *
 * An unbounded `fetch` on a dead socket does not fail fast — it sits until the
 * OS gives up, minutes later, holding a dispatch that has already charged the
 * customer. Worse, it eventually throws a bare TypeError, which reads as a
 * permanent error and fails the leg. Bounding the wait and classifying the
 * failure correctly is what keeps a network blip from becoming a second
 * courier at the same address.
 */
const AUTH_TIMEOUT_MS = 10_000;
const CALL_TIMEOUT_MS = 15_000;

/**
 * Fallback token lifetime when Uber omits `expires_in`.
 *
 * This was 30 days. A credential rotated or revoked on Uber's side then left
 * us holding a dead token for a month, and since a 401 never cleared the cache
 * the integration stayed wedged until a redeploy. Re-minting every few minutes
 * costs one cheap call; guessing long costs the whole channel.
 */
const TOKEN_FALLBACK_TTL_SEC = 300;

/**
 * Bounds for values Uber hands back that we persist and show to customers.
 *
 * `pickedUpAt`/`completedAt` anchor the "your clothes are ready by" estimate,
 * so a garbage timestamp is not a cosmetic bug — a date in the past tells a
 * customer their order is done when a courier has not moved. Storing nothing
 * degrades to "unknown", which the UI already handles; storing a lie does not.
 */
const TIMESTAMP_MAX_PAST_MS = 7 * 24 * 60 * 60 * 1000;
const TIMESTAMP_MAX_FUTURE_MS = 24 * 60 * 60 * 1000;
/** No legitimate local courier leg costs $500. Above this it is a unit or
 *  currency mix-up, and it would flow straight into our margin math. */
const MAX_FEE_CENTS = 50_000;

/** Uber's status vocabulary -> ours. Unknown values fall back to dispatching. */
const STATUS_MAP: Record<string, LegStatus> = {
  pending: 'dispatching',
  pickup: 'en_route_to_pickup',
  pickup_imminent: 'en_route_to_pickup',
  pickup_arrived: 'at_pickup',
  pickup_complete: 'picked_up',
  dropoff: 'en_route_to_dropoff',
  dropoff_imminent: 'en_route_to_dropoff',
  dropoff_arrived: 'at_dropoff',
  delivered: 'delivered',
  canceled: 'cancelled',
  cancelled: 'cancelled',
  returned: 'returned',
  failed: 'failed',
};

const VERIFICATION_MAP: Record<VerificationMode, string | undefined> = {
  none: undefined,
  signature: 'signature',
  pincode: 'pincode',
  picture: 'picture',
  barcode: 'barcodes',
};

export interface UberDirectOptions {
  clientId?: string;
  clientSecret?: string;
  /** Uber's customer/organization id — the path segment on every call. */
  customerId?: string;
  /** Signing key for X-Postmates-Signature on webhooks. */
  webhookSecret?: string;
  /** Point at Uber's sandbox host during the pilot. */
  apiBase?: string;
  fetchImpl?: typeof fetch;
}

export class UberDirectProvider implements DeliveryProvider {
  readonly name = 'uber_direct';
  /** A real courier network: quotes from here are allowed to win on price. */
  readonly simulated = false;
  private token?: { value: string; expiresAt: number };
  /** Set while an auth call is in flight so concurrent dispatches share it. */
  private tokenInFlight?: Promise<string>;
  private readonly fetchImpl: typeof fetch;
  private readonly base: string;

  constructor(private readonly opts: UberDirectOptions) {
    this.fetchImpl = opts.fetchImpl ?? fetch;
    this.base = opts.apiBase ?? API_BASE;
  }

  isConfigured(): boolean {
    return Boolean(this.opts.clientId && this.opts.clientSecret && this.opts.customerId);
  }

  async quote(req: QuoteRequest): Promise<Quote> {
    const body = {
      pickup_address: formatAddress(req.pickup),
      dropoff_address: formatAddress(req.dropoff),
      pickup_latitude: req.pickup.lat,
      pickup_longitude: req.pickup.lng,
      dropoff_latitude: req.dropoff.lat,
      dropoff_longitude: req.dropoff.lng,
      pickup_ready_dt: req.pickupReadyAt,
      pickup_deadline_dt: req.pickupDeadlineAt,
      dropoff_ready_dt: req.dropoffReadyAt,
      dropoff_deadline_dt: req.dropoffDeadlineAt,
      manifest_total_value: req.manifest.declaredValueCents,
    };

    const res = await this.call<any>('POST', `/customers/${this.opts.customerId}/delivery_quotes`, body);
    return {
      quoteId: res.id,
      feeCents: res.fee,
      currency: (res.currency ?? 'usd').toLowerCase(),
      expiresAt: res.expires,
      estimatedPickupAt: res.pickup_duration
        ? new Date(Date.now() + res.pickup_duration * 60_000).toISOString()
        : undefined,
      estimatedDropoffAt: res.dropoff_eta,
      unavailableReason: unavailableReason(res),
    };
  }

  async createDelivery(req: CreateDeliveryRequest): Promise<DeliveryState> {
    const body = {
      quote_id: req.quoteId,
      // Uber dedupes on this. Reusing a leg id after a timeout returns the
      // original delivery instead of double-dispatching a courier.
      external_id: req.externalId,
      external_store_id: req.orderReference,

      pickup_name: req.pickup.name,
      pickup_address: formatAddress(req.pickup),
      pickup_phone_number: req.pickup.phone,
      pickup_notes: req.pickup.notes,
      pickup_latitude: req.pickup.lat,
      pickup_longitude: req.pickup.lng,
      pickup_verification: verification(req.pickup.verification),

      dropoff_name: req.dropoff.name,
      dropoff_address: formatAddress(req.dropoff),
      dropoff_phone_number: req.dropoff.phone,
      dropoff_notes: req.dropoff.notes,
      dropoff_latitude: req.dropoff.lat,
      dropoff_longitude: req.dropoff.lng,
      dropoff_verification: verification(req.dropoff.verification),

      manifest_reference: req.orderReference,
      manifest_total_value: req.manifest.declaredValueCents,
      manifest_items: [
        {
          name: req.manifest.description,
          quantity: req.manifest.itemCount,
          size: 'large',
          weight: req.manifest.weightLbs ? Math.round(req.manifest.weightLbs * 453.592) : undefined,
          price: req.manifest.declaredValueCents,
        },
      ],

      pickup_ready_dt: req.pickupReadyAt,
      pickup_deadline_dt: req.pickupDeadlineAt,
      dropoff_ready_dt: req.dropoffReadyAt,
      dropoff_deadline_dt: req.dropoffDeadlineAt,

      // Never leave garments on a doorstep. If nobody answers, the courier
      // brings them back and we re-dispatch rather than eat a loss claim.
      deliverable_action: 'deliverable_action_meet_at_door',
      undeliverable_action: 'return',
    };

    const res = await this.call<any>('POST', `/customers/${this.opts.customerId}/deliveries`, body);
    return this.toState(res);
  }

  async getDelivery(providerDeliveryId: string): Promise<DeliveryState> {
    const res = await this.call<any>(
      'GET',
      `/customers/${this.opts.customerId}/deliveries/${providerDeliveryId}`,
    );
    return this.toState(res);
  }

  async cancelDelivery(providerDeliveryId: string): Promise<DeliveryState> {
    const res = await this.call<any>(
      'POST',
      `/customers/${this.opts.customerId}/deliveries/${providerDeliveryId}/cancel`,
      {},
    );
    return this.toState(res);
  }

  async handleWebhook(input: WebhookInput): Promise<WebhookResult> {
    if (!this.opts.webhookSecret) return { signatureValid: false };

    // Uber signs the raw bytes. Re-serializing the parsed object changes key
    // order and silently breaks the HMAC, so verify before any JSON.parse.
    const sent = header(input.headers, 'x-postmates-signature');
    const expected = createHmac('sha256', this.opts.webhookSecret)
      .update(input.rawBody)
      .digest('hex');
    const valid =
      !!sent &&
      sent.length === expected.length &&
      timingSafeEqual(Buffer.from(sent), Buffer.from(expected));
    if (!valid) return { signatureValid: false };

    const body = JSON.parse(input.rawBody.toString('utf8'));
    const kind = body.kind ?? body.event_type;
    if (kind !== 'event.delivery_status' && kind !== 'event.courier_update') {
      return { signatureValid: true, ignored: `unhandled kind: ${kind}` };
    }

    const data = body.data ?? body;
    return {
      signatureValid: true,
      event: {
        eventId: body.id ?? body.event_id,
        eventType: kind,
        externalId: data.external_id,
        ...this.toState(data),
      },
    };
  }

  /**
   * Map a provider payload onto our vocabulary — and don't trust it.
   *
   * Everything here is written to delivery_legs and most of it is shown to a
   * customer, so a field arriving malformed (or forged through the webhook
   * path) becomes a wrong promise in the app rather than a parse error we
   * would notice. Anything implausible is dropped instead of stored: the UI
   * already renders a missing timestamp as "pending", but it renders a
   * timestamp from last month as "your clothes are ready".
   */
  private toState(d: any): DeliveryState {
    const raw = d.status ?? d.delivery_status;
    return {
      providerDeliveryId: d.id ?? d.delivery_id,
      status: STATUS_MAP[raw] ?? 'dispatching',
      providerStatus: raw,
      trackingUrl: d.tracking_url,
      feeCents: boundedFeeCents(d.fee),
      courier: d.courier
        ? {
            name: d.courier.name,
            phone: d.courier.phone_number,
            vehicle: d.courier.vehicle_type,
            lat: d.courier.location?.lat,
            lng: d.courier.location?.lng,
          }
        : undefined,
      dropoffPincode: validPincode(d.dropoff?.verification?.pincode?.value),
      pickedUpAt: plausibleTimestamp(d.pickup?.status_timestamp),
      completedAt: plausibleTimestamp(d.dropoff?.status_timestamp ?? d.complete),
      error: d.undeliverable_reason,
    };
  }

  private async token_(): Promise<string> {
    // 60s of slack so a token cannot expire mid-flight.
    if (this.token && this.token.expiresAt > Date.now() + 60_000) return this.token.value;

    // Both legs of an order dispatch at once, and the reconciler polls beside
    // them. Without this latch each of them opens its own auth call against an
    // endpoint Uber rate-limits hard — and issuers that invalidate the prior
    // token on every mint would leave the callers knocking each other out.
    // One mint, shared by everyone waiting on it.
    if (!this.tokenInFlight) {
      this.tokenInFlight = this.mintToken().finally(() => {
        this.tokenInFlight = undefined;
      });
    }
    return this.tokenInFlight;
  }

  private async mintToken(): Promise<string> {
    const res = await this.fetchOrThrow(
      AUTH_URL,
      {
        method: 'POST',
        headers: { 'content-type': 'application/x-www-form-urlencoded' },
        body: new URLSearchParams({
          client_id: this.opts.clientId!,
          client_secret: this.opts.clientSecret!,
          grant_type: 'client_credentials',
          scope: 'eats.deliveries',
        }),
      },
      AUTH_TIMEOUT_MS,
      'auth',
    );
    if (!res.ok) {
      this.token = undefined;
      throw new DeliveryProviderError(`uber auth failed: ${res.status}`, {
        retryable: res.status >= 500 || res.status === 429,
        status: res.status,
      });
    }

    let json: any;
    try {
      json = await res.json();
    } catch (err) {
      this.token = undefined;
      throw new DeliveryProviderError(`uber auth returned unparseable body: ${(err as Error).message}`, {
        retryable: true,
        status: res.status,
      });
    }

    // A 200 carrying no access_token used to be cached verbatim, so every
    // later call went out as "Bearer undefined" — and with the old month-long
    // fallback TTL nothing re-minted, so the integration 401'd until someone
    // redeployed. Refuse to cache what we cannot use.
    const value = json?.access_token;
    if (typeof value !== 'string' || value.length === 0) {
      this.token = undefined;
      throw new DeliveryProviderError('uber auth response had no access_token', {
        retryable: true,
        status: res.status,
      });
    }

    const ttl = Number(json.expires_in);
    this.token = {
      value,
      expiresAt:
        Date.now() + (Number.isFinite(ttl) && ttl > 0 ? ttl : TOKEN_FALLBACK_TTL_SEC) * 1000,
    };
    return value;
  }

  /**
   * The only place this provider touches the network.
   *
   * A dropped socket, a DNS failure or an abort surfaces as a bare TypeError /
   * DOMException. Left as-is the dispatcher reads it as a permanent error,
   * fails the leg, and the retry mints a fresh external_id — so Uber's dedupe
   * never fires and a SECOND real courier rolls up to the same address while
   * the orphaned first delivery can no longer be cancelled. These failures are
   * the textbook retryable case: we do not know whether the request landed,
   * and replaying it under the same external_id is exactly what makes asking
   * again safe.
   */
  private async fetchOrThrow(
    url: string,
    init: RequestInit,
    timeoutMs: number,
    what: string,
  ): Promise<Response> {
    try {
      return await this.fetchImpl(url, { ...init, signal: AbortSignal.timeout(timeoutMs) });
    } catch (err) {
      if (err instanceof DeliveryProviderError) throw err;
      const e = err as Error;
      throw new DeliveryProviderError(`uber ${what} network failure: ${e.message}`, {
        retryable: true,
        providerCode: e.name === 'TimeoutError' ? 'timeout' : 'network',
      });
    }
  }

  private async call<T>(
    method: string,
    path: string,
    body?: unknown,
    retriedAuth = false,
  ): Promise<T> {
    if (!this.isConfigured()) {
      throw new DeliveryProviderError('uber_direct is not configured', { retryable: false });
    }
    const res = await this.fetchOrThrow(
      `${this.base}${path}`,
      {
        method,
        headers: {
          authorization: `Bearer ${await this.token_()}`,
          'content-type': 'application/json',
        },
        body: body === undefined ? undefined : JSON.stringify(body),
      },
      CALL_TIMEOUT_MS,
      `${method} ${path}`,
    );

    let text: string;
    try {
      text = await res.text();
    } catch (err) {
      // The connection died while the body was streaming. Same reasoning as
      // above: the request may well have been processed, so this has to be
      // retryable under the same external_id, not a leg failure.
      throw new DeliveryProviderError(
        `uber ${method} ${path} body read failed: ${(err as Error).message}`,
        { retryable: true, providerCode: 'network', status: res.status },
      );
    }

    if (!res.ok) {
      // A revoked or rotated credential answers 401/403, which is neither 5xx
      // nor 429 — so it used to be classified permanent AND the dead token
      // stayed cached, wedging every subsequent call until the process
      // restarted. Drop it and mint a fresh one once. Replaying the request is
      // safe: an unauthenticated call was never processed, and external_id
      // dedupes it regardless.
      if ((res.status === 401 || res.status === 403) && !retriedAuth) {
        this.token = undefined;
        return this.call<T>(method, path, body, true);
      }

      let code: string | undefined;
      let message = text;
      try {
        const parsed = JSON.parse(text);
        code = parsed.code ?? parsed.kind;
        message = parsed.message ?? text;
      } catch {
        /* non-JSON error body; keep the raw text */
      }
      throw new DeliveryProviderError(`uber ${method} ${path}: ${message}`, {
        // 409 is Uber's "already exists" on a replayed external_id — the
        // caller should re-read rather than retry blindly. A 401/403 that
        // survived the re-auth above is a genuinely bad credential, so it
        // stays non-retryable; the cache is already cleared, which is what
        // lets a re-issued key recover without a redeploy.
        retryable: res.status >= 500 || res.status === 429,
        status: res.status,
        providerCode: code,
      });
    }

    try {
      return text ? (JSON.parse(text) as T) : ({} as T);
    } catch {
      throw new DeliveryProviderError(`uber ${method} ${path}: unparseable success body`, {
        retryable: false,
        status: res.status,
      });
    }
  }
}

/** Uber accepts a JSON-encoded structured address; it geocodes server-side. */
function formatAddress(w: Waypoint): string {
  return w.address;
}

function verification(mode: VerificationMode | undefined) {
  const m = mode ? VERIFICATION_MAP[mode] : undefined;
  if (!m) return undefined;
  return m === 'signature'
    ? { signature_requirement: { enabled: true, collect_signer_name: true } }
    : { [m]: { enabled: true } };
}

function header(h: WebhookInput['headers'], key: string): string | undefined {
  const v = h[key] ?? h[key.toLowerCase()];
  return Array.isArray(v) ? v[0] : v;
}

/**
 * Why a 200 quote can still be unusable.
 *
 * Uber does not always answer "we don't serve that address" with an HTTP
 * error — a 200 can come back carrying a serviceability flag, or an envelope
 * with no quote in it. The chain filters on `unavailableReason`, so anything
 * not surfaced here is treated as a bookable quote and dispatched to a carrier
 * that will refuse it, after the customer has already been charged. Field
 * spellings have drifted between API revisions, so check each one seen rather
 * than betting the order on a single name.
 */
function unavailableReason(res: any): string | undefined {
  if (!res || typeof res !== 'object') return 'empty quote response';
  if (res.unavailable_reason) return String(res.unavailable_reason);
  if (res.serviceable === false || res.is_serviceable === false) return 'route not serviceable';
  if (res.deliverable === false) return 'address not deliverable';
  if (res.kind === 'error') return String(res.message ?? 'quote returned an error envelope');
  // Nothing to book against: the dispatcher needs an id to create the delivery
  // and a fee to write onto the leg.
  if (!res.id) return 'quote carried no id';
  if (!Number.isFinite(Number(res.fee))) return 'quote carried no fee';
  return undefined;
}

/** Reject a fee we could not have been charged; unset is safer than wrong,
 *  since the caller falls back to the fee we already recorded at quote time. */
function boundedFeeCents(v: unknown): number | undefined {
  const n = Number(v);
  if (!Number.isFinite(n) || n < 0 || n > MAX_FEE_CENTS) return undefined;
  return Math.round(n);
}

/** Only the digits Uber actually issues. A free-form string here goes straight
 *  onto the customer's screen as the code they read out at the door. */
function validPincode(v: unknown): string | undefined {
  const s = typeof v === 'number' ? String(v) : v;
  if (typeof s !== 'string' || !/^\d{4,8}$/.test(s)) return undefined;
  return s;
}

/** Keep only timestamps that could describe this delivery. A parse failure, a
 *  date from last month, or one in next week's future all become "unknown"
 *  rather than a ready-time promise we cannot keep. */
function plausibleTimestamp(v: unknown): string | undefined {
  if (typeof v !== 'string' && typeof v !== 'number') return undefined;
  const ms = new Date(v).getTime();
  if (!Number.isFinite(ms)) return undefined;
  const now = Date.now();
  if (ms < now - TIMESTAMP_MAX_PAST_MS || ms > now + TIMESTAMP_MAX_FUTURE_MS) return undefined;
  return new Date(ms).toISOString();
}
