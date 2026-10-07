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

// Number('') is 0, so a cron line whose $RETENTION_DAYS was never set expands
// to an empty argument and asks for "older than 0 days" — every event, every
// note, every finished leg's PII, scrubbed, and reported as a normal success
// line. An unusable retention has to stop the run, not become the widest
// possible one.
const days = Number(process.argv[2] ?? 90);
if (!Number.isFinite(days) || days < 1) {
  console.error(
    `refusing to purge with retention '${process.argv[2]}': need a number of days >= 1. ` +
      'Omit the argument for the 90-day default.',
  );
  process.exit(2);
}

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
  // Log the window the job actually used, not the default. Two of these jobs
  // override it, so the old message claimed order notes were scrubbed at 90
  // days when the call passed 365 — the log is the only record of what
  // retention this system really applies, and it was misreporting it.
  const window = overrideDays ?? days;
  const { data, error } = await db.rpc(fn, { p_days: window });
  const stamp = new Date().toISOString();
  if (error) {
    console.error(`${stamp} ${fn} failed: ${error.message}`);
    failed = true;
  } else {
    console.log(`${stamp} ${label}: ${data} (older than ${window}d)`);
  }
}
// Order photos (handoff + stain, migration 0049): a custody record matters
// while a dispute is still possible, not forever. Removed through the Storage
// API, never by deleting storage.objects rows, which would orphan the files.
// Bounded per run so a backlog cannot turn one weekly job into thousands of
// calls; the next run picks up the rest.
const PHOTO_DAYS = 90;
const PHOTO_ORDERS_PER_RUN = 200;
try {
  const cutoff = new Date(Date.now() - PHOTO_DAYS * 86400_000).toISOString();
  const { data: finished, error } = await db
    .from('orders')
    .select('id')
    .in('status', ['delivered', 'cancelled', 'failed'])
    .lt('updated_at', cutoff)
    .order('updated_at', { ascending: true })
    .limit(PHOTO_ORDERS_PER_RUN);
  if (error) throw error;
  let removed = 0;
  for (const { id } of finished ?? []) {
    const { data: files } = await db.storage.from('order-photos').list(id);
    if (!files?.length) continue;
    const { error: rmErr } = await db.storage.from('order-photos').remove(files.map((f) => `${id}/${f.name}`));
    if (rmErr) throw rmErr;
    removed += files.length;
  }
  console.log(`${new Date().toISOString()} order photos removed: ${removed} (orders finished over ${PHOTO_DAYS}d)`);
} catch (err) {
  console.error(`${new Date().toISOString()} order photo purge failed: ${err?.message ?? err}`);
  failed = true;
}

process.exit(failed ? 1 : 0);
