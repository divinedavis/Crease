// The reconciler. Three code comments in this codebase promised one existed
// ("a retryable failure stays 'pending' so the reconciler picks it up",
// "a dropped simulated webhook is fine — the reconciler will poll") and it
// never did, so nothing in the system ever looked at an order again once its
// dispatch failed. A customer could pay, have the confirm call die on a lift,
// and sit forever behind a success animation with no courier booked and no
// error anywhere. Everything below exists to make that state recoverable.
//
// Run every few minutes from a systemd timer. Idempotent and safe to re-run.
import { readFileSync } from 'node:fs';
import { createClient } from '@supabase/supabase-js';
// supabase-js builds a RealtimeClient eagerly and Node 20 has no global
// WebSocket, so it throws at construction without an explicit transport —
// same reason the dispatch service passes `ws` in index.ts.
import WebSocketTransport from 'ws';

// Path is overridable so a relocation of the deploy root (this moved from
// /root/crease to /opt/crease once already) doesn't silently break the sweep.
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

// Loopback, not PUBLIC_URL: the dispatcher binds 127.0.0.1 and /v1/ is refused
// at nginx from anywhere else, so going out through the public hostname would
// just come back 403.
const DISPATCH = `http://127.0.0.1:${env.PORT ?? 8011}`;

// A bad state must not become a storm. If more than this many orders look
// stranded something systemic is wrong and a human should see it, not a loop.
const MAX_PER_RUN = 25;
// Long enough that a leg mid-dispatch is never mistaken for an abandoned one.
const STALE_CLAIM_MINUTES = 10;

const TERMINAL = ['delivered', 'returned', 'cancelled', 'failed'];
const stamp = () => new Date().toISOString();
let failed = false;

/**
 * Legs claimed but never handed to a carrier.
 *
 * dispatchLeg inserts the row before buying a quote so the unique index acts
 * as a mutex. If the process dies in between, that row keeps `status:'pending'`
 * with no provider_delivery_id — and because 'pending' is non-terminal, the
 * live-leg guard returns it forever and every future dispatch is a no-op. Fail
 * them so the order can move again.
 */
async function releaseStaleClaims() {
  const cutoff = new Date(Date.now() - STALE_CLAIM_MINUTES * 60_000).toISOString();
  const { data, error } = await db
    .from('delivery_legs')
    .update({ status: 'failed', last_error: 'claim abandoned; released by sweep' })
    .eq('status', 'pending')
    .is('provider_delivery_id', null)
    .lt('created_at', cutoff)
    .select('id');

  if (error) {
    console.error(`${stamp()} release-stale-claims failed: ${error.message}`);
    failed = true;
    return;
  }
  console.log(`${stamp()} stale claims released: ${data?.length ?? 0}`);
}

/**
 * Paid orders that never got a courier.
 *
 * The app's confirm-payment call is the only thing that normally dispatches,
 * and the Stripe webhook is its backstop — but a webhook whose handler died
 * used to be deduped away on retry, and a phone that lost signal never called
 * at all. This is the long-stop: money is held, the order has not moved, and
 * no live leg exists, so ask the dispatcher to try again. dispatchLeg is
 * idempotent, so a race with the real path resolves to one courier.
 */
async function dispatchStrandedOrders() {
  const { data: paid, error } = await db
    .from('payments')
    .select('order_id, status, orders!inner(id, status, service_tier)')
    .eq('kind', 'primary')
    .in('status', ['authorized', 'captured'])
    .in('orders.status', ['draft', 'scheduled'])
    .limit(MAX_PER_RUN * 4);

  if (error) {
    console.error(`${stamp()} stranded-order lookup failed: ${error.message}`);
    failed = true;
    return;
  }

  const candidates = [];
  for (const row of paid ?? []) {
    const order = row.orders;
    // return_only never has a pickup leg to send; its courier is booked by the
    // customer choosing a delivery time, so it is not stranded.
    if (order?.service_tier === 'return_only') continue;

    const { data: legs } = await db
      .from('delivery_legs')
      .select('status')
      .eq('order_id', row.order_id)
      .eq('leg', 'pickup');

    const live = (legs ?? []).some((l) => !TERMINAL.includes(l.status));
    if (!live) candidates.push(row.order_id);
    if (candidates.length >= MAX_PER_RUN) break;
  }

  if (candidates.length === 0) {
    console.log(`${stamp()} stranded orders dispatched: 0`);
    return;
  }

  let ok = 0;
  for (const orderId of candidates) {
    try {
      const res = await fetch(`${DISPATCH}/v1/orders/${orderId}/dispatch-pickup`, {
        method: 'POST',
        headers: { 'x-crease-key': env.INTERNAL_API_KEY, 'content-type': 'application/json' },
        signal: AbortSignal.timeout(30_000),
      });
      if (res.ok) {
        ok++;
        console.log(`${stamp()} re-dispatched ${orderId}`);
      } else {
        // Not necessarily an error: no courier coverage and an exhausted
        // attempt cap both answer non-2xx, and both are states a human owns.
        console.warn(`${stamp()} re-dispatch ${orderId} answered ${res.status}: ${(await res.text()).slice(0, 200)}`);
      }
    } catch (err) {
      console.error(`${stamp()} re-dispatch ${orderId} failed: ${err.message}`);
      failed = true;
    }
  }
  console.log(`${stamp()} stranded orders dispatched: ${ok}/${candidates.length}`);
}

// Claims first: releasing an abandoned leg is what lets the same order be
// re-dispatched in the step below, rather than waiting a whole cycle.
await releaseStaleClaims();
await dispatchStrandedOrders();
process.exit(failed ? 1 : 0);
