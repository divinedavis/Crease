import { strict as assert } from 'node:assert';
import { test } from 'node:test';
import { ShipdayProvider } from './shipday.js';
import { DeliveryProviderError } from './types.js';
import type { CreateDeliveryRequest, QuoteRequest } from './types.js';

const NOW = Date.parse('2026-11-21T15:00:00Z');
const TOKEN = 'shipday-webhook-token-0123456789';

interface Seen {
  method: string;
  url: string;
  headers: Record<string, string>;
  body: any;
}

function fakeFetch(answers: Array<{ status: number; body?: unknown } | Error>) {
  const seen: Seen[] = [];
  const impl = (async (url: string, init: RequestInit) => {
    seen.push({
      method: String(init.method),
      url,
      headers: init.headers as Record<string, string>,
      body: init.body ? JSON.parse(String(init.body)) : undefined,
    });
    const next = answers.shift();
    if (!next) throw new Error('unexpected call');
    if (next instanceof Error) throw next;
    return new Response(next.status === 204 ? null : next.body === undefined ? '' : JSON.stringify(next.body), { status: next.status });
  }) as unknown as typeof fetch;
  return { impl, seen };
}

function provider(fetchImpl: typeof fetch, extra: Partial<ConstructorParameters<typeof ShipdayProvider>[0]> = {}) {
  return new ShipdayProvider({ apiKey: 'sd-key', webhookToken: TOKEN, fetchImpl, now: () => NOW, ...extra });
}

const REQ: QuoteRequest = {
  pickup: {
    name: 'Ada Lovelace',
    phone: '(718) 555-0142',
    address: '251 Dekalb Ave, Brooklyn, NY 11205',
    lat: 40.69,
    lng: -73.97,
    notes: 'Buzzer 4B',
  },
  dropoff: {
    name: 'Fulton Cleaners',
    phone: '7185550199',
    address: '909 Fulton St, Brooklyn, NY 11238',
    notes: 'Hand to the counter',
    verification: 'signature',
  },
  manifest: { description: 'Laundry bag', declaredValueCents: 10_000, itemCount: 2, weightLbs: 21.6, requiresCar: true },
};
const CREATE: CreateDeliveryRequest = { ...REQ, externalId: 'leg_abc-123', orderReference: 'CR-1001' };

const order = (state: string, extra: Record<string, unknown> = {}) => ({
  orderId: 777,
  orderNumber: 'leg_abc-123',
  orderStatus: { orderState: state },
  activityLog: {},
  ...extra,
});

const ANSWERS = [
  { id: '1', name: 'DoorDash', fee: 11.5, pickupTime: '2026-11-21T15:12:00Z', deliveryTime: '2026-11-21T15:40:00Z', error: false, regulatoryFee: 0 },
  { id: null, name: 'MotoClick', fee: null, error: true, errorMessage: 'No service available', errorDescription: 'Outside Delivery Zone' },
  { id: 'dqt_x', name: 'Uber', fee: 10.99, pickupTime: '2026-11-21T15:18:00Z', deliveryTime: '2026-11-21T15:51:00Z', error: false, regulatoryFee: 0.5 },
];

test('quote asks for availability with the Basic key and takes the cheapest, fees included', async () => {
  const { impl, seen } = fakeFetch([{ status: 200, body: ANSWERS }]);
  const q = await provider(impl).quote(REQ);
  assert.equal(seen[0].method, 'POST');
  assert.equal(seen[0].url, 'https://api.shipday.com/on-demand/availability');
  assert.equal(seen[0].headers.authorization, 'Basic sd-key');
  assert.deepEqual(seen[0].body, { pickupAddress: REQ.pickup.address, deliveryAddress: REQ.dropoff.address });
  // Uber 10.99 + 0.50 regulatory = 11.49 beats DoorDash 11.50.
  assert.equal(q.quoteId, 'Uber');
  assert.equal(q.feeCents, 1149);
  assert.equal(q.estimatedDropoffAt, '2026-11-21T15:51:00.000Z');
  assert.equal(q.expiresAt, new Date(NOW + 5 * 60_000).toISOString());
});

test('quote reports why nobody can take the leg', async () => {
  const { impl } = fakeFetch([{ status: 200, body: [ANSWERS[1]] }]);
  const q = await provider(impl).quote(REQ);
  assert.equal(q.unavailableReason, 'MotoClick: Outside Delivery Zone');
  assert.ok(Number.isNaN(q.feeCents));
});

test('quote passes a future pickup time and ignores a past one', async () => {
  const { impl, seen } = fakeFetch([{ status: 200, body: ANSWERS }, { status: 200, body: ANSWERS }]);
  const p = provider(impl);
  await p.quote({ ...REQ, pickupReadyAt: '2026-11-21T18:00:00.000Z' });
  await p.quote({ ...REQ, pickupReadyAt: '2026-11-21T10:00:00.000Z' });
  assert.equal(seen[0].body.pickUpTime, '2026-11-21T18:00:00Z');
  assert.equal(seen[1].body.pickUpTime, undefined);
});

test('createDelivery inserts the order under our leg id, estimates and assigns the cheapest', async () => {
  const { impl, seen } = fakeFetch([
    { status: 200, body: [] }, // not there yet
    { status: 200, body: { success: true, orderId: 777 } },
    { status: 200, body: ANSWERS },
    { status: 200, body: { orderId: 777, thirdPartyName: 'Uber', totalBillableAmount: 12.74, trackingUrl: 'https://dispatch.shipday.com/tracking/x' } },
    { status: 200, body: [order('NOT_ACCEPTED')] },
  ]);
  const s = await provider(impl).createDelivery(CREATE);

  assert.equal(seen[0].url, 'https://api.shipday.com/orders/leg_abc-123');
  const body = seen[1].body;
  assert.equal(seen[1].url, 'https://api.shipday.com/orders');
  assert.equal(body.orderNumber, 'leg_abc-123');
  assert.equal(body.restaurantName, 'Ada Lovelace');
  assert.equal(body.restaurantPhoneNumber, '+17185550142');
  assert.equal(body.customerName, 'Fulton Cleaners');
  assert.equal(body.customerPhoneNumber, '+17185550199');
  assert.equal(body.pickupLatitude, 40.69);
  assert.equal(body.deliveryLatitude, undefined);
  // Shipday has no weight field: the courier reads it in the instructions.
  assert.equal(body.pickupInstruction, 'Laundry bag, about 22 lb, 2 items, needs a car. Buzzer 4B');
  assert.equal(body.deliveryInstruction, 'Hand to the counter');
  assert.equal(body.totalOrderCost, 100);
  assert.equal(body.additionalId, 'CR-1001');

  assert.equal(seen[2].url, 'https://api.shipday.com/on-demand/estimate/777');
  assert.deepEqual(seen[3].body, { name: 'Uber', orderId: 777, estimateReference: 'dqt_x', podType: 'SIGNATURE' });
  assert.equal(s.providerDeliveryId, 'leg_abc-123');
  assert.equal(s.status, 'dispatching');
  assert.equal(s.feeCents, 1274);
  assert.equal(s.trackingUrl, 'https://dispatch.shipday.com/tracking/x');
});

test('a replay of a leg that already has a courier books nothing', async () => {
  const { impl, seen } = fakeFetch([
    { status: 200, body: [order('STARTED')] },
    { status: 200, body: [order('STARTED')] },
    { status: 200, body: { id: 1, thirdPartyName: 'DoorDash', driverName: 'Sam', driverPhone: '+17185550000' } },
  ]);
  const s = await provider(impl).createDelivery(CREATE);
  assert.ok(seen.every((c) => c.method === 'GET'));
  assert.equal(s.status, 'en_route_to_pickup');
  assert.equal(s.courier?.name, 'Sam');
});

test('a replay of an order already booked but not yet accepted books nothing', async () => {
  const { impl, seen } = fakeFetch([
    { status: 200, body: [order('NOT_ASSIGNED')] },
    { status: 200, body: { id: 1, thirdPartyName: 'Uber' } },
  ]);
  const s = await provider(impl).createDelivery(CREATE);
  assert.equal(seen.length, 2);
  assert.equal(s.status, 'dispatching');
});

test('a replay of an order inserted but never assigned reuses it instead of inserting again', async () => {
  const { impl, seen } = fakeFetch([
    { status: 200, body: [order('NOT_ASSIGNED')] },
    { status: 400, body: {} }, // no on-demand booking yet
    { status: 200, body: [ANSWERS[0]] },
    { status: 200, body: { orderId: 777, thirdPartyName: 'DoorDash' } },
    { status: 200, body: [order('NOT_ACCEPTED')] },
  ]);
  await provider(impl).createDelivery(CREATE);
  assert.ok(!seen.some((c) => c.method === 'POST' && c.url.endsWith('/orders')));
  assert.equal(seen[2].url, 'https://api.shipday.com/on-demand/estimate/777');
  assert.equal(seen[3].body.name, 'DoorDash');
});

test('no courier for the leg is a non-retryable failure', async () => {
  const { impl } = fakeFetch([
    { status: 200, body: [] },
    { status: 200, body: { success: true, orderId: 777 } },
    { status: 200, body: [ANSWERS[1]] },
  ]);
  await assert.rejects(provider(impl).createDelivery(CREATE), (e: any) =>
    e instanceof DeliveryProviderError && e.opts.providerCode === 'no_quotes' && !e.opts.retryable);
});

test('Shipday order states map onto ours, and a deleted order reads as cancelled', async () => {
  const cases: Array<[string, string]> = [
    ['NOT_ASSIGNED', 'dispatching'],
    ['NOT_ACCEPTED', 'dispatching'],
    ['NOT_STARTED_YET', 'courier_assigned'],
    ['STARTED', 'en_route_to_pickup'],
    ['PICKED_UP', 'picked_up'],
    ['READY_TO_DELIVER', 'en_route_to_dropoff'],
    ['ALREADY_DELIVERED', 'delivered'],
    ['INCOMPLETE', 'failed'],
    ['FAILED_DELIVERY', 'failed'],
  ];
  for (const [raw, want] of cases) {
    const { impl } = fakeFetch([
      { status: 200, body: [order(raw, { activityLog: { pickedUpTime: '2026-11-21T14:30:00', deliveryTime: '2026-11-21T14:55:00' } })] },
      { status: 400, body: {} },
    ]);
    const s = await provider(impl).getDelivery('leg_abc-123');
    assert.equal(s.status, want, raw);
    if (raw === 'ALREADY_DELIVERED') assert.equal(s.completedAt, '2026-11-21T14:55:00.000Z');
  }
  const { impl } = fakeFetch([{ status: 200, body: [] }]);
  assert.equal((await provider(impl).getDelivery('leg_abc-123')).status, 'cancelled');
});

test('only https tracking links are kept, and fees are bounded', async () => {
  const { impl } = fakeFetch([
    { status: 200, body: [order('STARTED', { trackingLink: 'http://evil.example/x' })] },
    { status: 200, body: { id: 1, thirdPartyName: 'Uber', totalBillableAmount: 9_999, trackingUrl: 'javascript:alert(1)' } },
  ]);
  const s = await provider(impl).getDelivery('leg_abc-123');
  assert.equal(s.trackingUrl, undefined);
  assert.equal(s.feeCents, undefined);
});

test('cancel calls off the courier, then deletes the order', async () => {
  const { impl, seen } = fakeFetch([
    { status: 200, body: [order('NOT_STARTED_YET')] },
    { status: 200, body: { success: true } },
    { status: 204 },
  ]);
  const s = await provider(impl).cancelDelivery('leg_abc-123');
  assert.equal(seen[1].url, 'https://api.shipday.com/on-demand/cancel/777');
  assert.equal(seen[2].method, 'DELETE');
  assert.equal(seen[2].url, 'https://api.shipday.com/orders/777');
  assert.equal(s.status, 'cancelled');
});

test('cancel still deletes an order that never had an on-demand courier', async () => {
  const { impl, seen } = fakeFetch([
    { status: 200, body: [order('NOT_ASSIGNED')] },
    { status: 400, body: {} },
    { status: 204 },
  ]);
  assert.equal((await provider(impl).cancelDelivery('leg_abc-123')).status, 'cancelled');
  assert.equal(seen[2].method, 'DELETE');
});

test('cancel refuses once the bag is picked up', async () => {
  const { impl, seen } = fakeFetch([{ status: 200, body: [order('PICKED_UP')] }]);
  await assert.rejects(provider(impl).cancelDelivery('leg_abc-123'), (e: any) => e.opts?.providerCode === 'too_late');
  assert.equal(seen.length, 1);
});

test('5xx and 429 are retryable, 4xx is not, and a timeout is retryable', async () => {
  for (const [status, retryable] of [[503, true], [429, true], [401, false]] as const) {
    const { impl } = fakeFetch([{ status, body: {} }]);
    await assert.rejects(provider(impl).quote(REQ), (e: any) => e.opts.retryable === retryable && e.opts.status === status);
  }
  const t = new Error('timed out');
  t.name = 'TimeoutError';
  const { impl } = fakeFetch([t]);
  await assert.rejects(provider(impl).quote(REQ), (e: any) => e.opts.retryable && e.opts.providerCode === 'timeout');
});

test('ids are checked before they reach a URL path, and an unconfigured provider makes no calls', async () => {
  const { impl, seen } = fakeFetch([]);
  await assert.rejects(provider(impl).getDelivery('../orders'), DeliveryProviderError);
  await assert.rejects(provider(impl, { apiKey: undefined }).quote(REQ), /not configured/);
  assert.equal(seen.length, 0);
  assert.equal(provider(impl, { apiKey: undefined }).isConfigured(), false);
});

const hook = (body: unknown, token?: string) => ({
  headers: token === undefined ? {} : { token },
  rawBody: Buffer.from(JSON.stringify(body)),
});
const EVENT = {
  timestamp: 1795269600000,
  event: 'ORDER_PIKEDUP',
  order_status: 'PICKED_UP',
  order: { id: 777, order_number: 'leg_abc-123' },
};

test('a webhook needs the exact token, and with no token configured every webhook is refused', async () => {
  const { impl } = fakeFetch([]);
  assert.equal((await provider(impl).handleWebhook(hook(EVENT))).signatureValid, false);
  assert.equal((await provider(impl).handleWebhook(hook(EVENT, 'wrong'))).signatureValid, false);
  assert.equal((await provider(impl).handleWebhook(hook(EVENT, `${TOKEN}x`))).signatureValid, false);
  assert.equal((await provider(impl, { webhookToken: undefined }).handleWebhook(hook(EVENT, TOKEN))).signatureValid, false);
});

test('a webhook re-reads the order instead of trusting the payload', async () => {
  const { impl, seen } = fakeFetch([
    { status: 200, body: [order('STARTED')] }, // Shipday says it is NOT picked up yet
    { status: 400, body: {} },
  ]);
  const r = await provider(impl).handleWebhook(hook(EVENT, TOKEN));
  assert.equal(r.signatureValid, true);
  assert.equal(seen[0].url, 'https://api.shipday.com/orders/leg_abc-123');
  assert.equal(r.event?.status, 'en_route_to_pickup');
  assert.equal(r.event?.eventId, 'leg_abc-123:ORDER_PIKEDUP:1795269600000');
  assert.equal(r.event?.externalId, 'leg_abc-123');
});

test('a webhook falls back to the payload only when Shipday cannot be reached', async () => {
  const { impl } = fakeFetch([new Error('ECONNRESET')]);
  const r = await provider(impl).handleWebhook(hook(EVENT, TOKEN));
  assert.equal(r.event?.status, 'picked_up');

  const gone = fakeFetch([{ status: 401, body: {} }]);
  const r2 = await provider(gone.impl).handleWebhook(hook(EVENT, TOKEN));
  assert.equal(r2.event, undefined);
  assert.match(String(r2.ignored), /re-read failed/);
});

test('webhooks with no status meaning, or an unusable order number, are ignored', async () => {
  const { impl, seen } = fakeFetch([]);
  const p = provider(impl);
  assert.match(String((await p.handleWebhook(hook({ ...EVENT, event: 'ORDER_POD_UPLOAD' }, TOKEN))).ignored), /unhandled/);
  assert.match(
    String((await p.handleWebhook(hook({ ...EVENT, order: { order_number: '../x' } }, TOKEN))).ignored),
    /order_number/,
  );
  assert.match(String((await p.handleWebhook({ headers: { token: TOKEN }, rawBody: Buffer.from('{') })).ignored), /unparseable/);
  assert.equal(seen.length, 0);
});
