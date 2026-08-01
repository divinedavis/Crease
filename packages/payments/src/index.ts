export * from './types.js';
export { MockPaymentProvider } from './mock.js';
export { StripeProvider } from './stripe.js';
export * from './connect.js';

import { MockPaymentProvider } from './mock.js';
import { StripeProvider } from './stripe.js';
import type { PaymentProvider } from './types.js';

/**
 * Stripe when it has a key, the mock otherwise. Unlike couriers there is no
 * fallback chain — you do not want a second payment processor silently
 * picking up an order the first one declined.
 */
export function buildPaymentProvider(env: {
  STRIPE_SECRET_KEY?: string;
  ENABLE_MOCK_PAYMENTS?: string;
}): PaymentProvider {
  const stripe = new StripeProvider({ secretKey: env.STRIPE_SECRET_KEY });
  if (stripe.isConfigured() && env.ENABLE_MOCK_PAYMENTS !== 'true') return stripe;
  return new MockPaymentProvider();
}
