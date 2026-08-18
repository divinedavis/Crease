// What the orders actually earned.
//
// The pricing model says $2.80 an order. Nothing in the system had ever
// checked, and when somebody finally did the arithmetic the real number on a
// median order was $1.84 — Stripe's 2.9% falls on the whole capture, cleaning
// included, and the model only ever subtracted the card fee on the delivery
// fee. Past ~$96 of cleaning an order lost money. It was invisible because no
// row anywhere compared what an order collected to what it cost.
//
// This reads public.order_margin, which does that comparison from recorded
// amounts only — carrier fees as billed, capture as captured, payout as paid.
//
//   node scripts/margin-report.mjs [--days 30] [--all]
//
// Run it from the droplet, where the dispatch .env is; --all lists every
// order rather than only the ones that lost money.
import { readFileSync } from 'node:fs';
import { createClient } from '@supabase/supabase-js';
import WebSocketTransport from 'ws';

const envPath = process.env.DISPATCH_ENV_PATH ?? '/opt/crease/services/dispatch/.env';
const env = Object.fromEntries(
  readFileSync(envPath, 'utf8')
    .split('\n')
    .filter((l) => l.includes('=') && !l.startsWith('#'))
    .map((l) => [l.slice(0, l.indexOf('=')).trim(), l.slice(l.indexOf('=') + 1).trim()]),
);

const args = process.argv.slice(2);
const days = Number(args[args.indexOf('--days') + 1]) || 30;
const showAll = args.includes('--all');

const db = createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false },
  realtime: { transport: WebSocketTransport },
});

const money = (c) => `$${(c / 100).toFixed(2)}`;
const since = new Date(Date.now() - days * 86_400_000).toISOString();

const { data: rows, error } = await db
  .from('order_margin')
  .select('*')
  .gte('created_at', since)
  // An order nobody paid for has no economics to report — it is a draft, not
  // a loss.
  .gt('captured_cents', 0)
  .order('created_at', { ascending: false });

if (error) {
  console.error('could not read order_margin:', error.message);
  process.exit(1);
}
if (!rows.length) {
  console.log(`no captured orders in the last ${days} days`);
  process.exit(0);
}

const sum = (f) => rows.reduce((n, r) => n + f(r), 0);
const captured = sum((r) => r.captured_cents);
const card = sum((r) => r.card_fee_cents);
const courier = sum((r) => r.courier_cents);
const payout = sum((r) => r.payout_cents);
const margin = sum((r) => r.realized_margin_cents);

console.log(`\n${rows.length} captured orders, last ${days} days\n`);
console.log(`  collected          ${money(captured).padStart(12)}`);
console.log(`  card fees         -${money(card).padStart(12)}`);
console.log(`  couriers          -${money(courier).padStart(12)}`);
console.log(`  paid to shops     -${money(payout).padStart(12)}`);
console.log(`  ${'-'.repeat(30)}`);
console.log(`  realized margin    ${money(margin).padStart(12)}   (${money(Math.round(margin / rows.length))}/order)`);

// Per tier, because the tiers are priced by different formulas and a broken
// one hides inside a healthy average.
const tiers = [...new Set(rows.map((r) => r.service_tier))];
console.log('\n  by tier');
for (const tier of tiers) {
  const t = rows.filter((r) => r.service_tier === tier);
  const m = t.reduce((n, r) => n + r.realized_margin_cents, 0);
  console.log(
    `    ${String(tier).padEnd(14)} ${String(t.length).padStart(4)} orders  ` +
      `${money(m).padStart(10)} total  ${money(Math.round(m / t.length)).padStart(8)}/order`,
  );
}

// The whole point. A single losing order is a bug report, not a rounding
// difference.
const losers = rows.filter((r) => r.realized_margin_cents < 0);
if (losers.length) {
  console.log(`\n  !! ${losers.length} order(s) lost money:`);
  for (const r of losers) {
    console.log(
      `    ${r.short_code}  ${String(r.service_tier).padEnd(12)} ` +
        `collected ${money(r.captured_cents)}  card ${money(r.card_fee_cents)}  ` +
        `courier ${money(r.courier_cents)}  shop ${money(r.payout_cents)}  ` +
        `=> ${money(r.realized_margin_cents)}`,
    );
  }
} else {
  console.log('\n  no order lost money in this window');
}

if (showAll) {
  console.log('\n  every order');
  for (const r of rows) {
    console.log(
      `    ${r.short_code}  ${String(r.service_tier).padEnd(12)} ${String(r.service_type).padEnd(10)} ` +
        `${money(r.captured_cents).padStart(9)} collected  ${money(r.realized_margin_cents).padStart(8)} kept  ${r.cleaner_name}`,
    );
  }
}
console.log('');
