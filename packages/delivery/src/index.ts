export * from './types.js';
export { MockProvider } from './mock.js';
export { UberDirectProvider } from './uberDirect.js';

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
  constructor(private readonly providers: DeliveryProvider[]) {}

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

  /**
   * Cheapest usable quote among REAL carriers, with the provider that gave it.
   * The simulator is only ever returned when nothing real answered.
   */
  async bestQuote(
    req: QuoteRequest,
  ): Promise<{ provider: DeliveryProvider; quote: Quote } | undefined> {
    const results = await Promise.allSettled(
      this.active().map(async (provider) => ({ provider, quote: await provider.quote(req) })),
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
    const pool = real.length > 0 ? real : usable;
    return pool.reduce((a, b) => (b.quote.feeCents < a.quote.feeCents ? b : a));
  }
}

export interface BuildChainEnv {
  UBER_CLIENT_ID?: string;
  UBER_CLIENT_SECRET?: string;
  UBER_CUSTOMER_ID?: string;
  UBER_WEBHOOK_SECRET?: string;
  UBER_API_BASE?: string;
  MOCK_WEBHOOK_URL?: string;
  MOCK_WEBHOOK_SECRET?: string;
  MOCK_SPEED_FACTOR?: string;
  MOCK_FAILURE_RATE?: string;
  ENABLE_MOCK_COURIER?: string;
}

/**
 * Uber when credentials exist, plus the mock when explicitly enabled. Today
 * the mock is the only active provider in every environment, which is how the
 * whole two-leg flow runs end to end before Uber approves us — but it is
 * selected because nothing real answered, never because it quoted less.
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

  return new ProviderChain(providers);
}
