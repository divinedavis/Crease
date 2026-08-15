import { config as loadEnv } from 'dotenv';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

// Resolve .env relative to the service, not the cwd — otherwise running from
// the repo root (or from a systemd unit) silently picks up nothing.
loadEnv({ path: join(dirname(dirname(fileURLToPath(import.meta.url))), '.env') });

function required(key: string): string {
  const v = process.env[key];
  if (!v) throw new Error(`missing required env var: ${key}`);
  return v;
}

// The mock courier runs in-process and signs its own callbacks; if it's on,
// its webhook secret must be a real value, never a shipped default.
const mockCourierEnabled = /^(1|true|yes|on)$/i.test(process.env.ENABLE_MOCK_COURIER ?? '');

// A Stripe key with no webhook secret is a box that takes payments and refuses
// every callback Stripe makes about them (the route 503s with nothing to verify
// against). That backstop is the only thing that catches a customer who pays and
// then loses their connection before the app can tell us, so a deploy missing it
// quietly drops orders — and STRIPE_WEBHOOK_SECRET was absent from .env.example,
// one provisioning step away from exactly that.
//
// Fatal in production only. A dev box legitimately runs a test key with no
// webhook tunnel, and refusing to start there would just be in the way.
if (process.env.STRIPE_SECRET_KEY && !process.env.STRIPE_WEBHOOK_SECRET) {
  const message =
    'STRIPE_SECRET_KEY is set but STRIPE_WEBHOOK_SECRET is not — Stripe webhooks will be refused';
  if (process.env.NODE_ENV === 'production') throw new Error(message);
  console.warn(`warning: ${message}`);
}

export const config = {
  port: Number(process.env.PORT ?? 8080),
  // Bind loopback by default; the service holds the service-role key and is
  // meant to sit behind nginx. Set HOST=0.0.0.0 explicitly to expose it.
  host: process.env.HOST ?? '127.0.0.1',
  logLevel: process.env.LOG_LEVEL ?? 'info',
  publicUrl: process.env.PUBLIC_URL ?? 'http://localhost:8080',

  supabaseUrl: required('SUPABASE_URL'),
  // Service role bypasses RLS. This process is the only thing that writes
  // delivery_legs and advances order status; clients read, they never drive.
  supabaseServiceKey: required('SUPABASE_SERVICE_ROLE_KEY'),

  // Used only to introspect a customer's access token. Public by design.
  supabaseAnonKey: required('SUPABASE_ANON_KEY'),

  // Shared secret for calls from the portal / iOS app into the dispatcher.
  internalApiKey: required('INTERNAL_API_KEY'),

  // Safe to hand to a client — it identifies the account and can do nothing
  // on its own. The secret key never leaves this process.
  stripePublishableKey: process.env.STRIPE_PUBLISHABLE_KEY ?? '',

  // Optional, because a mock-payments box has no Stripe to hear from. Absent,
  // the webhook route refuses input rather than acting on an unsigned POST.
  stripeWebhookSecret: process.env.STRIPE_WEBHOOK_SECRET ?? '',

  // All optional, because the APNs auth key is created by hand in the developer
  // portal and does not exist yet. Absent, the sender says so once and no-ops:
  // an order must still reach 'ready' on a box that cannot notify anyone.
  apns: {
    keyId: process.env.APNS_KEY_ID ?? '',
    teamId: process.env.APNS_TEAM_ID ?? '',
    // The .p8 contents, or a path to the file. A PEM's newlines do not survive
    // an env file, so an escaped \n is unescaped where the key is parsed.
    key: process.env.APNS_KEY ?? '',
    keyPath: process.env.APNS_KEY_PATH ?? '',
    // The app's bundle id, which is what APNs routes on.
    bundleId: process.env.APNS_BUNDLE_ID ?? 'com.divinedavis.crease',
  },

  /** What we declare to the carrier per order, capped. See docs/insurance.md. */
  declaredValueDefaultCents: Number(process.env.DECLARED_VALUE_DEFAULT_CENTS ?? 20_000),
  declaredValueMaxCents: Number(process.env.DECLARED_VALUE_MAX_CENTS ?? 50_000),

  payments: {
    STRIPE_SECRET_KEY: process.env.STRIPE_SECRET_KEY,
    ENABLE_MOCK_PAYMENTS: process.env.ENABLE_MOCK_PAYMENTS,
  },

  providers: {
    UBER_CLIENT_ID: process.env.UBER_CLIENT_ID,
    UBER_CLIENT_SECRET: process.env.UBER_CLIENT_SECRET,
    UBER_CUSTOMER_ID: process.env.UBER_CUSTOMER_ID,
    UBER_WEBHOOK_SECRET: process.env.UBER_WEBHOOK_SECRET,
    UBER_API_BASE: process.env.UBER_API_BASE,
    ENABLE_MOCK_COURIER: process.env.ENABLE_MOCK_COURIER,
    // The mock courier runs in this process, so its callbacks should loop
    // straight back to this process. Deriving it from PUBLIC_URL sent them
    // out to the public hostname and back, which silently swallowed every
    // simulated event before DNS existed.
    MOCK_WEBHOOK_URL:
      process.env.MOCK_WEBHOOK_URL ??
      `http://127.0.0.1:${process.env.PORT ?? 8080}/webhooks/mock`,
    // No insecure default: if the mock courier is enabled its secret is
    // required, so an unsigned/default-signed mock event can never be forged.
    MOCK_WEBHOOK_SECRET: mockCourierEnabled
      ? required('MOCK_WEBHOOK_SECRET')
      : (process.env.MOCK_WEBHOOK_SECRET ?? ''),
    MOCK_SPEED_FACTOR: process.env.MOCK_SPEED_FACTOR,
    MOCK_FAILURE_RATE: process.env.MOCK_FAILURE_RATE,
  },
};
