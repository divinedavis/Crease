export * from './types.js';
export { MockProvider } from './mock.js';
export { DoorDashDriveProvider, e164 } from './doordashDrive.js';
export { NashProvider } from './nash.js';

import { MockProvider } from './mock.js';
import { DoorDashDriveProvider } from './doordashDrive.js';
import { NashProvider } from './nash.js';
import type { DeliveryProvider, Quote, QuoteRequest } from './types.js';

/**
 * Provider chain.
 *
 * Dispatch quotes every configured provider in parallel and takes the cheapest
 * usable answer — except that a simulated provider can only ever be a last
 * resort (see bestQuote). Courier networks have real coverage holes — a
 * cleaner three blocks outside a carrier's radius is a normal Tuesday — so the
 * fallback is not a nicety, it is how orders get served at the edges.
 */
export class ProviderChain {
  constructor(private readonly providers: DeliveryProvider[]) {}

  /** Only providers whose credentials are actually present. */
  active(): DeliveryProvider[] {
    return this.providers.filter((p) => p.isConfigured());
  }

  get(name: string): DeliveryProvider | undefined {
    return this.providers.find((p) => p.name === name);
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
      ? this.active().filter((p) => p.simulated)
      : this.active();
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
    // means the day real credentials land every order silently routes to a
    // simulated driver — real order rows advancing, real Stripe payouts, no
    // one ever collecting the clothes.
    //
    // Disabling the mock is not the fix either: production runs it with no
    // carrier credentials, so an empty chain fails every booking into
    // charge-then-refund. So real carriers compete on price among themselves
    // and the mock is selected only when it is the last thing standing.
    const real = usable.filter((u) => !u.provider.simulated);
    const contenders = real.length > 0 ? real : usable;
    return contenders.reduce((a, b) => (b.quote.feeCents < a.quote.feeCents ? b : a));
  }
}

export interface BuildChainEnv {
  DOORDASH_DEVELOPER_ID?: string;
  DOORDASH_KEY_ID?: string;
  DOORDASH_SIGNING_SECRET?: string;
  DOORDASH_WEBHOOK_AUTH?: string;
  DOORDASH_API_BASE?: string;
  NASH_API_KEY?: string;
  NASH_ORG_ID?: string;
  NASH_WEBHOOK_SECRET?: string;
  NASH_API_BASE?: string;
  MOCK_WEBHOOK_URL?: string;
  MOCK_WEBHOOK_SECRET?: string;
  MOCK_SPEED_FACTOR?: string;
  MOCK_FAILURE_RATE?: string;
  ENABLE_MOCK_COURIER?: string;
}

/**
 * DoorDash Drive and Nash when their credentials exist, plus the mock when
 * explicitly enabled. Today
 * the mock is the only active provider in every environment, which is how the
 * whole two-leg flow runs end to end before DoorDash credentials land — but it is
 * selected because nothing real answered, never because it quoted less.
 */
export function buildChain(env: BuildChainEnv): ProviderChain {
  const providers: DeliveryProvider[] = [
    new DoorDashDriveProvider({
      developerId: env.DOORDASH_DEVELOPER_ID,
      keyId: env.DOORDASH_KEY_ID,
      signingSecret: env.DOORDASH_SIGNING_SECRET,
      webhookAuth: env.DOORDASH_WEBHOOK_AUTH,
      apiBase: env.DOORDASH_API_BASE,
    }),
    // One account in front of many courier networks; competes on price with
    // DoorDash when both are configured.
    new NashProvider({
      apiKey: env.NASH_API_KEY,
      orgId: env.NASH_ORG_ID,
      webhookSecret: env.NASH_WEBHOOK_SECRET,
      apiBase: env.NASH_API_BASE,
    }),
  ];

  // Explicit opt-in only. A missing/typo'd flag must NOT silently activate the
  // mock — that shipped a simulated courier (with a forgeable, empty-secret
  // webhook) into production and, being the cheapest quote, let it win over
  // a real carrier. And no insecure default secret: if the mock is on, its webhook
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
