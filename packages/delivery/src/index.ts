export * from './types.js';
export { MockProvider } from './mock.js';
export { UberDirectProvider } from './uberDirect.js';
export { DoorDashDriveProvider } from './doordashDrive.js';

import { DoorDashDriveProvider } from './doordashDrive.js';
import { MockProvider } from './mock.js';
import { UberDirectProvider } from './uberDirect.js';
import type { DeliveryProvider, Quote, QuoteRequest } from './types.js';

/**
 * Provider chain.
 *
 * Dispatch quotes every configured provider in parallel and takes the cheapest
 * usable answer — except that a simulated provider can only ever be a last
 * resort (see bestQuote). Courier networks have real coverage holes — a
 * cleaner three blocks outside Uber's radius is a normal Tuesday — so the
 * fallback is not a nicety, it is how orders get served at the edges.
 */
export class ProviderChain {
  /**
   * @param quoteFrom Real carriers allowed to win NEW legs. Unset means every
   *   configured one. A carrier left out still answers `get()`, so legs it is
   *   already carrying keep receiving webhooks and can still be cancelled —
   *   which is the difference between this and deleting its credentials.
   */
  constructor(
    private readonly providers: DeliveryProvider[],
    private readonly quoteFrom?: readonly string[],
  ) {}

  /** Only providers whose credentials are actually present. */
  active(): DeliveryProvider[] {
    return this.providers.filter((p) => p.isConfigured());
  }

  get(name: string): DeliveryProvider | undefined {
    // The Uber dashboard endpoint is registered as /webhooks/uber, but the
    // provider names itself uber_direct (and that name is what lands in
    // delivery_events rows). Resolve the public slug here rather than
    // renaming the provider under existing data.
    const target = ProviderChain.WEBHOOK_ALIASES[name] ?? name;
    return this.providers.find((p) => p.name === target);
  }

  private static readonly WEBHOOK_ALIASES: Record<string, string> = { uber: 'uber_direct' };

  /** Configured providers that may quote a new leg (simulators always may). */
  quotable(): DeliveryProvider[] {
    const allow = this.quoteFrom;
    return this.active().filter((p) => p.simulated || !allow || allow.includes(p.name));
  }

  /**
   * Cheapest usable quote among REAL carriers, with the provider that gave it.
   * The simulator is only ever returned when nothing real answered.
   *
   * `simulatedOnly` inverts that for orders that must never reach a road: App
   * Review's account, and demo walkthroughs. It is a filter on the pool rather
   * than a separate code path so those orders still travel every line below —
   * the same quoting, the same claim, the same status mapping — because a
   * review session that exercises a bypass has not exercised the product.
   */
  async bestQuote(
    req: QuoteRequest,
    opts: { simulatedOnly?: boolean } = {},
  ): Promise<{ provider: DeliveryProvider; quote: Quote } | undefined> {
    const pool = opts.simulatedOnly
      ? this.quotable().filter((p) => p.simulated)
      : this.quotable();
    const results = await Promise.allSettled(
      pool.map(async (provider) => ({ provider, quote: await provider.quote(req) })),
    );

    const usable = results
      .filter(
        (r): r is PromiseFulfilledResult<{ provider: DeliveryProvider; quote: Quote }> =>
          r.status === 'fulfilled' && !r.value.quote.unavailableReason,
      )
      .map((r) => r.value);

    if (usable.length === 0) return undefined;

    // A simulator must never win on price. The mock quotes ~$6-12 by design,
    // which undercuts any real courier network, so a pure cheapest-wins rule
    // means the day Uber credentials land every order silently routes to a
    // simulated driver — real order rows advancing, real Stripe payouts, no
    // one ever collecting the clothes.
    //
    // Disabling the mock is not the fix either: production runs it with no
    // Uber credentials, so an empty chain fails every booking into
    // charge-then-refund. So real carriers compete on price among themselves
    // and the mock is selected only when it is the last thing standing.
    const real = usable.filter((u) => !u.provider.simulated);
    const contenders = real.length > 0 ? real : usable;
    return contenders.reduce((a, b) => (b.quote.feeCents < a.quote.feeCents ? b : a));
  }
}

export interface BuildChainEnv {
  UBER_CLIENT_ID?: string;
  UBER_CLIENT_SECRET?: string;
  UBER_CUSTOMER_ID?: string;
  UBER_WEBHOOK_SECRET?: string;
  UBER_API_BASE?: string;
  DOORDASH_DEVELOPER_ID?: string;
  DOORDASH_KEY_ID?: string;
  DOORDASH_SIGNING_SECRET?: string;
  DOORDASH_WEBHOOK_SECRET?: string;
  DOORDASH_API_BASE?: string;
  /** Comma list of real carriers that may take new legs, e.g. "doordash". */
  COURIER_PROVIDERS?: string;
  MOCK_WEBHOOK_URL?: string;
  MOCK_WEBHOOK_SECRET?: string;
  MOCK_SPEED_FACTOR?: string;
  MOCK_FAILURE_RATE?: string;
  ENABLE_MOCK_COURIER?: string;
}

/**
 * Uber Direct and DoorDash Drive when their credentials exist, plus the mock
 * when explicitly enabled. Real carriers compete on price; COURIER_PROVIDERS
 * narrows which of them may take new legs (e.g. "doordash" to stop sending new
 * work to Uber while its in-flight legs finish). The mock is selected only
 * because nothing real answered, never because it quoted less.
 */
export function buildChain(env: BuildChainEnv): ProviderChain {
  const providers: DeliveryProvider[] = [
    new UberDirectProvider({
      clientId: env.UBER_CLIENT_ID,
      clientSecret: env.UBER_CLIENT_SECRET,
      customerId: env.UBER_CUSTOMER_ID,
      webhookSecret: env.UBER_WEBHOOK_SECRET,
      apiBase: env.UBER_API_BASE,
    }),
    new DoorDashDriveProvider({
      developerId: env.DOORDASH_DEVELOPER_ID,
      keyId: env.DOORDASH_KEY_ID,
      signingSecret: env.DOORDASH_SIGNING_SECRET,
      webhookSecret: env.DOORDASH_WEBHOOK_SECRET,
      apiBase: env.DOORDASH_API_BASE,
    }),
  ];

  // Explicit opt-in only. A missing/typo'd flag must NOT silently activate the
  // mock — that shipped a simulated courier (with a forgeable, empty-secret
  // webhook) into production and, being the cheapest quote, let it win over
  // real Uber. And no insecure default secret: if the mock is on, its webhook
  // secret is required so its events can't be forged.
  const enableMock = /^(1|true|yes|on)$/i.test(env.ENABLE_MOCK_COURIER ?? '');
  if (enableMock) {
    if (!env.MOCK_WEBHOOK_SECRET) {
      throw new Error('ENABLE_MOCK_COURIER is on but MOCK_WEBHOOK_SECRET is not set');
    }
    providers.push(
      new MockProvider({
        webhookUrl: env.MOCK_WEBHOOK_URL,
        webhookSecret: env.MOCK_WEBHOOK_SECRET,
        speedFactor: Number(env.MOCK_SPEED_FACTOR ?? 10),
        failureRate: Number(env.MOCK_FAILURE_RATE ?? 0),
      }),
    );
  }

  return new ProviderChain(providers, parseQuoteFrom(env.COURIER_PROVIDERS, providers));
}

/**
 * COURIER_PROVIDERS, checked. A typo here would quietly leave no real carrier
 * able to quote, and every order would fall to the simulator or fail after
 * the charge. Refuse to start instead.
 */
function parseQuoteFrom(raw: string | undefined, providers: DeliveryProvider[]): string[] | undefined {
  const names = (raw ?? '')
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean);
  if (names.length === 0) return undefined;
  const known = providers.filter((p) => !p.simulated).map((p) => p.name);
  const unknown = names.filter((n) => !known.includes(n));
  if (unknown.length > 0) {
    throw new Error(
      `COURIER_PROVIDERS names unknown carrier(s): ${unknown.join(', ')} (known: ${known.join(', ')})`,
    );
  }
  return names;
}
