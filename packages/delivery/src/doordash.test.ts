import { strict as assert } from 'node:assert';
import { createHmac } from 'node:crypto';
import { test } from 'node:test';
import { DoorDashDriveProvider, e164 } from './doordashDrive.js';
import { DeliveryProviderError, type CreateDeliveryRequest } from './types.js';

const SECRET = Buffer.from('signing-secret-bytes').toString('base64url');

interface Call {
  method: string;
  url: string;
  headers: Record<string, string>;
  body?: any;
}

/** A fetch that records each call and answers from a script, in order. */
function scripted(...answers: Array<{ status: number; body?: unknown } | Error>) {
  const calls: Call[] = [];
  const fetchImpl = (async (url: string, init: RequestInit) => {
    calls.push({
      method: String(init.method),
      url,
      headers: init.headers as Record<string, string>,
      body: init.body ? JSON.parse(String(init.body)) : undefined,
    });
    const a = answers.shift();
    if (!a) throw new Error('unscripted call');
    if (a instanceof Error) throw a;
    return new Response(a.body === undefined ? '' : JSON.stringify(a.body), { status: a.status });
  }) as unknown as typeof fetch;
  return { calls, fetchImpl };
}

function provider(fetchImpl: typeof fetch, extra: Record<string, string> = {}) {
  return new DoorDashDriveProvider({
    developerId: 'dev_1',
    keyId: 'key_1',
    signingSecret: SECRET,
    webhookSecret: 'Basic d2ViaG9vaw==',
    apiBase: 'https://dd.test/drive/v2',
    fetchImpl,
    ...extra,
  });
}

const REQ: CreateDeliveryRequest = {
  externalId: 'leg_123',
  pickup: {
    name: 'Ada',
    phone: '(718) 555-0100',
    address: '1 Main St, Brooklyn, NY 11201',
    lat: 40.7,
    lng: -73.99,
    verification: 'signature',
  },
  dropoff: { name: 'Sparkle Cleaners', phone: '+1 212 555 0199', address: '9 Court St, Brooklyn, NY' },
  manifest: { description: 'Garment bag', declaredValueCents: 20_000, itemCount: 3, requiresCar: true },
  pickupReadyAt: new Date(Date.now() + 60_000).toISOString(),
  pickupDeadlineAt: new Date(Date.now() + 3_600_000).toISOString(),
};

test('unconfigured until all three credentials are present', () => {
  assert.equal(new DoorDashDriveProvider({}).isConfigured(), false);
  assert.equal(new DoorDashDriveProvider({ developerId: 'd', keyId: 'k' }).isConfigured(), false);
  assert.equal(provider(fetch).isConfigured(), true);
});

test('every call carries a valid DD-JWT-V1 signed with the decoded secret', async () => {
  const { calls, fetchImpl } = scripted({ status: 200, body: { fee: 975, currency: 'USD' } });
  await provider(fetchImpl).quote(REQ);
  const jwt = calls[0]!.headers.authorization!.replace(/^Bearer /, '');
  const [h, p, sig] = jwt.split('.');
  const header = JSON.parse(Buffer.from(h!, 'base64url').toString());
  const payload = JSON.parse(Buffer.from(p!, 'base64url').toString());
  assert.deepEqual(header, { alg: 'HS256', typ: 'JWT', 'dd-ver': 'DD-JWT-V1' });
  assert.equal(payload.aud, 'doordash');
  assert.equal(payload.iss, 'dev_1');
  assert.equal(payload.kid, 'key_1');
  assert.ok(payload.exp > payload.iat && payload.exp - payload.iat <= 1800);
  const expected = createHmac('sha256', Buffer.from(SECRET, 'base64url'))
    .update(`${h}.${p}`)
    .digest('base64url');
  assert.equal(sig, expected);
});

test('quote maps the fee and never spends the leg id', async () => {
  const { calls, fetchImpl } = scripted({ status: 200, body: { fee: 975, currency: 'USD' } });
  const q = await provider(fetchImpl).quote(REQ);
  assert.equal(calls[0]!.method, 'POST');
  assert.equal(calls[0]!.url, 'https://dd.test/drive/v2/quotes');
  assert.match(calls[0]!.body.external_delivery_id, /^crease-q-/);
  assert.equal(q.quoteId, calls[0]!.body.external_delivery_id);
  assert.equal(q.feeCents, 975);
  assert.equal(q.currency, 'usd');
  assert.equal(q.unavailableReason, undefined);
  assert.ok(Date.parse(q.expiresAt) > Date.now());
});

test('a 200 quote with no fee, or an absurd one, is unavailable rather than bookable', async () => {
  const { fetchImpl } = scripted({ status: 200, body: {} }, { status: 200, body: { fee: 9_999_999 } });
  const p = provider(fetchImpl);
  assert.equal((await p.quote(REQ)).unavailableReason, 'quote carried no fee');
  assert.match((await p.quote(REQ)).unavailableReason ?? '', /implausible fee/);
});

test('create sends the garment-safe body under the leg id', async () => {
  const { calls, fetchImpl } = scripted({
    status: 200,
    body: { external_delivery_id: 'leg_123', delivery_status: 'created', fee: 975, tracking_url: 'https://t' },
  });
  const state = await provider(fetchImpl).createDelivery(REQ);
  const b = calls[0]!.body;
  assert.equal(calls[0]!.url, 'https://dd.test/drive/v2/deliveries');
  assert.equal(b.external_delivery_id, 'leg_123');
  assert.equal(b.pickup_phone_number, '+17185550100');
  assert.equal(b.dropoff_phone_number, '+12125550199');
  assert.equal(b.contactless_dropoff, false);
  assert.equal(b.action_if_undeliverable, 'return_to_pickup');
  assert.equal(b.dropoff_requires_signature, true);
  assert.deepEqual(b.dasher_allowed_vehicles, ['car']);
  assert.deepEqual(b.pickup_location, { lat: 40.7, lng: -73.99 });
  assert.equal(b.order_value, 20_000);
  assert.equal(state.providerDeliveryId, 'leg_123');
  assert.equal(state.status, 'dispatching');
  assert.equal(state.feeCents, 975);
});

test('a replayed create (409) reads back the original instead of failing the leg', async () => {
  const { calls, fetchImpl } = scripted(
    { status: 409, body: { code: 'duplicate_delivery_id', message: 'exists' } },
    { status: 200, body: { external_delivery_id: 'leg_123', delivery_status: 'confirmed', dasher_name: 'Sam' } },
  );
  const state = await provider(fetchImpl).createDelivery(REQ);
  assert.equal(calls[1]!.method, 'GET');
  assert.equal(calls[1]!.url, 'https://dd.test/drive/v2/deliveries/leg_123');
  assert.equal(state.status, 'courier_assigned');
  assert.equal(state.courier?.name, 'Sam');
});

test('network failures and 5xx are retryable; validation errors are not and name the field', async () => {
  const { fetchImpl } = scripted(
    new TypeError('socket hang up'),
    { status: 503, body: { message: 'busy' } },
    { status: 400, body: { code: 'validation_error', message: 'Bad', field_errors: [{ field: 'dropoff_phone_number', error: 'invalid' }] } },
  );
  const p = provider(fetchImpl);
  for (const retryable of [true, true, false]) {
    await assert.rejects(p.quote(REQ), (err: unknown) => {
      assert.ok(err instanceof DeliveryProviderError);
      assert.equal(err.opts.retryable, retryable);
      if (!retryable) assert.match(err.message, /dropoff_phone_number: invalid/);
      return true;
    });
  }
});

test('cancel uses PUT on the leg id', async () => {
  const { calls, fetchImpl } = scripted({
    status: 200,
    body: { external_delivery_id: 'leg_123', delivery_status: 'cancelled', cancellation_reason: 'customer' },
  });
  const state = await provider(fetchImpl).cancelDelivery('leg_123');
  assert.equal(calls[0]!.method, 'PUT');
  assert.equal(calls[0]!.url, 'https://dd.test/drive/v2/deliveries/leg_123/cancel');
  assert.equal(state.status, 'cancelled');
  assert.equal(state.error, 'customer');
});

test('implausible timestamps and fees from DoorDash are dropped, not stored', async () => {
  const { fetchImpl } = scripted({
    status: 200,
    body: {
      external_delivery_id: 'leg_123',
      delivery_status: 'delivered',
      fee: -5,
      pickup_time_actual: '2020-01-01T00:00:00Z',
      dropoff_time_actual: 'not a date',
    },
  });
  const s = await provider(fetchImpl).getDelivery('leg_123');
  assert.equal(s.status, 'delivered');
  assert.equal(s.feeCents, undefined);
  assert.equal(s.pickedUpAt, undefined);
  assert.equal(s.completedAt, undefined);
});

function hook(body: unknown, auth?: string) {
  return {
    headers: auth === undefined ? {} : { authorization: auth },
    rawBody: Buffer.from(JSON.stringify(body)),
  };
}

test('webhooks are refused without the configured Authorization header', async () => {
  const p = provider(fetch);
  const body = { event_name: 'DASHER_PICKED_UP', external_delivery_id: 'leg_123' };
  assert.equal((await p.handleWebhook(hook(body))).signatureValid, false);
  assert.equal((await p.handleWebhook(hook(body, 'Basic wrong'))).signatureValid, false);
  const noSecret = provider(fetch, { webhookSecret: '' });
  assert.equal((await noSecret.handleWebhook(hook(body, ''))).signatureValid, false);
});

test('a webhook maps to our status with a stable id for dedupe', async () => {
  const p = provider(fetch);
  const body = {
    event_name: 'DASHER_PICKED_UP',
    external_delivery_id: 'leg_123',
    created_at: '2026-11-18T15:00:00Z',
    dasher_name: 'Sam',
    dasher_location: { lat: 40.7, lng: -73.9 },
  };
  const a = await p.handleWebhook(hook(body, 'Basic d2ViaG9vaw=='));
  const b = await p.handleWebhook(hook(body, 'Basic d2ViaG9vaw=='));
  assert.equal(a.signatureValid, true);
  assert.equal(a.event?.status, 'picked_up');
  assert.equal(a.event?.providerDeliveryId, 'leg_123');
  assert.equal(a.event?.courier?.lat, 40.7);
  assert.equal(a.event?.eventId, b.event?.eventId);
  assert.ok(a.event?.eventId);
});

test('delivery_status wins over the event name; unknown events are ignored', async () => {
  const p = provider(fetch);
  const withStatus = await p.handleWebhook(
    hook(
      { event_name: 'DASHER_CONFIRMED', delivery_status: 'enroute_to_pickup', external_delivery_id: 'leg_1' },
      'Basic d2ViaG9vaw==',
    ),
  );
  assert.equal(withStatus.event?.status, 'en_route_to_pickup');
  const unknown = await p.handleWebhook(
    hook({ event_name: 'SOMETHING_NEW', external_delivery_id: 'leg_1' }, 'Basic d2ViaG9vaw=='),
  );
  assert.equal(unknown.signatureValid, true);
  assert.equal(unknown.event, undefined);
  assert.match(unknown.ignored ?? '', /SOMETHING_NEW/);
});

test('a return in progress stays live until the garments are back', async () => {
  const p = provider(fetch);
  const r = await p.handleWebhook(
    hook({ event_name: 'DELIVERY_RETURN_INITIALIZED', external_delivery_id: 'leg_1' }, 'Basic d2ViaG9vaw=='),
  );
  assert.equal(r.event?.status, 'en_route_to_dropoff');
  const done = await p.handleWebhook(
    hook({ event_name: 'DELIVERY_RETURNED', external_delivery_id: 'leg_1' }, 'Basic d2ViaG9vaw=='),
  );
  assert.equal(done.event?.status, 'returned');
});

test('e164 normalises US numbers and leaves the rest for DoorDash to judge', () => {
  assert.equal(e164('(718) 555-0100'), '+17185550100');
  assert.equal(e164('1-718-555-0100'), '+17185550100');
  assert.equal(e164('+44 20 7946 0958'), '+442079460958');
  assert.equal(e164('555'), '555');
  assert.equal(e164(undefined), undefined);
});
