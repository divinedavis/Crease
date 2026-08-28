import { strict as assert } from 'node:assert';
import { test } from 'node:test';
import { ProviderChain } from './index.js';
import type { DeliveryProvider, Quote, QuoteRequest } from './types.js';

/** A provider that only answers quotes; nothing here dispatches anything. */
function stub(name: string, feeCents: number, simulated: boolean): DeliveryProvider {
  return {
    name,
    simulated,
    isConfigured: () => true,
    quote: async (): Promise<Quote> => ({
      feeCents,
      currency: 'usd',
      quoteId: `q_${name}`,
      expiresAt: new Date(Date.now() + 600_000).toISOString(),
    }),
  } as unknown as DeliveryProvider;
}

const REQ = {} as QuoteRequest;

test('a real carrier wins even when the simulator is cheaper', () => {
  // The simulator quotes low by design, so a plain cheapest-wins rule would
  // route every order to a driver who does not exist.
  const chain = new ProviderChain([stub('mock', 600, true), stub('uber_direct', 1_299, false)]);
  return chain.bestQuote(REQ).then((best) => {
    assert.equal(best?.provider.name, 'uber_direct');
  });
});

test('the simulator is taken when nothing real answered', async () => {
  const chain = new ProviderChain([stub('mock', 600, true)]);
  const best = await chain.bestQuote(REQ);
  assert.equal(best?.provider.name, 'mock');
});

test('simulatedOnly refuses the real carrier however cheap it is', async () => {
  // This is what stands between an App Store reviewer tapping Book and an
  // actual driver arriving at an actual Brooklyn address for a bag that does
  // not exist. Priced so that every other rule in bestQuote would pick Uber.
  const chain = new ProviderChain([stub('mock', 9_999, true), stub('uber_direct', 1, false)]);
  const best = await chain.bestQuote(REQ, { simulatedOnly: true });
  assert.equal(best?.provider.name, 'mock');
});

test('simulatedOnly with no simulator configured returns nothing', async () => {
  // Rather than falling back to a real carrier. The caller turns this into a
  // failed leg naming the deployment mistake — a box dispatching review orders
  // with ENABLE_MOCK_COURIER off — which is the honest report; silently
  // dispatching for real is not.
  const chain = new ProviderChain([stub('uber_direct', 1_299, false)]);
  assert.equal(await chain.bestQuote(REQ, { simulatedOnly: true }), undefined);
});
