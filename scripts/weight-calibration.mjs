#!/usr/bin/env node
/**
 * How good is the photo weight estimate? Compares each wash & fold order's
 * accepted estimate (orders.weight_estimate_lb, migration 0051) with what the
 * counter weighed (the by-the-pound order_items line after intake), per
 * method, and prints the factor to put in WeightEstimate.calibration.
 *
 *   node scripts/weight-calibration.mjs
 *
 * Read-only. Test accounts (CREASE_TEST_CUSTOMER_IDS in the dispatch .env)
 * are excluded: a test bag tells us nothing about real laundry.
 */
import { adminClient, readEnv } from './lib/client.mjs';

const { db } = await adminClient();
const testIds = new Set(
  (readEnv('services/dispatch/.env').CREASE_TEST_CUSTOMER_IDS ?? '').split(',').map((s) => s.trim()).filter(Boolean),
);

const { data: orders, error } = await db
  .from('orders')
  .select('id, customer_id, status, weight_estimate_lb, weight_estimate_method, order_items(quantity, service_items(unit))')
  .not('weight_estimate_lb', 'is', null)
  .in('status', ['cleaning', 'awaiting_approval', 'ready', 'return_dispatched', 'in_transit_to_customer', 'delivered']);
if (error) throw error;

const byMethod = {};
for (const o of orders ?? []) {
  if (testIds.has(o.customer_id)) continue;
  const weighed = (o.order_items ?? [])
    .filter((i) => i.service_items?.unit === 'pound')
    .reduce((sum, i) => sum + Number(i.quantity), 0);
  if (!(weighed > 0)) continue;
  (byMethod[o.weight_estimate_method] ??= []).push(weighed / Number(o.weight_estimate_lb));
}

const median = (xs) => {
  const s = [...xs].sort((a, b) => a - b);
  return s.length % 2 ? s[(s.length - 1) / 2] : (s[s.length / 2 - 1] + s[s.length / 2]) / 2;
};

if (Object.keys(byMethod).length === 0) {
  console.log('No weighed orders with a photo estimate yet.');
  process.exit(0);
}
for (const [method, ratios] of Object.entries(byMethod)) {
  const m = median(ratios);
  const within30 = ratios.filter((r) => r >= 0.7 && r <= 1.3).length;
  console.log(
    `${method}: ${ratios.length} orders, median actual/estimate ${m.toFixed(2)}, ` +
      `${Math.round((100 * within30) / ratios.length)}% within ±30%` +
      (ratios.length >= 20 ? ` -> set WeightEstimate.calibration ≈ ${m.toFixed(2)}` : ' (need 20+ before tuning)'),
  );
}
