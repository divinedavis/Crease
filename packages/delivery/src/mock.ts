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
 * Simulated courier network.
 *
 * Deliberately not a stub that resolves instantly: it walks a delivery through
 * the real status sequence on a timer and POSTs signed webhooks back at our
 * own endpoint. That means the dispatcher's webhook path, signature check,
 * dedupe, and state machine are all exercised for real before Uber Direct
 * credentials ever exist — and the swap to Uber changes one env var.
 */

const SEQUENCE: { status: LegStatus; afterMs: number }[] = [
  { status: 'dispatching', afterMs: 0 },
  { status: 'courier_assigned', afterMs: 4_000 },
  { status: 'en_route_to_pickup', afterMs: 8_000 },
  { status: 'at_pickup', afterMs: 16_000 },
  { status: 'picked_up', afterMs: 20_000 },
  { status: 'en_route_to_dropoff', afterMs: 24_000 },
  { status: 'at_dropoff', afterMs: 34_000 },
  { status: 'delivered', afterMs: 38_000 },
];

/** Simulated webhooks go to our own dispatcher; anything slower than this is
 *  a wedged endpoint, not a slow one. */
const WEBHOOK_TIMEOUT_MS = 10_000;

const COURIERS = [
  { name: 'Marcus T.', vehicle: 'Toyota Camry', phone: '+15550100' },
  { name: 'Aisha R.', vehicle: 'Honda CR-V', phone: '+15550101' },
  { name: 'Dmitri K.', vehicle: 'Ford Transit', phone: '+15550102' },
];

export interface MockProviderOptions {
  /** Where to POST simulated webhooks. Omit to run in poll-only mode. */
  webhookUrl?: string;
  webhookSecret: string;
  /** Compress the whole sequence. 10 => a 38s delivery finishes in ~3.8s. */
  speedFactor?: number;
  /** Fraction of deliveries that end in 'returned' instead of 'delivered'.
   *  Exercises the failure path, which is where real money is lost. */
  failureRate?: number;
  fetchImpl?: typeof fetch;
}

interface MockRecord extends DeliveryState {
  externalId: string;
  timers: NodeJS.Timeout[];
  cancelled: boolean;
}

export class MockProvider implements DeliveryProvider {
  readonly name = 'mock';
  /** No courier exists behind this. Selection uses it to keep the simulator
   *  from ever outbidding a real carrier — see ProviderChain.bestQuote. */
  readonly simulated = true;
  private readonly store = new Map<string, MockRecord>();
  private readonly speed: number;
  private readonly failureRate: number;
  private readonly fetchImpl: typeof fetch;
  private seq = 0;

  constructor(private readonly opts: MockProviderOptions) {
    this.speed = opts.speedFactor ?? 1;
    this.failureRate = opts.failureRate ?? 0;
    this.fetchImpl = opts.fetchImpl ?? fetch;
  }

  isConfigured(): boolean {
    return true;
  }

  async quote(req: QuoteRequest): Promise<Quote> {
    // Rough shape of real courier pricing: a base plus distance, so the
    // portal's numbers are not obviously fake during a demo.
    const miles = haversineMiles(req.pickup, req.dropoff) ?? 2.5;
    const feeCents = Math.round(599 + miles * 120);
    return {
      quoteId: `mockq_${randomUUID()}`,
      feeCents,
      currency: 'usd',
      expiresAt: new Date(Date.now() + 5 * 60_000).toISOString(),
      estimatedDropoffAt: new Date(Date.now() + 45 * 60_000).toISOString(),
    };
  }

  async createDelivery(req: CreateDeliveryRequest): Promise<DeliveryState> {
    const id = `mockd_${randomUUID()}`;
    const courier = COURIERS[this.seq++ % COURIERS.length];
    const willFail = Math.random() < this.failureRate;

    const record: MockRecord = {
      externalId: req.externalId,
      providerDeliveryId: id,
      status: 'dispatching',
      providerStatus: 'pending',
      trackingUrl: `https://track.crease.local/${id}`,
      feeCents: (await this.quote(req)).feeCents,
      courier: { ...courier, lat: req.pickup.lat, lng: req.pickup.lng },
      dropoffPincode:
        req.dropoff.verification === 'pincode'
          ? String(Math.floor(1000 + Math.random() * 9000))
          : undefined,
      timers: [],
      cancelled: false,
    };
    this.store.set(id, record);

    for (const step of SEQUENCE) {
      // On a simulated failure, divert at the dropoff instead of completing.
      const status: LegStatus =
        willFail && step.status === 'delivered' ? 'returned' : step.status;
      const timer = setTimeout(() => {
        const cur = this.store.get(id);
        if (!cur || cur.cancelled) return;
        cur.status = status;
        cur.providerStatus = status;
        if (status === 'picked_up') cur.pickedUpAt = new Date().toISOString();
        if (status === 'delivered' || status === 'returned') {
          cur.completedAt = new Date().toISOString();
          if (status === 'returned') cur.error = 'customer_unavailable';
        }
        // Drift the courier pin toward the dropoff so the map moves.
        if (cur.courier && req.dropoff.lat != null && req.dropoff.lng != null) {
          const t = SEQUENCE.findIndex((s) => s.status === step.status) / (SEQUENCE.length - 1);
          cur.courier.lat = lerp(req.pickup.lat, req.dropoff.lat, t);
          cur.courier.lng = lerp(req.pickup.lng, req.dropoff.lng, t);
        }
        void this.emit(cur);
      }, step.afterMs / this.speed);
      // Do not hold the process open on simulated deliveries.
      timer.unref?.();
      record.timers.push(timer);
    }

    return stripInternals(record);
  }

  async getDelivery(providerDeliveryId: string): Promise<DeliveryState> {
    const rec = this.store.get(providerDeliveryId);
    if (!rec) {
      throw new DeliveryProviderError('unknown mock delivery', {
        retryable: false,
        status: 404,
      });
    }
    return stripInternals(rec);
  }

  async cancelDelivery(providerDeliveryId: string): Promise<DeliveryState> {
    const rec = this.store.get(providerDeliveryId);
    if (!rec) {
      // This store is process-local, so a deploy erases every in-flight
      // simulated delivery. Throwing 404 here made cancellation permanently
      // impossible for those legs — the caller could never close them out.
      // A delivery the provider has no record of cannot be en route, so
      // cancelling it is a no-op that already succeeded. Report the outcome
      // the caller asked for rather than an error it cannot act on.
      return {
        providerDeliveryId,
        status: 'cancelled',
        providerStatus: 'unknown_to_provider',
        completedAt: new Date().toISOString(),
      };
    }
    if (rec.status === 'picked_up' || rec.status === 'en_route_to_dropoff') {
      // Matches real carriers: once the goods are aboard you cannot cancel,
      // you can only ask for a return. Worth exercising in tests.
      throw new DeliveryProviderError('cannot cancel after pickup', {
        retryable: false,
        status: 409,
        providerCode: 'cancel_after_pickup',
      });
    }
    rec.cancelled = true;
    rec.status = 'cancelled';
    rec.completedAt = new Date().toISOString();
    rec.timers.forEach(clearTimeout);
    await this.emit(rec);
    return stripInternals(rec);
  }

  async handleWebhook(input: WebhookInput): Promise<WebhookResult> {
    const sig = header(input.headers, 'x-crease-signature');
    const expected = createHmac('sha256', this.opts.webhookSecret)
      .update(input.rawBody)
      .digest('hex');
    const valid =
      !!sig &&
      sig.length === expected.length &&
      timingSafeEqual(Buffer.from(sig), Buffer.from(expected));
    if (!valid) return { signatureValid: false };

    const body = JSON.parse(input.rawBody.toString('utf8'));
    return {
      signatureValid: true,
      event: {
        eventId: body.event_id,
        eventType: body.event_type,
        externalId: body.external_id,
        providerDeliveryId: body.delivery_id,
        status: body.status,
        providerStatus: body.status,
        trackingUrl: body.tracking_url,
        feeCents: body.fee_cents,
        courier: body.courier,
        dropoffPincode: body.dropoff_pincode,
        pickedUpAt: body.picked_up_at,
        completedAt: body.completed_at,
        error: body.error,
      },
    };
  }

  /** Fire-and-forget signed webhook, mirroring a real provider callback. */
  private async emit(rec: MockRecord): Promise<void> {
    if (!this.opts.webhookUrl) return;
    const body = JSON.stringify({
      event_id: randomUUID(),
      event_type: 'delivery.status_changed',
      external_id: rec.externalId,
      delivery_id: rec.providerDeliveryId,
      status: rec.status,
      tracking_url: rec.trackingUrl,
      fee_cents: rec.feeCents,
      courier: rec.courier,
      dropoff_pincode: rec.dropoffPincode,
      picked_up_at: rec.pickedUpAt,
      completed_at: rec.completedAt,
      error: rec.error,
    });
    const signature = createHmac('sha256', this.opts.webhookSecret).update(body).digest('hex');
    try {
      await this.fetchImpl(this.opts.webhookUrl, {
        method: 'POST',
        headers: { 'content-type': 'application/json', 'x-crease-signature': signature },
        body,
        // Bounded so a hung webhook endpoint cannot pin a timer callback open
        // for the OS default (~2 min) while the simulation marches on.
        signal: AbortSignal.timeout(WEBHOOK_TIMEOUT_MS),
      });
    } catch {
      // A dropped simulated webhook is fine — the reconciler will poll.
    }
  }
}

function stripInternals(rec: MockRecord): DeliveryState {
  const { timers, cancelled, externalId, ...state } = rec;
  return state;
}

function lerp(a: number | undefined, b: number, t: number): number {
  return a == null ? b : a + (b - a) * t;
}

function header(h: WebhookInput['headers'], key: string): string | undefined {
  const v = h[key] ?? h[key.toLowerCase()];
  return Array.isArray(v) ? v[0] : v;
}

function haversineMiles(
  a: { lat?: number; lng?: number },
  b: { lat?: number; lng?: number },
): number | undefined {
  if (a.lat == null || a.lng == null || b.lat == null || b.lng == null) return undefined;
  const R = 3958.8;
  const dLat = ((b.lat - a.lat) * Math.PI) / 180;
  const dLng = ((b.lng - a.lng) * Math.PI) / 180;
  const s =
    Math.sin(dLat / 2) ** 2 +
    Math.cos((a.lat * Math.PI) / 180) *
      Math.cos((b.lat * Math.PI) / 180) *
      Math.sin(dLng / 2) ** 2;
  return R * 2 * Math.asin(Math.sqrt(s));
}
