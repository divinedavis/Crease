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
  private token?: { value: string; expiresAt: number };
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

  private toState(d: any): DeliveryState {
    const raw = d.status ?? d.delivery_status;
    return {
      providerDeliveryId: d.id ?? d.delivery_id,
      status: STATUS_MAP[raw] ?? 'dispatching',
      providerStatus: raw,
      trackingUrl: d.tracking_url,
      feeCents: d.fee,
      courier: d.courier
        ? {
            name: d.courier.name,
            phone: d.courier.phone_number,
            vehicle: d.courier.vehicle_type,
            lat: d.courier.location?.lat,
            lng: d.courier.location?.lng,
          }
        : undefined,
      dropoffPincode: d.dropoff?.verification?.pincode?.value,
      pickedUpAt: d.pickup?.status_timestamp,
      completedAt: d.dropoff?.status_timestamp ?? d.complete,
      error: d.undeliverable_reason,
    };
  }

  private async token_(): Promise<string> {
    // 60s of slack so a token cannot expire mid-flight.
    if (this.token && this.token.expiresAt > Date.now() + 60_000) return this.token.value;

    const res = await this.fetchImpl(AUTH_URL, {
      method: 'POST',
      headers: { 'content-type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        client_id: this.opts.clientId!,
        client_secret: this.opts.clientSecret!,
        grant_type: 'client_credentials',
        scope: 'eats.deliveries',
      }),
    });
    if (!res.ok) {
      throw new DeliveryProviderError(`uber auth failed: ${res.status}`, {
        retryable: res.status >= 500 || res.status === 429,
        status: res.status,
      });
    }
    const json: any = await res.json();
    this.token = {
      value: json.access_token,
      expiresAt: Date.now() + (json.expires_in ?? 2592000) * 1000,
    };
    return this.token.value;
  }

  private async call<T>(method: string, path: string, body?: unknown): Promise<T> {
    if (!this.isConfigured()) {
      throw new DeliveryProviderError('uber_direct is not configured', { retryable: false });
    }
    const res = await this.fetchImpl(`${this.base}${path}`, {
      method,
      headers: {
        authorization: `Bearer ${await this.token_()}`,
        'content-type': 'application/json',
      },
      body: body === undefined ? undefined : JSON.stringify(body),
    });

    const text = await res.text();
    if (!res.ok) {
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
        // caller should re-read rather than retry blindly.
        retryable: res.status >= 500 || res.status === 429,
        status: res.status,
        providerCode: code,
      });
    }
    return text ? (JSON.parse(text) as T) : ({} as T);
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
