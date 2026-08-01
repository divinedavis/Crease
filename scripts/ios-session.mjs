#!/usr/bin/env node
/**
 * Mint a real Supabase session for the seeded test customer and print it as
 * shell exports, for injection into the iOS UI tests.
 *
 * A genuine session (not a stub) means the UI tests exercise the real query
 * path under RLS — which is the part worth testing.
 *
 *   eval "$(node scripts/ios-session.mjs)"
 */
import { readEnv } from './lib/client.mjs';

const svc = readEnv('services/dispatch/.env');
const anon = readEnv('apps/ios/Secrets.xcconfig');

const res = await fetch(`${svc.SUPABASE_URL}/auth/v1/token?grant_type=password`, {
  method: 'POST',
  headers: { apikey: anon.SUPABASE_ANON_KEY, 'content-type': 'application/json' },
  body: JSON.stringify({
    email: 'testcustomer@crease.local',
    password: 'crease-dev-password',
  }),
});

if (!res.ok) {
  console.error(`# sign-in failed: ${res.status} ${await res.text()}`);
  process.exit(1);
}
const json = await res.json();
console.log(`export UITEST_ACCESS_TOKEN='${json.access_token}'`);
console.log(`export UITEST_REFRESH_TOKEN='${json.refresh_token}'`);
