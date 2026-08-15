// Purge delivery_events older than N days. Raw courier payloads hold customer
// addresses, courier phones, and dropoff PINs, so they should not accumulate
// forever. Run weekly from cron; reads the dispatch service's own .env.
import { readFileSync } from 'node:fs';
import { createClient } from '@supabase/supabase-js';
// supabase-js builds a RealtimeClient eagerly and Node 20 has no global
// WebSocket, so it throws at construction without an explicit transport —
// same reason the dispatch service passes `ws` in index.ts.
import WebSocketTransport from 'ws';

// Path is overridable so a relocation of the deploy root (this moved from
// /root/crease to /opt/crease once already) doesn't silently break the purge.
const envPath = process.env.DISPATCH_ENV_PATH ?? '/opt/crease/services/dispatch/.env';
const env = Object.fromEntries(
  readFileSync(envPath, 'utf8')
    .split('\n')
    .filter((l) => l.includes('=') && !l.trimStart().startsWith('#'))
    .map((l) => [l.slice(0, l.indexOf('=')).trim(), l.slice(l.indexOf('=') + 1).trim()]),
);

const db = createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false },
  realtime: { transport: WebSocketTransport },
});

const days = Number(process.argv[2] ?? 90);

// Three jobs, one schedule: raw webhook payloads, the PII denormalised onto
// finished legs (customer address/phone, courier phone and GPS, the handoff
// PIN), and the notification log. A failure in one shouldn't skip the others.
const jobs = [
  ['purge_delivery_events', 'delivery_events purged'],
  ['scrub_finished_leg_pii', 'finished legs scrubbed'],
  ['purge_notifications_sent', 'notifications purged'],
  // Abandoned drafts are nobody's record — no payment, no shop ever saw the
  // bag — and they used to accumulate until a customer hit the draft cap and
  // could not order at all. Kept on a longer clock than the event tables.
  ['purge_abandoned_drafts', 'abandoned drafts purged', 30],
  ['scrub_old_order_notes', 'old order notes scrubbed', 365],
];

let failed = false;
for (const [fn, label, overrideDays] of jobs) {
  const { data, error } = await db.rpc(fn, { p_days: overrideDays ?? days });
  const stamp = new Date().toISOString();
  if (error) {
    console.error(`${stamp} ${fn} failed: ${error.message}`);
    failed = true;
  } else {
    console.log(`${stamp} ${label}: ${data} (older than ${days}d)`);
  }
}
process.exit(failed ? 1 : 0);
