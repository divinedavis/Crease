import { createHmac, timingSafeEqual } from 'node:crypto';
import { e164 } from './doordashDrive.js';
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
 * Nash.
 *
 * Nash is not a courier. It is one account in front of many courier networks
 * (DoorDash, Uber and dozens of local fleets): it asks each one that covers the
 * route for a price and books the one we pick. For Crease that means one
 * integration instead of one per carrier, and no per-carrier approval queue.
 *
 * The flow, per leg:
 *  1. quote()          POST /v1/order/get_quotes   price only, nothing booked
 *  2. createDelivery() POST /v1/order/external-identifier/{legId}
 *                      creates (or, on a replay, finds) the order under OUR
 *                      leg id, with fresh quotes on it
 *                      POST /v1/select_quote        books the cheapest one
 *  3. getDelivery()    GET  /v1/jobs/{jobId}
 *
 * A dispatched order becomes a "job"; a job holds one or more "tasks" (each a
 * delivery attempt — a reassignment adds a new task rather than editing the
 * old one). The newest task is the one that is live.
 *
 * Laundry and dry cleaning are heavy and bulky, so every order carries its
 * weight and a minimum vehicle size: Nash only offers couriers who can carry
 * it, and a bike courier never gets a 25 lb wash-and-fold bag.
 *
 * Webhooks are signed by Svix (svix-id / svix-timestamp / svix-signature),
 * so unlike DoorDash's the payload can be trusted once verified.
 *
 * Docs: https://docs.usenash.com/
 */

const API_BASE = 'https://api.usenash.com';
const CALL_TIMEOUT_MS = 20_000;

/** Svix rejects anything older/newer than this; so do we (replay window). */
const WEBHOOK_TOLERANCE_SEC = 5 * 60;

/** Go out as "scheduled" only when the window starts this far ahead. */
const SCHEDULE_MIN_LEAD_MS = 60 * 60 * 1000;

const TIMESTAMP_MAX_PAST_MS = 7 * 24 * 60 * 60 * 1000;
const TIMESTAMP_MAX_FUTURE_MS = 24 * 60 * 60 * 1000;
const MAX_FEE_CENTS = 50_000;
/** Nash's limits on free-text fields. */
const MAX_INSTRUCTIONS = 280;
const MAX_BUSINESS_NAME = 80;

/** Nash's normalized delivery statuses -> ours. Wire values are snake_case. */
const STATUS_MAP: Record<string, LegStatus> = {
  created: 'dispatching',
  scheduled: 'dispatching',
  not_assigned_driver: 'dispatching',
  assigned_driver: 'courier_assigned',
  started: 'courier_assigned',
  pickup_enroute: 'en_route_to_pickup',
  pickup_arrived: 'at_pickup',
  items_pick_update: 'at_pickup',
  picking_complete: 'at_pickup',
  items_pick_complete: 'at_pickup',
  pickup_complete: 'picked_up',
  pick_complete: 'picked_up',
  dropoff_enroute: 'en_route_to_dropoff',
  dropoff_arrived: 'at_dropoff',
  dropoff_complete: 'delivered',
  // Nobody took the bag; it is on its way back. Our vocabulary has no
  // "returning", and at_dropoff is the furthest progress that is still true.
  return_in_progress: 'at_dropoff',
  return_arrived: 'at_dropoff',
  returned: 'returned',
  canceled_by_customer: 'cancelled',
  canceled_by_provider: 'cancelled',
  canceled_by_nash: 'cancelled',
  canceled_by_auto_reassign: 'cancelled',
  expired: 'failed',
  failed: 'failed',
};

const BEFORE_PICKUP = new Set<LegStatus>([
  'pending',
  'dispatching',
  'courier_assigned',
  'en_route_to_pickup',
  'at_pickup',
]);

export interface NashOptions {
  apiKey?: string;
  /** Only needed when the key can see more than one organization. */
  orgId?: string;
  /** Svix endpoint signing secret, `whsec_...`. Unset = every webhook refused. */
  webhookSecret?: string;
  /** https://api.sandbox.usenash.com while testing. */
  apiBase?: string;
  fetchImpl?: typeof fetch;
  now?: () => number;
}

export class NashProvider implements DeliveryProvider {
  readonly name = 'nash';
  readonly simulated = false;
  private readonly fetchImpl: typeof fetch;
  private readonly base: string;
  private readonly now: () => number;

  constructor(private readonly opts: NashOptions) {
    this.fetchImpl = opts.fetchImpl ?? fetch;
    this.base = (opts.apiBase ?? API_BASE).replace(/\/+$/, '').replace(/\/v1$/, '');
    this.now = opts.now ?? Date.now;
  }

  isConfigured(): boolean {
    return Boolean(this.opts.apiKey);
  }

  async quote(req: QuoteRequest): Promise<Quote> {
    const order = await this.call<any>('POST', '/v1/order/get_quotes', this.orderBody(req));
    const best = cheapestQuote(order?.quotes);
    if (!best) {
      return {
        quoteId: '',
        feeCents: NaN,
        currency: 'usd',
        expiresAt: new Date(this.now()).toISOString(),
        unavailableReason: quoteFailure(order),
      };
    }
    return {
      quoteId: String(best.id),
      feeCents: best.fee,
      currency: String(best.q.currency ?? 'usd').toLowerCase(),
      expiresAt:
        this.plausibleTimestamp(best.q.expireTime, { allowFuture: true }) ??
        new Date(this.now() + 10 * 60_000).toISOString(),
      estimatedDropoffAt: this.plausibleTimestamp(best.q.dropoffEta, { allowFuture: true }),
    };
  }

  async createDelivery(req: CreateDeliveryRequest): Promise<DeliveryState> {
    assertId(req.externalId);

    // A replay after a timeout: the leg may already be a job. Read it back
    // rather than book a second courier.
    const existing = await this.jobByExternalId(req.externalId);
    if (existing) return this.toState(existing);

    const order = await this.call<any>(
      'POST',
      `/v1/order/external-identifier/${encodeURIComponent(req.externalId)}`,
      { ...this.orderBody(req), externalId: req.externalId, referenceId: req.orderReference },
    );

    if (order?.status === 'dispatched') {
      const job = await this.jobByExternalId(req.externalId);
      if (job) return this.toState(job);
      throw new DeliveryProviderError('nash: order is dispatched but its job could not be read', {
        retryable: true,
      });
    }
    if (order?.status === 'needs_attention') {
      throw new DeliveryProviderError(`nash: order needs attention: ${validationText(order)}`, {
        retryable: false,
        providerCode: 'needs_attention',
      });
    }

    let best = cheapestQuote(order?.quotes);
    if (!best && order?.id) {
      // An upsert does not always come back with quotes attached.
      const refreshed = await this.call<any>('POST', '/v1/order/refresh_quotes', { orderId: order.id });
      best = cheapestQuote(refreshed?.quotes);
    }
    if (!best) {
      throw new DeliveryProviderError(`nash: no courier can take this leg: ${quoteFailure(order)}`, {
        retryable: false,
        providerCode: 'no_quotes',
      });
    }

    const selected = await this.call<any>('POST', '/v1/select_quote', { quoteId: best.id });
    return this.toState(selected?.job ?? selected);
  }

  async getDelivery(providerDeliveryId: string): Promise<DeliveryState> {
    assertId(providerDeliveryId);
    return this.toState(await this.call<any>('GET', `/v1/jobs/${encodeURIComponent(providerDeliveryId)}`));
  }

  async cancelDelivery(providerDeliveryId: string): Promise<DeliveryState> {
    assertId(providerDeliveryId);
    const job = await this.call<any>('GET', `/v1/jobs/${encodeURIComponent(providerDeliveryId)}`);
    const ext = typeof job?.externalIdentifier === 'string' ? job.externalIdentifier : undefined;
    let res: any;
    if (ext && ID_RE.test(ext)) {
      res = await this.call<any>('POST', `/v1/jobs/external_identifier/${encodeURIComponent(ext)}/cancel`, {});
    } else {
      const configId = job?.jobConfigurations?.[0]?.id;
      if (typeof configId !== 'string' || !ID_RE.test(configId)) {
        throw new DeliveryProviderError('nash: job has no configuration to cancel', { retryable: false });
      }
      res = await this.call<any>(
        'POST',
        `/v1/jobs/${encodeURIComponent(providerDeliveryId)}/${encodeURIComponent(configId)}/cancel`,
        {},
      );
    }
    // Nash answers a cancel with the job wrapped as { job: {...} } (seen in
    // the sandbox 11/22). If neither shape carries the job, read it again:
    // the copy fetched before the cancel would still say it is live.
    const after = res?.job?.id ? res.job : res?.id ? res : undefined;
    return this.toState(after ?? (await this.call<any>('GET', `/v1/jobs/${encodeURIComponent(providerDeliveryId)}`)));
  }

  async handleWebhook(input: WebhookInput): Promise<WebhookResult> {
    if (!this.verifySvix(input)) return { signatureValid: false };

    let body: any;
    try {
      body = JSON.parse(input.rawBody.toString('utf8'));
    } catch {
      return { signatureValid: true, ignored: 'unparseable body' };
    }
    if (body?.type !== 'delivery') {
      return { signatureValid: true, ignored: `unhandled type: ${body?.type}` };
    }
    const event = String(body.event ?? '').toLowerCase();
    if (!STATUS_MAP[event]) return { signatureValid: true, ignored: `unhandled event: ${event}` };

    const job = body.data;
    const state = this.toState(job);
    const ext = typeof job?.externalIdentifier === 'string' && ID_RE.test(job.externalIdentifier)
      ? job.externalIdentifier
      : undefined;
    return {
      signatureValid: true,
      event: {
        ...state,
        // Svix keeps one message id across all its retries: a perfect dedupe key.
        eventId: header(input.headers, 'svix-id'),
        eventType: `delivery.${event}`,
        externalId: ext,
      },
    };
  }

  /** Svix: HMAC-SHA256 over `${id}.${timestamp}.${body}`, key = base64 after `whsec_`. */
  private verifySvix(input: WebhookInput): boolean {
    const secret = this.opts.webhookSecret;
    if (!secret) return false;
    const id = header(input.headers, 'svix-id');
    const ts = header(input.headers, 'svix-timestamp');
    const sigs = header(input.headers, 'svix-signature');
    if (!id || !ts || !sigs) return false;

    const tsSec = Number(ts);
    if (!Number.isFinite(tsSec) || Math.abs(this.now() / 1000 - tsSec) > WEBHOOK_TOLERANCE_SEC) return false;

    const key = Buffer.from(secret.replace(/^whsec_/, ''), 'base64');
    const expected = createHmac('sha256', key)
      .update(`${id}.${ts}.`)
      .update(input.rawBody)
      .digest();
    // The header lists one or more "v1,<base64>" entries (key rotation).
    return sigs.split(' ').some((entry) => {
      const [version, sig] = entry.split(',');
      if (version !== 'v1' || !sig) return false;
      const got = Buffer.from(sig, 'base64');
      return got.length === expected.length && timingSafeEqual(got, expected);
    });
  }

  private async jobByExternalId(externalId: string): Promise<any | undefined> {
    try {
      return await this.call<any>(
        'GET',
        `/v1/jobs/external_identifier/${encodeURIComponent(externalId)}`,
      );
    } catch (err) {
      if (err instanceof DeliveryProviderError && err.opts.status === 404) return undefined;
      throw err;
    }
  }

  private orderBody(req: QuoteRequest) {
    const ready = Date.parse(req.pickupReadyAt ?? '');
    const deadline = Date.parse(req.pickupDeadlineAt ?? '');
    const scheduled = Number.isFinite(ready) && ready - this.now() >= SCHEDULE_MIN_LEAD_MS;
    const weight = req.manifest.weightLbs;
    return {
      ...waypointFields('pickup', req.pickup),
      ...waypointFields('dropoff', req.dropoff),
      description: req.manifest.description.slice(0, MAX_INSTRUCTIONS),
      itemsCount: req.manifest.itemCount,
      valueCents: Math.max(0, Math.round(req.manifest.declaredValueCents)),
      currency: 'USD',
      // Garment bags and laundry: a car or bigger, never a bike.
      ...(req.manifest.requiresCar ? { minimumVehicleSize: 'car' } : {}),
      ...(weight && weight > 0 ? { weight, weightUnit: 'lbs' } : {}),
      ...(req.dropoff.verification === 'signature'
        ? { requirements: ['signature_proof_of_delivery'] }
        : {}),
      ...(scheduled
        ? {
            deliveryMode: 'scheduled',
            pickupStartTime: nashTime(ready),
            ...(Number.isFinite(deadline) && deadline > ready ? { pickupEndTime: nashTime(deadline) } : {}),
          }
        : { deliveryMode: 'now' }),
    };
  }

  /** Map a Nash job onto our vocabulary, using its newest task. */
  private toState(job: any): DeliveryState {
    const config = job?.jobConfigurations?.[0];
    const tasks: any[] = Array.isArray(config?.tasks) ? config.tasks : [];
    const task = tasks.length
      ? [...tasks].sort((a, b) => String(a?.createdAt ?? '').localeCompare(String(b?.createdAt ?? ''))).at(-1)
      : undefined;
    const d = task?.delivery ?? config?.delivery;

    const raw = typeof d?.status === 'string' ? d.status.toLowerCase() : undefined;
    const taskRaw = typeof task?.status === 'string' ? task.status.toLowerCase() : undefined;
    let status: LegStatus = (raw && STATUS_MAP[raw]) || 'dispatching';
    if (!raw && taskRaw === 'failed') status = 'failed';
    if (!raw && taskRaw?.startsWith('canceled')) status = 'cancelled';

    const before = BEFORE_PICKUP.has(status);
    const phone = before
      ? d?.courierPickupPhoneNumber ?? d?.courierPhoneNumber
      : d?.courierDropoffPhoneNumber ?? d?.courierPhoneNumber;
    const v = d?.courierVehicle;
    const vehicle =
      typeof v === 'string'
        ? v
        : [v?.color, v?.make, v?.model].filter((s) => typeof s === 'string' && s).join(' ') || undefined;
    const history: any[] = Array.isArray(d?.statusHistory) ? d.statusHistory : [];
    const at = (s: string) => history.find((h) => String(h?.status).toLowerCase() === s)?.createdAt;

    return {
      providerDeliveryId: String(job?.id ?? ''),
      status,
      providerStatus: raw ?? taskRaw,
      trackingUrl: safeUrl(config?.publicTrackingUrl),
      feeCents: boundedFee(d?.totalPriceCents ?? sum(d?.priceCents, d?.nashFeeCents)),
      courier:
        d?.courierName || phone || d?.courierLocation
          ? {
              name: typeof d?.courierName === 'string' ? d.courierName : undefined,
              phone: typeof phone === 'string' ? phone : undefined,
              vehicle,
              lat: finite(d?.courierLocation?.lat),
              lng: finite(d?.courierLocation?.lng),
            }
          : undefined,
      pickedUpAt: this.plausibleTimestamp(at('pickup_complete') ?? at('pick_complete')),
      completedAt: this.plausibleTimestamp(at('dropoff_complete') ?? at('returned')),
      error: task?.failureReason ? String(task.failureReason) : undefined,
    };
  }

  private async call<T>(method: string, path: string, body?: unknown): Promise<T> {
    if (!this.isConfigured()) {
      throw new DeliveryProviderError('nash is not configured', { retryable: false });
    }
    let res: Response;
    try {
      res = await this.fetchImpl(`${this.base}${path}`, {
        method,
        headers: {
          authorization: `Bearer ${this.opts.apiKey}`,
          'content-type': 'application/json',
          ...(this.opts.orgId ? { 'nash-org-id': this.opts.orgId } : {}),
        },
        body: body === undefined ? undefined : JSON.stringify(body),
        signal: AbortSignal.timeout(CALL_TIMEOUT_MS),
      });
    } catch (err) {
      const e = err as Error;
      throw new DeliveryProviderError(`nash ${method} ${path} network failure: ${e.message}`, {
        retryable: true,
        providerCode: e.name === 'TimeoutError' ? 'timeout' : 'network',
      });
    }

    let text: string;
    try {
      text = await res.text();
    } catch (err) {
      throw new DeliveryProviderError(`nash ${method} ${path} body read failed: ${(err as Error).message}`, {
        retryable: true,
        providerCode: 'network',
        status: res.status,
      });
    }

    if (!res.ok) {
      let code: string | undefined;
      let message = text;
      try {
        const parsed = JSON.parse(text);
        const first = Array.isArray(parsed) ? parsed[0] : parsed;
        const err = first?.error ?? first;
        code = err?.code;
        message = [err?.message, err?.details ? JSON.stringify(err.details) : undefined]
          .filter(Boolean)
          .join(' ') || text;
      } catch {
        /* keep raw text */
      }
      throw new DeliveryProviderError(`nash ${method} ${path}: ${res.status} ${message}`.slice(0, 600), {
        retryable: res.status >= 500 || res.status === 429,
        status: res.status,
        providerCode: code,
      });
    }

    try {
      return text ? (JSON.parse(text) as T) : ({} as T);
    } catch {
      throw new DeliveryProviderError(`nash ${method} ${path}: unparseable success body`, {
        retryable: false,
        status: res.status,
      });
    }
  }

  /** Nash timestamps are UTC with no zone suffix; read them as UTC. */
  private plausibleTimestamp(v: unknown, o: { allowFuture?: boolean } = {}): string | undefined {
    if (typeof v !== 'string' || !v) return undefined;
    const s = /[zZ]|[+-]\d\d:?\d\d$/.test(v) ? v : `${v}Z`;
    const ms = Date.parse(s);
    if (!Number.isFinite(ms)) return undefined;
    const now = this.now();
    const maxFuture = o.allowFuture ? 31 * 24 * 60 * 60 * 1000 : TIMESTAMP_MAX_FUTURE_MS;
    if (ms < now - TIMESTAMP_MAX_PAST_MS || ms > now + maxFuture) return undefined;
    return new Date(ms).toISOString();
  }
}

const ID_RE = /^[A-Za-z0-9\-._~]{1,128}$/;

function assertId(id: string): void {
  if (!ID_RE.test(id ?? '')) {
    throw new DeliveryProviderError(`nash: invalid id '${id}'`, { retryable: false });
  }
}

/** Contact fields for one end of a leg. Nash wants a first/last name; a shop gets "Manager". */
function waypointFields(side: 'pickup' | 'dropoff', w: Waypoint) {
  const parts = (w.name ?? '').trim().split(/\s+/).filter(Boolean);
  const notes = w.notes?.trim();
  return {
    [`${side}Address`]: w.address,
    [`${side}PhoneNumber`]: e164(w.phone),
    [`${side}BusinessName`]: (w.name ?? '').slice(0, MAX_BUSINESS_NAME) || undefined,
    [`${side}FirstName`]: parts[0] ?? 'Manager',
    [`${side}LastName`]: parts.length > 1 ? parts.slice(1).join(' ') : undefined,
    [`${side}Instructions`]: notes ? notes.slice(0, MAX_INSTRUCTIONS) : undefined,
    ...(Number.isFinite(w.lat) && Number.isFinite(w.lng) ? { [`${side}Lat`]: w.lat, [`${side}Lng`]: w.lng } : {}),
  };
}

/** Cheapest quote a courier actually offered, with what it costs us all-in. */
function cheapestQuote(quotes: unknown): { id: string; fee: number; q: any } | undefined {
  if (!Array.isArray(quotes)) return undefined;
  let best: { id: string; fee: number; q: any } | undefined;
  for (const q of quotes) {
    if (!q || typeof q.id !== 'string' || q.isSuccessful === false || q.errorCode) continue;
    const fee = boundedFee(q.totalPriceCents ?? sum(q.priceCents, q.nashFeeCents));
    if (fee === undefined) continue;
    if (!best || fee < best.fee) best = { id: q.id, fee, q };
  }
  return best;
}

function quoteFailure(order: any): string {
  const failed = Array.isArray(order?.failedQuotes) ? order.failedQuotes : [];
  const reasons = failed
    .map((f: any) => [f?.providerName, f?.errorMessage ?? f?.errorCode].filter(Boolean).join(': '))
    .filter(Boolean)
    .slice(0, 3);
  return reasons.length ? reasons.join('; ') : String(order?.quoteFailure ?? 'no quotes returned');
}

function validationText(order: any): string {
  const v = order?.validationErrors;
  if (!v) return 'unknown';
  return (Array.isArray(v) ? v : [v])
    .map((e: any) => (typeof e === 'string' ? e : e?.message ?? JSON.stringify(e)))
    .join('; ')
    .slice(0, 300);
}

function nashTime(ms: number): string {
  return new Date(ms).toISOString().replace(/\.\d{3}Z$/, 'Z');
}

function header(h: WebhookInput['headers'], key: string): string | undefined {
  const v = h[key] ?? h[key.toLowerCase()];
  return Array.isArray(v) ? v[0] : v;
}

function sum(a: unknown, b: unknown): number | undefined {
  const x = Number(a);
  if (a === undefined || a === null || !Number.isFinite(x)) return undefined;
  const y = Number(b);
  return x + (b !== undefined && b !== null && Number.isFinite(y) ? y : 0);
}

function boundedFee(v: unknown): number | undefined {
  const n = Number(v);
  if (v === undefined || v === null || !Number.isFinite(n) || n < 0 || n > MAX_FEE_CENTS) return undefined;
  return Math.round(n);
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
