/**
 * Carrier-agnostic delivery contract.
 *
 * Every courier network we can plug in (Uber Direct, DoorDash Drive, Roadie,
 * Nash) exposes roughly the same four verbs. Keeping the dispatcher behind
 * this interface means switching carriers — or falling back when one has no
 * coverage — is a config change, not a rewrite.
 */

export type LegStatus =
  | 'pending'
  | 'dispatching'
  | 'courier_assigned'
  | 'en_route_to_pickup'
  | 'at_pickup'
  | 'picked_up'
  | 'en_route_to_dropoff'
  | 'at_dropoff'
  | 'delivered'
  | 'returned'
  | 'cancelled'
  | 'failed';

/** Terminal states. The dispatcher stops polling/retrying at these. */
export const TERMINAL_STATUSES: readonly LegStatus[] = [
  'delivered',
  'returned',
  'cancelled',
  'failed',
];

export type VerificationMode = 'none' | 'signature' | 'pincode' | 'picture' | 'barcode';

export interface Waypoint {
  name: string;
  phone?: string;
  /** Single-line, courier-readable. Providers geocode this themselves. */
  address: string;
  lat?: number;
  lng?: number;
  /** "Buzzer 4B, leave with doorman" — passed through to the courier app. */
  notes?: string;
  verification?: VerificationMode;
}

export interface Manifest {
  /** Human description shown to the courier. */
  description: string;
  /**
   * Declared value in cents. Carriers cap their liability well below the
   * replacement cost of a garment bag — this is what they will actually
   * cover, not what the load is worth. Insure the gap separately.
   */
  declaredValueCents: number;
  itemCount: number;
  /** Whole pounds. Carriers reject above ~50 lb per package. */
  weightLbs?: number;
  /**
   * Hanging garments need a car, not a bike courier. Not every market
   * honors this, so treat it as a preference and verify during pilot.
   */
  requiresCar?: boolean;
}

export interface QuoteRequest {
  pickup: Waypoint;
  dropoff: Waypoint;
  manifest: Manifest;
  /** ISO-8601. Omit for on-demand dispatch. */
  pickupReadyAt?: string;
  pickupDeadlineAt?: string;
  dropoffReadyAt?: string;
  dropoffDeadlineAt?: string;
}

export interface Quote {
  quoteId: string;
  feeCents: number;
  currency: string;
  /** Quotes expire; the dispatcher must create the delivery before this. */
  expiresAt: string;
  estimatedPickupAt?: string;
  estimatedDropoffAt?: string;
  /** Provider said it cannot serve this route at all. */
  unavailableReason?: string;
}

export interface CreateDeliveryRequest extends QuoteRequest {
  /** Our leg id. Sent as the provider's external/idempotency key. */
  externalId: string;
  quoteId?: string;
  /** Shown to the customer in tracking; some carriers surface it. */
  orderReference?: string;
}

export interface DeliveryState {
  providerDeliveryId: string;
  status: LegStatus;
  /** Raw provider status string, kept for debugging mapping drift. */
  providerStatus?: string;
  trackingUrl?: string;
  feeCents?: number;
  courier?: {
    name?: string;
    phone?: string;
    vehicle?: string;
    lat?: number;
    lng?: number;
  };
  /** Set when the provider issued a dropoff PIN we must show the customer. */
  dropoffPincode?: string;
  pickedUpAt?: string;
  completedAt?: string;
  error?: string;
}

export interface NormalizedEvent extends DeliveryState {
  /** For webhook dedupe. */
  eventId?: string;
  eventType?: string;
  externalId?: string;
}

export interface WebhookInput {
  headers: Record<string, string | string[] | undefined>;
  /** Raw body bytes. Signature verification must run on these, not on
   *  a re-serialized object — key order changes break HMACs. */
  rawBody: Buffer;
}

export interface WebhookResult {
  signatureValid: boolean;
  event?: NormalizedEvent;
  /** Set when the payload parsed but isn't a status change we care about. */
  ignored?: string;
}

export class DeliveryProviderError extends Error {
  constructor(
    message: string,
    readonly opts: {
      /** Worth retrying with backoff (5xx, timeout, rate limit). */
      retryable: boolean;
      status?: number;
      providerCode?: string;
    },
  ) {
    super(message);
    this.name = 'DeliveryProviderError';
  }
}

export interface DeliveryProvider {
  readonly name: string;
  /**
   * True when no real courier is ever dispatched — the provider only pretends.
   *
   * Selection has to be able to tell a simulator apart from a carrier without
   * matching on `name`, because a name is a label anyone can change and the
   * consequence of getting it wrong is a live order handed to something that
   * will never pick up the clothes. Real providers leave this false/unset;
   * a simulator must set it true.
   */
  readonly simulated?: boolean;
  /** True when credentials are present and the provider can be dispatched to. */
  isConfigured(): boolean;
  quote(req: QuoteRequest): Promise<Quote>;
  createDelivery(req: CreateDeliveryRequest): Promise<DeliveryState>;
  getDelivery(providerDeliveryId: string): Promise<DeliveryState>;
  cancelDelivery(providerDeliveryId: string): Promise<DeliveryState>;
  /** Verify signature and map the payload onto our vocabulary. */
  handleWebhook(input: WebhookInput): Promise<WebhookResult>;
}
