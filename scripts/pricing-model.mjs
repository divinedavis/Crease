#!/usr/bin/env node
/**
 * Unit economics against live Uber Direct quotes.
 *
 * Every courier number here is fetched from the real API, not assumed. The
 * whole point is that the cost side of this business is not a guess — it is a
 * price Uber will quote you today — and the pricing decision follows from it.
 *
 *   node scripts/pricing-model.mjs
 */
import { UberDirectProvider } from '../packages/delivery/dist/index.js';

const provider = new UberDirectProvider({
  clientId: process.env.UBER_CLIENT_ID,
  clientSecret: process.env.UBER_CLIENT_SECRET,
  customerId: process.env.UBER_CUSTOMER_ID,
});

const money = (c) => `$${(c / 100).toFixed(2)}`;
const pad = (s, n) => String(s).padEnd(n);
const rpad = (s, n) => String(s).padStart(n);

// Stripe: 2.9% + 30c per successful charge. Applied once per order on the
// customer's total, because the difference charge is rare enough to ignore in
// a planning model.
const stripeFee = (totalCents) => Math.round(totalCents * 0.029) + 30;

const wp = (name, address, lat, lng) => ({
  name, address, lat, lng, phone: '+15555550123', verification: 'signature',
});

const MANIFEST = {
  description: 'Dry cleaning',
  declaredValueCents: 20000,
  itemCount: 5,
  requiresCar: true,
};

// A customer and a cleaner about a mile apart in the same neighbourhood —
// the densest, cheapest case, and therefore the best case for the model.
const CUSTOMER = wp('Customer', '215 Bedford Ave, Brooklyn, NY 11211', 40.7178, -73.9569);
const CLEANER = wp('Cleaner', '404 Bedford Ave, Brooklyn, NY 11249', 40.7141, -73.9613);

console.log('\nFETCHING REAL COURIER QUOTES…');
const outbound = await provider.quote({ pickup: CUSTOMER, dropoff: CLEANER, manifest: MANIFEST });
const inbound = await provider.quote({ pickup: CLEANER, dropoff: CUSTOMER, manifest: MANIFEST });
const courier = outbound.feeCents + inbound.feeCents;
console.log(`  leg 1 ${money(outbound.feeCents)} + leg 2 ${money(inbound.feeCents)} = ${money(courier)} per order`);

// Baskets from the seeded price list — what people actually send out.
const BASKETS = [
  ['5 shirts', 5 * 349],
  ['5 shirts + 2 slacks', 5 * 349 + 2 * 799],
  ['2 suits + 5 shirts', 2 * 1899 + 5 * 349],
  ['week of a household', 8 * 349 + 3 * 799 + 1599],
  ['2 comforters', 2 * 3499],
];

const COMMISSION_BPS = 2000; // what the shop gives up

function contribution({ subtotal, deliveryFee, serviceFee }) {
  const customerTotal = subtotal + deliveryFee + serviceFee;
  const shopPayout = subtotal - Math.round((subtotal * COMMISSION_BPS) / 10_000);
  const stripe = stripeFee(customerTotal);
  return {
    customerTotal,
    revenue: customerTotal - shopPayout,
    margin: customerTotal - shopPayout - courier - stripe,
    stripe,
  };
}

console.log('\n\nA.  CURRENT SETTINGS — no delivery fee, no minimum');
console.log('    ' + pad('basket', 22) + rpad('cleaning', 10) + rpad('customer pays', 15) + rpad('margin', 10));
for (const [label, subtotal] of BASKETS) {
  const r = contribution({ subtotal, deliveryFee: 0, serviceFee: 0 });
  console.log('    ' + pad(label, 22) + rpad(money(subtotal), 10) + rpad(money(r.customerTotal), 15) + rpad(money(r.margin), 10));
}
console.log('    every one of these loses money.');

// What flat fee makes the *median* basket break even?
console.log('\n\nB.  BREAK-EVEN DELIVERY FEE BY BASKET');
console.log('    (the fee that makes margin exactly zero, before any profit)');
console.log('    ' + pad('basket', 22) + rpad('cleaning', 10) + rpad('fee needed', 13));
for (const [label, subtotal] of BASKETS) {
  let fee = 0;
  while (contribution({ subtotal, deliveryFee: fee, serviceFee: 0 }).margin < 0 && fee < 6000) fee += 25;
  console.log('    ' + pad(label, 22) + rpad(money(subtotal), 10) + rpad(money(fee), 13));
}

// A flat fee people will actually pay, plus a minimum to carry the rest.
console.log('\n\nC.  FLAT $9.99 DELIVERY FEE — what minimum order does it need?');
const FLAT = 999;
console.log('    ' + pad('basket', 22) + rpad('cleaning', 10) + rpad('customer pays', 15) + rpad('margin', 10));
for (const [label, subtotal] of BASKETS) {
  const r = contribution({ subtotal, deliveryFee: FLAT, serviceFee: 0 });
  console.log('    ' + pad(label, 22) + rpad(money(subtotal), 10) + rpad(money(r.customerTotal), 15) + rpad(money(r.margin), 10));
}
let minOrder = 0;
while (contribution({ subtotal: minOrder, deliveryFee: FLAT, serviceFee: 0 }).margin < 0 && minOrder < 30000) minOrder += 100;
console.log(`    -> minimum cleaning subtotal to break even: ${money(minOrder)}`);

// Commission is the other dial. How much does raising it help?
console.log('\n\nD.  DOES A HIGHER COMMISSION RESCUE IT?  (basket: 5 shirts + 2 slacks, $9.99 fee)');
const testSub = 5 * 349 + 2 * 799;
console.log('    ' + pad('commission', 14) + rpad('shop keeps', 13) + rpad('our margin', 13));
for (const bps of [2000, 2500, 3000, 3500, 4000]) {
  const shopPayout = testSub - Math.round((testSub * bps) / 10_000);
  const customerTotal = testSub + FLAT;
  const margin = customerTotal - shopPayout - courier - stripeFee(customerTotal);
  console.log('    ' + pad(`${bps / 100}%`, 14) + rpad(money(shopPayout), 13) + rpad(money(margin), 13));
}
console.log('    commission moves margin slowly and costs you partners quickly.');

// The structural lever.
console.log('\n\nE.  THE ONLY BIG LEVER — fewer courier legs per order');
console.log(`    Today every order pays for two legs: ${money(courier)}.`);
console.log('    Uber Direct is one-pickup-to-one-dropoff, so several customers');
console.log('    CANNOT share a leg — each address is its own delivery. Batching');
console.log('    needs a route-based carrier or your own driver, not this API.');
console.log('');
console.log('    ' + pad('scenario', 34) + rpad('courier/order', 14) + rpad('margin @ $9.99 fee', 20));
const scenarios = [
  ['two Uber legs (today)', courier],
  ['one Uber leg, customer drops off', Math.round(courier / 2)],
  ['own driver, 6 stops/hour @ $25/hr', Math.round(2500 / 6) * 2],
  ['own driver, 10 stops/hour @ $25/hr', Math.round(2500 / 10) * 2],
];
for (const [label, cost] of scenarios) {
  const customerTotal = testSub + FLAT;
  const shopPayout = testSub - Math.round((testSub * COMMISSION_BPS) / 10_000);
  const margin = customerTotal - shopPayout - cost - stripeFee(customerTotal);
  console.log('    ' + pad(label, 34) + rpad(money(cost), 14) + rpad(money(margin), 20));
}

console.log('');
