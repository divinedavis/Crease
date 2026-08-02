#!/usr/bin/env node
/**
 * What Crease must charge for the delivery service alone.
 *
 * Assumes Crease never touches the cleaning bill: the customer settles that
 * with the shop directly, and Crease sells transport. So the only revenue is
 * the delivery fee, and the only costs are couriers plus card processing.
 *
 * That makes this a much simpler business to price — and a much less
 * forgiving one, because there is no cleaning margin to hide courier cost
 * inside. The fee has to carry the whole thing on its own.
 *
 *   node scripts/courier-pricing.mjs
 */
import { UberDirectProvider } from '../packages/delivery/dist/index.js';

const provider = new UberDirectProvider({
  clientId: process.env.UBER_CLIENT_ID,
  clientSecret: process.env.UBER_CLIENT_SECRET,
  customerId: process.env.UBER_CUSTOMER_ID,
});

const money = (c) => `$${(c / 100).toFixed(2)}`;
const pad = (s, n) => String(s).padEnd(n);
const rp = (s, n) => String(s).padStart(n);

// Stripe takes 2.9% + 30c of whatever we charge. On a small fee the fixed 30c
// is a meaningful slice, which is an argument for charging per order rather
// than per leg.
const STRIPE_PCT = 0.029;
const STRIPE_FIXED = 30;

/** Fee that nets `target` after Stripe and courier cost. */
function feeFor(courierCents, targetCents) {
  // fee - courier - (fee*pct + fixed) = target   =>   solve for fee
  return Math.ceil((courierCents + targetCents + STRIPE_FIXED) / (1 - STRIPE_PCT));
}
function marginAt(fee, courier) {
  return fee - courier - Math.round(fee * STRIPE_PCT) - STRIPE_FIXED;
}

const wp = (name, address, lat, lng) => ({ name, address, lat, lng, phone: '+15555550123', verification: 'signature' });
const CUSTOMER = wp('Customer', '215 Bedford Ave, Brooklyn, NY 11211', 40.7178, -73.9569);
const CLEANER = wp('Cleaner', '404 Bedford Ave, Brooklyn, NY 11249', 40.7141, -73.9613);
const MANIFEST = { description: 'Dry cleaning', declaredValueCents: 20000, itemCount: 5, requiresCar: true };

const q1 = await provider.quote({ pickup: CUSTOMER, dropoff: CLEANER, manifest: MANIFEST });
const q2 = await provider.quote({ pickup: CLEANER, dropoff: CUSTOMER, manifest: MANIFEST });
const LEG = Math.round((q1.feeCents + q2.feeCents) / 2);
const ROUND = q1.feeCents + q2.feeCents;

console.log(`\nLIVE COURIER COST    one leg ${money(LEG)}    round trip ${money(ROUND)}\n`);

console.log('WHAT YOU MUST CHARGE (delivery only — no cleaning revenue)');
console.log('  ' + pad('service', 30) + rp('courier', 10) + rp('break-even', 13) + rp('+$5', 10) + rp('+$8', 10) + rp('+$12', 10));
const SERVICES = [
  ['Round trip, both legs Uber', ROUND],
  ['One leg only', LEG],
  ['Own driver, 6 stops/hr', Math.round(2500 / 6) * 2],
  ['Own driver, 10 stops/hr', Math.round(2500 / 10) * 2],
];
for (const [label, courier] of SERVICES) {
  const row = [0, 500, 800, 1200].map((t) => money(feeFor(courier, t)));
  console.log('  ' + pad(label, 30) + rp(money(courier), 10) + rp(row[0], 13) + rp(row[1], 10) + rp(row[2], 10) + rp(row[3], 10));
}

console.log('\n\nAT PRICES CUSTOMERS MIGHT ACTUALLY ACCEPT');
console.log('  ' + pad('you charge', 14) + pad('round trip (Uber)', 22) + pad('one leg (Uber)', 20) + 'own driver 6/hr');
for (const fee of [1495, 1995, 2495, 2995, 3495]) {
  const cells = [ROUND, LEG, Math.round(2500 / 6) * 2].map((c) => {
    const m = marginAt(fee, c);
    return (m >= 0 ? '+' : '') + money(m);
  });
  console.log('  ' + pad(money(fee), 14) + pad(cells[0], 22) + pad(cells[1], 20) + cells[2]);
}

console.log('\n\nSUBSCRIPTION VIEW  (a weekly pickup, billed monthly)');
console.log('  Card fees are charged once a month instead of once an order,');
console.log('  which is worth real money on a small ticket.');
console.log('  ' + pad('plan', 26) + rp('orders/mo', 11) + rp('courier cost', 14) + rp('break-even', 12) + rp('at $99/mo', 12));
for (const [label, n] of [['Weekly round trip', 4], ['Fortnightly round trip', 2], ['Weekly, one leg', 4]]) {
  const perOrder = label.includes('one leg') ? LEG : ROUND;
  const courier = perOrder * n;
  const be = Math.ceil((courier + STRIPE_FIXED) / (1 - STRIPE_PCT));
  const at99 = marginAt(9900, courier);
  console.log('  ' + pad(label, 26) + rp(n, 11) + rp(money(courier), 14) + rp(money(be), 12) + rp((at99 >= 0 ? '+' : '') + money(at99), 12));
}

console.log('\n\nTHE FIXED-COST FLOOR');
console.log(`  Every round trip costs ${money(ROUND)} in couriers no matter what.`);
console.log('  Distance barely matters under ~3 miles, so a denser service area');
console.log('  does not reduce cost per order — only using fewer legs, or your');
console.log('  own driver, does. Uber Direct cannot batch: one pickup, one');
console.log('  dropoff per delivery, so two customers can never share a trip.');
console.log('');
