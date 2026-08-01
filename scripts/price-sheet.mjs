#!/usr/bin/env node
/**
 * What to charge a customer for a full pickup-and-delivery order.
 *
 * Works backwards from a target margin against live courier quotes, under
 * three operating models, and reports the price a customer would actually see.
 *
 *   node scripts/price-sheet.mjs
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
const stripeFee = (t) => Math.round(t * 0.029) + 30;

const wp = (name, address, lat, lng) => ({ name, address, lat, lng, phone: '+15555550123', verification: 'signature' });
const CUSTOMER = wp('Customer', '215 Bedford Ave, Brooklyn, NY 11211', 40.7178, -73.9569);
const CLEANER = wp('Cleaner', '404 Bedford Ave, Brooklyn, NY 11249', 40.7141, -73.9613);
const MANIFEST = { description: 'Dry cleaning', declaredValueCents: 20000, itemCount: 5, requiresCar: true };

const q1 = await provider.quote({ pickup: CUSTOMER, dropoff: CLEANER, manifest: MANIFEST });
const q2 = await provider.quote({ pickup: CLEANER, dropoff: CUSTOMER, manifest: MANIFEST });
const ONE_LEG = Math.round((q1.feeCents + q2.feeCents) / 2);
const TWO_LEGS = q1.feeCents + q2.feeCents;

console.log(`\nLIVE COURIER COST   one leg ${money(ONE_LEG)}   two legs ${money(TWO_LEGS)}\n`);

// What the shop charges us. This is the number that matters, and it is NOT
// the same as what we charge the customer — see the note at the end.
const WHOLESALE = [
  ['5 shirts', 5 * 349],
  ['5 shirts + 2 slacks', 5 * 349 + 2 * 799],
  ['2 suits + 5 shirts', 2 * 1899 + 5 * 349],
  ['household week', 8 * 349 + 3 * 799 + 1599],
];

const TARGET_MARGIN = 600; // $6 contribution per order — modest, not greedy

/**
 * Smallest customer total that clears the target margin.
 *
 * Solved by search rather than algebra because the Stripe fee is a function
 * of the total, so the total appears on both sides.
 */
function requiredTotal(wholesaleCents, courierCents) {
  let total = wholesaleCents;
  for (let i = 0; i < 100_000; i++) {
    const margin = total - wholesaleCents - courierCents - stripeFee(total);
    if (margin >= TARGET_MARGIN) return total;
    total += 25;
  }
  return null;
}

const MODELS = [
  ['A. Two Uber legs (full service today)', TWO_LEGS],
  ['B. One Uber leg (customer does the other)', ONE_LEG],
  ['C. Own driver, 6 stops/hr, both legs', Math.round(2500 / 6) * 2],
];

for (const [label, courier] of MODELS) {
  console.log(label + `   courier ${money(courier)}/order`);
  console.log('   ' + pad('basket', 22) + rp('shop charges', 14) + rp('customer pays', 15) + rp('markup', 9) + rp('margin', 9));
  for (const [name, wholesale] of WHOLESALE) {
    const total = requiredTotal(wholesale, courier);
    const margin = total - wholesale - courier - stripeFee(total);
    const markup = ((total / wholesale - 1) * 100).toFixed(0) + '%';
    console.log('   ' + pad(name, 22) + rp(money(wholesale), 14) + rp(money(total), 15) + rp(markup, 9) + rp(money(margin), 9));
  }
  console.log('');
}

// A flat fee is what customers understand. What does it have to be, and what
// minimum does it imply, if the cleaning is marked up a normal amount?
console.log('\nIF YOU MARK CLEANING UP 35% AND ADD A FLAT DELIVERY FEE');
console.log('   ' + pad('model', 30) + rp('flat fee', 11) + rp('min order', 12) + rp('margin @ med basket', 21));
const MEDIAN = 5 * 349 + 2 * 799;
for (const [label, courier] of MODELS) {
  for (const fee of [995, 1495, 1995]) {
    const retail = Math.round(MEDIAN * 1.35);
    const total = retail + fee;
    const margin = total - MEDIAN - courier - stripeFee(total);
    if (margin >= 0) {
      // Minimum wholesale basket at which this fee still clears zero.
      let min = 0;
      for (let w = 0; w <= 20000; w += 100) {
        const t = Math.round(w * 1.35) + fee;
        if (t - w - courier - stripeFee(t) >= 0) { min = w; break; }
      }
      console.log('   ' + pad(label.slice(3), 30) + rp(money(fee), 11) + rp(money(min), 12) + rp(money(margin), 21));
      break;
    }
  }
}
console.log('');
