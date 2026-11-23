import { strict as assert } from 'node:assert';
import { createHmac } from 'node:crypto';
import { test } from 'node:test';
import { NashProvider } from './nash.js';
import { DeliveryProviderError } from './types.js';
import type { QuoteRequest } from './types.js';

const NOW = Date.parse('2026-11-18T15:00:00Z');
const SECRET_BYTES = Buffer.from('nash-webhook-signing-secret-bytes');
const WHSEC = `whsec_${SECRET_BYTES.toString('base64')}`;

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
    return new Response(next.body === undefined ? '' : JSON.stringify(next.body), { status: next.status });
  }) as unknown as typeof fetch;
  return { impl, seen };
}

function provider(fetchImpl: typeof fetch, extra: Partial<ConstructorParameters<typeof NashProvider>[0]> = {}) {
  return new NashProvider({
    apiKey: 'nash-key',
    orgId: 'org_123',
    webhookSecret: WHSEC,
    apiBase: 'https://api.sandbox.usenash.com',
    fetchImpl,
    now: () => NOW,
    ...extra,
  });
}

const REQ: QuoteRequest = {
  pickup: {
    name: 'Ada Lovelace',
    phone: '(718) 555-0142',
    address: '251 Dekalb Ave, Brooklyn, NY 11205',
    lat: 40.69,
    lng: -73.97,
    notes: 'Buzzer 4B',
    verification: 'signature',
  },
  dropoff: {
    name: 'Fulton Cleaners',
    phone: '7185550199',
    address: '909 Fulton St, Brooklyn, NY 11238',
    verification: 'signature',
  },
  manifest: {
    description: 'Laundry bag (wash & fold) — order CR7',
    declaredValueCents: 20_000,
    itemCount: 1,
    weightLbs: 19,
    requiresCar: true,
  },
};

const quote = (id: string, total: number, extra: object = {}) => ({
  id,
  providerName: id,
  totalPriceCents: total,
  currency: 'USD',
  expireTime: '2026-11-18T15:10:00.000000',
  ...extra,
});

const JOB = (status: string, extra: object = {}) => ({
  id: 'job_1',
  externalIdentifier: 'leg-1',
  jobConfigurations: [
    {
      id: 'jc_1',
      publicTrackingUrl: 'https://tracking.sandbox.usenash.com/ord_1',
      tasks: [
        {
          id: 'tsk_old',
          createdAt: '2026-11-18T14:00:00.000000',
          status: 'CANCELED_BY_AUTO_REASSIGN',
          delivery: { status: 'CANCELED_BY_PROVIDER' },
        },
        {
          id: 'tsk_new',
          createdAt: '2026-11-18T14:30:00.000000',
          status: 'RUNNING',
          delivery: {
            status,
            totalPriceCents: 1150,
            courierName: 'Sam',
            courierPickupPhoneNumber: '+16505550001',
            courierDropoffPhoneNumber: '+16505550002',
            courierVehicle: { make: 'Toyota', model: 'Sienna', color: 'Grey' },
            courierLocation: { lat: 40.7, lng: -73.9 },
            statusHistory: [
              { status: 'created', createdAt: '2026-11-18T14:30:00.000000' },
              { status: 'pickup_complete', createdAt: '2026-11-18T14:50:00.000000' },
            ],
          },
          ...extra,
        },
      ],
    },
  ],
});

test('quote sends a laundry bag as weighed, car-or-bigger, signed for', async () => {
  const { impl, seen } = fakeFetch([
    { status: 200, body: { id: 'ord_q', quotes: [quote('a', 1400), quote('b', 1150), quote('c', 900, { isSuccessful: false })] } },
  ]);
  const q = await provider(impl).quote(REQ);
  const s = seen[0];
  assert.equal(s.url, 'https://api.sandbox.usenash.com/v1/order/get_quotes');
  assert.equal(s.headers.authorization, 'Bearer nash-key');
  assert.equal(s.headers['nash-org-id'], 'org_123');
  assert.equal(s.body.minimumVehicleSize, 'car');
  assert.equal(s.body.weight, 19);
  assert.equal(s.body.weightUnit, 'lbs');
  assert.deepEqual(s.body.requirements, ['signature_proof_of_delivery']);
  assert.equal(s.body.pickupPhoneNumber, '+17185550142');
  assert.equal(s.body.pickupFirstName, 'Ada');
  assert.equal(s.body.pickupLastName, 'Lovelace');
  assert.equal(s.body.dropoffFirstName, 'Fulton');
  assert.equal(s.body.deliveryMode, 'now');
  assert.equal(s.body.externalId, undefined, 'a price check is never tied to a leg');
  // Cheapest offer that actually succeeded; the failed $9 one is ignored.
  assert.equal(q.quoteId, 'b');
  assert.equal(q.feeCents, 1150);
  assert.equal(q.expiresAt, '2026-11-18T15:10:00.000Z');
});

test('no courier can take it: the quote is unavailable, with the reason', async () => {
  const { impl } = fakeFetch([
    { status: 200, body: { id: 'ord_q', quotes: [], failedQuotes: [{ providerName: 'X', errorMessage: 'too heavy' }] } },
  ]);
  const q = await provider(impl).quote(REQ);
  assert.match(q.unavailableReason ?? '', /too heavy/);
});

test('a window an hour out is booked as scheduled', async () => {
  const { impl, seen } = fakeFetch([{ status: 200, body: { quotes: [quote('a', 1000)] } }]);
  await provider(impl).quote({
    ...REQ,
    pickupReadyAt: new Date(NOW + 2 * 3600_000).toISOString(),
    pickupDeadlineAt: new Date(NOW + 4 * 3600_000).toISOString(),
  });
  assert.equal(seen[0].body.deliveryMode, 'scheduled');
  assert.equal(seen[0].body.pickupStartTime, '2026-11-18T17:00:00Z');
  assert.equal(seen[0].body.pickupEndTime, '2026-11-18T19:00:00Z');
});

test('create: order under the leg id, cheapest quote selected, job read back', async () => {
  const { impl, seen } = fakeFetch([
    { status: 404, body: { error: { code: 'NOT_FOUND', message: 'no job' } } },
    { status: 200, body: { id: 'ord_1', status: 'valid', quotes: [quote('q_hi', 1600), quote('q_lo', 1150)] } },
    { status: 200, body: { job: JOB('assigned_driver') } },
  ]);
  const st = await provider(impl).createDelivery({ ...REQ, externalId: 'leg-1', orderReference: 'CR7' });
  assert.equal(seen[0].url, 'https://api.sandbox.usenash.com/v1/jobs/external_identifier/leg-1');
  assert.equal(seen[1].url, 'https://api.sandbox.usenash.com/v1/order/external-identifier/leg-1');
  assert.equal(seen[1].body.externalId, 'leg-1');
  assert.equal(seen[1].body.referenceId, 'CR7');
  assert.equal(seen[2].url, 'https://api.sandbox.usenash.com/v1/select_quote');
  assert.deepEqual(seen[2].body, { quoteId: 'q_lo' });
  assert.equal(st.providerDeliveryId, 'job_1');
  assert.equal(st.status, 'courier_assigned');
  assert.equal(st.feeCents, 1150);
  assert.equal(st.trackingUrl, 'https://tracking.sandbox.usenash.com/ord_1');
  assert.equal(st.courier?.vehicle, 'Grey Toyota Sienna');
  assert.equal(st.courier?.phone, '+16505550001', 'before pickup: the pickup-side number');
});

test('a replayed create finds the existing job and books nothing', async () => {
  const { impl, seen } = fakeFetch([{ status: 200, body: JOB('pickup_complete') }]);
  const st = await provider(impl).createDelivery({ ...REQ, externalId: 'leg-1' });
  assert.equal(seen.length, 1);
  assert.equal(st.status, 'picked_up');
  assert.equal(st.courier?.phone, '+16505550002', 'after pickup: the dropoff-side number');
  assert.equal(st.pickedUpAt, '2026-11-18T14:50:00.000Z');
});

test('an order Nash flags as needing attention fails loudly, not silently', async () => {
  const { impl } = fakeFetch([
    { status: 404, body: {} },
    { status: 200, body: { id: 'ord_1', status: 'needs_attention', validationErrors: [{ message: 'invalid dropoff address' }] } },
  ]);
  await assert.rejects(provider(impl).createDelivery({ ...REQ, externalId: 'leg-1' }), (e: any) =>
    e instanceof DeliveryProviderError && !e.opts.retryable && /invalid dropoff address/.test(e.message),
  );
});

test('an upsert without quotes refreshes them once before giving up', async () => {
  const { impl, seen } = fakeFetch([
    { status: 404, body: {} },
    { status: 200, body: { id: 'ord_1', status: 'valid', quotes: [] } },
    { status: 200, body: { id: 'ord_1', quotes: [quote('q', 1200)] } },
    { status: 200, body: { job: JOB('created') } },
  ]);
  await provider(impl).createDelivery({ ...REQ, externalId: 'leg-1' });
  assert.equal(seen[2].url, 'https://api.sandbox.usenash.com/v1/order/refresh_quotes');
  assert.deepEqual(seen[2].body, { orderId: 'ord_1' });
  assert.deepEqual(seen[3].body, { quoteId: 'q' });
});

test('the newest task decides the status, not the reassigned one', async () => {
  const { impl } = fakeFetch([{ status: 200, body: JOB('dropoff_complete') }]);
  const st = await provider(impl).getDelivery('job_1');
  assert.equal(st.status, 'delivered');
});

test('status mapping covers returns, cancels and failures', async () => {
  for (const [nash, ours] of [
    ['return_in_progress', 'at_dropoff'],
    ['returned', 'returned'],
    ['canceled_by_provider', 'cancelled'],
    ['expired', 'failed'],
    ['FAILED', 'failed'],
  ]) {
    const { impl } = fakeFetch([{ status: 200, body: JOB(nash) }]);
    assert.equal((await provider(impl).getDelivery('job_1')).status, ours, nash);
  }
});

test('cancel goes through the external id', async () => {
  const { impl, seen } = fakeFetch([
    { status: 200, body: JOB('assigned_driver') },
    { status: 200, body: JOB('canceled_by_customer') },
  ]);
  const st = await provider(impl).cancelDelivery('job_1');
  assert.equal(seen[1].method, 'POST');
  assert.equal(seen[1].url, 'https://api.sandbox.usenash.com/v1/jobs/external_identifier/leg-1/cancel');
  assert.equal(st.status, 'cancelled');
});

test('cancel reads the job out of Nash\'s { job } wrapper', async () => {
  const { impl } = fakeFetch([
    { status: 200, body: JOB('assigned_driver') },
    { status: 200, body: { job: JOB('canceled_by_customer') } },
  ]);
  assert.equal((await provider(impl).cancelDelivery('job_1')).status, 'cancelled');
});

test('a cancel answer without the job re-reads it instead of trusting the old copy', async () => {
  const { impl, seen } = fakeFetch([
    { status: 200, body: JOB('assigned_driver') },
    { status: 200, body: {} },
    { status: 200, body: JOB('canceled_by_customer') },
  ]);
  const st = await provider(impl).cancelDelivery('job_1');
  assert.equal(seen.length, 3);
  assert.equal(seen[2].method, 'GET');
  assert.equal(st.status, 'cancelled');
});

test('retry classes: network and 5xx retry, 4xx does not', async () => {
  const net = fakeFetch([new TypeError('socket hang up')]);
  await assert.rejects(provider(net.impl).getDelivery('job_1'), (e: any) => e.opts.retryable === true);
  const five = fakeFetch([{ status: 503, body: {} }]);
  await assert.rejects(provider(five.impl).getDelivery('job_1'), (e: any) => e.opts.retryable === true);
  const four = fakeFetch([{ status: 422, body: [{ error: { code: 'VALIDATION_ERRORS', message: 'bad phone' } }] }]);
  await assert.rejects(provider(four.impl).getDelivery('job_1'), (e: any) =>
    e.opts.retryable === false && e.opts.providerCode === 'VALIDATION_ERRORS' && /bad phone/.test(e.message),
  );
});

test('ids that could escape the path are refused before any call', async () => {
  const { impl, seen } = fakeFetch([]);
  await assert.rejects(provider(impl).getDelivery('../order'));
  assert.equal(seen.length, 0);
});

function signed(body: unknown, opts: { ts?: number; secret?: Buffer; id?: string } = {}) {
  const raw = Buffer.from(JSON.stringify(body));
  const id = opts.id ?? 'msg_abc';
  const ts = String(opts.ts ?? NOW / 1000);
  const sig = createHmac('sha256', opts.secret ?? SECRET_BYTES).update(`${id}.${ts}.`).update(raw).digest('base64');
  return {
    headers: { 'svix-id': id, 'svix-timestamp': ts, 'svix-signature': `v1,bogus v1,${sig}` },
    rawBody: raw,
  };
}

test('a correctly signed delivery webhook maps to a leg event', async () => {
  const { impl } = fakeFetch([]);
  const r = await provider(impl).handleWebhook(
    signed({ type: 'delivery', event: 'pickup_complete', data: JOB('pickup_complete') }),
  );
  assert.equal(r.signatureValid, true);
  assert.equal(r.event?.status, 'picked_up');
  assert.equal(r.event?.externalId, 'leg-1');
  assert.equal(r.event?.providerDeliveryId, 'job_1');
  assert.equal(r.event?.eventId, 'msg_abc');
});

test('forged, stale or unsigned webhooks are rejected', async () => {
  const { impl } = fakeFetch([]);
  const p = provider(impl);
  const body = { type: 'delivery', event: 'dropoff_complete', data: JOB('dropoff_complete') };
  assert.equal((await p.handleWebhook(signed(body, { secret: Buffer.from('wrong') }))).signatureValid, false);
  assert.equal((await p.handleWebhook(signed(body, { ts: NOW / 1000 - 600 }))).signatureValid, false);
  const tampered = signed(body);
  tampered.rawBody = Buffer.from(JSON.stringify({ ...body, event: 'returned' }));
  assert.equal((await p.handleWebhook(tampered)).signatureValid, false);
  assert.equal((await p.handleWebhook({ headers: {}, rawBody: Buffer.from('{}') })).signatureValid, false);
  const noSecret = provider(impl, { webhookSecret: undefined });
  assert.equal((await noSecret.handleWebhook(signed(body))).signatureValid, false);
});

test('non-delivery webhooks are acknowledged and ignored', async () => {
  const { impl } = fakeFetch([]);
  const r = await provider(impl).handleWebhook(signed({ type: 'courier_location', event: 'updated', data: {} }));
  assert.equal(r.signatureValid, true);
  assert.equal(r.event, undefined);
  assert.ok(r.ignored);
});

test('only the API key is needed to be configured', () => {
  const { impl } = fakeFetch([]);
  assert.equal(provider(impl).isConfigured(), true);
  assert.equal(provider(impl, { apiKey: undefined }).isConfigured(), false);
});
