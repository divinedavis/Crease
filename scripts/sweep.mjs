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
// A carrier that has said nothing for this long is not mid-delivery, it is
// stuck. Generous, because a real courier leg legitimately spans hours.
const STALLED_LEG_HOURS = 6;

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
 * Legs a carrier accepted and then stopped talking about.
 *
 * The other two checks between them cover a claim that never reached a carrier
 * and an order that never got a leg. Neither covers the case in between: a leg
 * that reached `dispatching` flipped the order to `pickup_dispatched`, so it is
 * no longer `draft`/`scheduled`, and it has a provider so it is not an
 * abandoned claim. It is non-terminal, so the partial unique index treats it as
 * live and dispatchLeg hands it back to every caller as a success — forever.
 *
 * Two live sources: a real carrier whose callbacks stop arriving, and the mock,
 * whose entire state machine is setTimeout inside the dispatcher's own process,
 * so every deploy silently kills the timers of everything in flight.
 *
 * This only reports. Re-dispatching would risk a second courier for a delivery
 * that may well be happening, and cancelling would strand a real one — the
 * right move is to put it in front of a human.
 */
async function reportStalledLegs() {
  const cutoff = new Date(Date.now() - STALLED_LEG_HOURS * 3_600_000).toISOString();
  const { data, error } = await db
    .from('delivery_legs')
    .select('id, order_id, leg, status, provider, updated_at')
    .not('status', 'in', `(${TERMINAL.join(',')})`)
    .not('provider_delivery_id', 'is', null)
    .lt('updated_at', cutoff)
    .order('updated_at', { ascending: true })
    .limit(MAX_PER_RUN);

  if (error) {
    console.error(`${stamp()} stalled-leg lookup failed: ${error.message}`);
    failed = true;
    return;
  }
  const stalled = data ?? [];
  if (stalled.length > 0) {
    failed = true; // non-zero exit, so the unit is visibly failed rather than quietly green
    for (const l of stalled) {
      console.error(
        `${stamp()} STALLED leg ${l.id} (order ${l.order_id}, ${l.leg}, ${l.provider}) ` +
          `has sat at '${l.status}' since ${l.updated_at} — no carrier update, needs a human`,
      );
    }
  }
  console.log(`${stamp()} stalled legs: ${stalled.length}`);
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
    // Oldest first, and deterministic: without an order by, a backlog larger
    // than the cap can leave the same tail unvisited forever.
    .order('created_at', { ascending: true })
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
        // 4xx from the dispatcher is usually a state a human owns — no courier
        // coverage, an exhausted attempt cap — and not a sweep failure. But 401
        // means the internal key was rotated out from under us and 5xx means
        // the dispatcher is down; both make every future run a silent no-op,
        // which is exactly the shape of failure this script exists to catch.
        const body = (await res.text()).slice(0, 200);
        if (res.status === 401 || res.status === 403 || res.status >= 500) {
          console.error(`${stamp()} re-dispatch ${orderId} answered ${res.status}: ${body}`);
          failed = true;
        } else {
          console.warn(`${stamp()} re-dispatch ${orderId} answered ${res.status}: ${body}`);
        }
      }
    } catch (err) {
      console.error(`${stamp()} re-dispatch ${orderId} failed: ${err.message}`);
      failed = true;
    }
  }
  console.log(`${stamp()} stranded orders dispatched: ${ok}/${candidates.length}`);
  if (ok === 0 && candidates.length > 0) {
    console.error(`${stamp()} every re-dispatch was refused — the reconciler is not reconciling`);
    failed = true;
  }
}

// Claims first: releasing an abandoned leg is what lets the same order be
// re-dispatched in the step below, rather than waiting a whole cycle.
await releaseStaleClaims();
await dispatchStrandedOrders();
await reportStalledLegs();
process.exit(failed ? 1 : 0);
