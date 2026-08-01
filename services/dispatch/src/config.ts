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

export const config = {
  port: Number(process.env.PORT ?? 8080),
  host: process.env.HOST ?? '0.0.0.0',
  logLevel: process.env.LOG_LEVEL ?? 'info',
  publicUrl: process.env.PUBLIC_URL ?? 'http://localhost:8080',

  supabaseUrl: required('SUPABASE_URL'),
  // Service role bypasses RLS. This process is the only thing that writes
  // delivery_legs and advances order status; clients read, they never drive.
  supabaseServiceKey: required('SUPABASE_SERVICE_ROLE_KEY'),

  // Shared secret for calls from the portal / iOS app into the dispatcher.
  internalApiKey: required('INTERNAL_API_KEY'),

  /** What we declare to the carrier per order, capped. See docs/insurance.md. */
  declaredValueDefaultCents: Number(process.env.DECLARED_VALUE_DEFAULT_CENTS ?? 20_000),
  declaredValueMaxCents: Number(process.env.DECLARED_VALUE_MAX_CENTS ?? 50_000),

  providers: {
    UBER_CLIENT_ID: process.env.UBER_CLIENT_ID,
    UBER_CLIENT_SECRET: process.env.UBER_CLIENT_SECRET,
    UBER_CUSTOMER_ID: process.env.UBER_CUSTOMER_ID,
    UBER_WEBHOOK_SECRET: process.env.UBER_WEBHOOK_SECRET,
    UBER_API_BASE: process.env.UBER_API_BASE,
    ENABLE_MOCK_COURIER: process.env.ENABLE_MOCK_COURIER,
    MOCK_WEBHOOK_URL:
      process.env.MOCK_WEBHOOK_URL ??
      `${process.env.PUBLIC_URL ?? 'http://localhost:8080'}/webhooks/mock`,
    MOCK_WEBHOOK_SECRET: process.env.MOCK_WEBHOOK_SECRET ?? 'dev-mock-secret',
    MOCK_SPEED_FACTOR: process.env.MOCK_SPEED_FACTOR,
    MOCK_FAILURE_RATE: process.env.MOCK_FAILURE_RATE,
  },
};
