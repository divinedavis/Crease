import { strict as assert } from 'node:assert';
import { createHmac } from 'node:crypto';
import { test } from 'node:test';
import { DoorDashDriveProvider, e164 } from './doordashDrive.js';
import { DeliveryProviderError } from './types.js';
import type { CreateDeliveryRequest, QuoteRequest } from './types.js';

const NOW = Date.parse('2026-11-18T15:00:00Z');
const SECRET = Buffer.from('a-signing-secret-of-some-length!').toString('base64');
const HOOK_AUTH = 'Basic dGVzdDpzZWNyZXQ=';

interface Seen {
  method: string;
  url: string;
  headers: Record<string, string>;
  body: any;
}

/** A fetch that records each call and answers from a queue. */
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
    return new Response(next.body === undefined ? '' : JSON.stringify(next.body), {
      status: next.status,
    });
  }) as unknown as typeof fetch;
  return { impl, seen };
}

function provider(fetchImpl: typeof fetch, extra: Partial<ConstructorParameters<typeof DoorDashDriveProvider>[0]> = {}) {
  return new DoorDashDriveProvider({
    developerId: 'dev-123',
    keyId: 'key-456',
    signingSecret: SECRET,
    webhookAuth: HOOK_AUTH,
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
    notes: 'Buzzer 4B',
    verification: 'signature',
  },
  dropoff: {
    name: 'Fulton Cleaners',
    phone: '7185550199',
    address: '909 Fulton St, Brooklyn, NY 11238',
    lat: 40.68,
    lng: -73.96,
    verification: 'signature',
  },
  manifest: { description: 'Garment bag', declaredValueCents: 20_000, itemCount: 1, requiresCar: true },
};

const DELIVERY = {
  external_delivery_id: 'leg-1',
  delivery_status: 'confirmed',
  fee: 975,
  currency: 'USD',
  tracking_url: 'https://doordash.com/drive/portal/track/abc',
  dasher_name: 'Sam D.',
  dasher_pickup_phone_number: '+16505550001',
  dasher_dropoff_phone_number: '+16505550002',
  dasher_location: { lat: 40.7, lng: -73.9 },
  dasher_vehicle_make: 'Honda',
  dasher_vehicle_model: 'Civic',
};

test('signs an HS256 JWT DoorDash will accept', async () => {
  const { impl, seen } = fakeFetch([{ status: 200, body: { external_delivery_id: 'q', fee: 975 } }]);
  await provider(impl).quote(REQ);
  const token = seen[0].headers.authorization.replace(/^Bearer /, '');
  const [head, claims, sig] = token.split('.');
  assert.deepEqual(JSON.parse(Buffer.from(head, 'base64url').toString()), {
    alg: 'HS256',
    typ: 'JWT',
    'dd-ver': 'DD-JWT-V1',
  });
  const c = JSON.parse(Buffer.from(claims, 'base64url').toString());
  assert.equal(c.aud, 'doordash');
  assert.equal(c.iss, 'dev-123');
  assert.equal(c.kid, 'key-456');
  assert.equal(c.exp - c.iat, 300);
  const expected = createHmac('sha256', Buffer.from(SECRET, 'base64'))
    .update(`${head}.${claims}`)
    .digest('base64url');
  assert.equal(sig, expected);
});

test('quote maps the route and returns the fee in cents', async () => {
  const { impl, seen } = fakeFetch([
    { status: 200, body: { external_delivery_id: 'crease-quote-x', fee: 975, currency: 'USD' } },
  ]);
  const q = await provider(impl).quote(REQ);
  assert.equal(seen[0].method, 'POST');
  assert.equal(seen[0].url, 'https://openapi.doordash.com/drive/v2/quotes');
  const b = seen[0].body;
  assert.match(b.external_delivery_id, /^crease-quote-/);
  assert.equal(b.pickup_phone_number, '+17185550142');
  assert.equal(b.dropoff_phone_number, '+17185550199');
  assert.deepEqual(b.dasher_allowed_vehicles, ['car']);
  assert.equal(b.order_value, 20_000);
  assert.deepEqual(b.dropoff_location, { lat: 40.68, lng: -73.96 });
  assert.equal(b.pickup_time, undefined, 'no window = on demand');
  assert.equal(q.feeCents, 975);
  assert.equal(q.currency, 'usd');
  assert.equal(q.unavailableReason, undefined);
  assert.equal(Date.parse(q.expiresAt) - NOW, 5 * 60 * 1000);
});

test('a window an hour or more out is sent as a scheduled pickup', async () => {
  const { impl, seen } = fakeFetch([{ status: 200, body: { external_delivery_id: 'q', fee: 975 } }]);
  const ready = new Date(NOW + 3 * 3600_000).toISOString();
  await provider(impl).quote({ ...REQ, pickupReadyAt: ready });
  assert.equal(seen[0].body.pickup_time, ready);
});

test('a quote with no usable fee is unavailable, not bookable', async () => {
  const { impl } = fakeFetch([{ status: 200, body: { external_delivery_id: 'q' } }]);
  const q = await provider(impl).quote(REQ);
  assert.ok(q.unavailableReason);
});

test('create sends the leg id, return-to-pickup and signature', async () => {
  const { impl, seen } = fakeFetch([{ status: 200, body: DELIVERY }]);
  const req: CreateDeliveryRequest = { ...REQ, externalId: 'leg-1', orderReference: 'CR-42' };
  const state = await provider(impl).createDelivery(req);
  const b = seen[0].body;
  assert.equal(seen[0].url, 'https://openapi.doordash.com/drive/v2/deliveries');
  assert.equal(b.external_delivery_id, 'leg-1');
  assert.equal(b.action_if_undeliverable, 'return_to_pickup');
  assert.equal(b.contactless_dropoff, false);
  assert.equal(b.dropoff_requires_signature, true);
  assert.equal(b.dropoff_contact_given_name, 'Fulton');
  assert.equal(b.dropoff_contact_family_name, 'Cleaners');
  assert.equal(b.pickup_reference_tag, 'CR-42');
  assert.equal(state.providerDeliveryId, 'leg-1');
  assert.equal(state.status, 'courier_assigned');
  assert.equal(state.feeCents, 975);
  assert.equal(state.courier?.vehicle, 'Honda Civic');
  // Before pickup the customer-facing number is the pickup-side one.
  assert.equal(state.courier?.phone, '+16505550001');
});

test('a replayed create (409) reads the existing delivery back', async () => {
  const { impl, seen } = fakeFetch([
    { status: 409, body: { code: 'duplicate_delivery_id', message: 'exists' } },
    { status: 200, body: { ...DELIVERY, delivery_status: 'picked_up' } },
  ]);
  const state = await provider(impl).createDelivery({ ...REQ, externalId: 'leg-1' });
  assert.equal(seen[1].method, 'GET');
  assert.equal(seen[1].url, 'https://openapi.doordash.com/drive/v2/deliveries/leg-1');
  assert.equal(state.status, 'picked_up');
  // After pickup the customer-facing number is the dropoff-side one.
  assert.equal(state.courier?.phone, '+16505550002');
});

test('network failure is retryable; a 400 is not and names the field', async () => {
  const net = fakeFetch([new TypeError('socket hang up')]);
  await assert.rejects(provider(net.impl).createDelivery({ ...REQ, externalId: 'leg-1' }), (e: any) => {
    return e instanceof DeliveryProviderError && e.opts.retryable === true;
  });
  const bad = fakeFetch([
    {
      status: 400,
      body: {
        code: 'validation_error',
        message: 'Validation Failed',
        field_errors: [{ field: 'dropoff_phone_number', error: 'Invalid phone number' }],
      },
    },
  ]);
  await assert.rejects(provider(bad.impl).createDelivery({ ...REQ, externalId: 'leg-1' }), (e: any) => {
    return e.opts.retryable === false && /dropoff_phone_number/.test(e.message);
  });
});

test('a 401 re-signs once and retries', async () => {
  const { impl, seen } = fakeFetch([
    { status: 401, body: { message: 'expired' } },
    { status: 200, body: DELIVERY },
  ]);
  await provider(impl).getDelivery('leg-1');
  assert.equal(seen.length, 2);
});

test('cancel uses PUT on the leg id', async () => {
  const { impl, seen } = fakeFetch([{ status: 200, body: { ...DELIVERY, delivery_status: 'cancelled' } }]);
  const state = await provider(impl).cancelDelivery('leg-1');
  assert.equal(seen[0].method, 'PUT');
  assert.equal(seen[0].url, 'https://openapi.doordash.com/drive/v2/deliveries/leg-1/cancel');
  assert.equal(state.status, 'cancelled');
});

test('ids that could escape the path are refused before any call', async () => {
  const { impl, seen } = fakeFetch([]);
  await assert.rejects(provider(impl).getDelivery('../quotes'));
  assert.equal(seen.length, 0);
});

const hook = (body: unknown, auth?: string) => ({
  headers: auth ? { authorization: auth } : {},
  rawBody: Buffer.from(JSON.stringify(body)),
});

test('webhooks without the configured Authorization header are rejected', async () => {
  const { impl, seen } = fakeFetch([]);
  const p = provider(impl);
  const body = { event_name: 'DASHER_PICKED_UP', external_delivery_id: 'leg-1' };
  assert.equal((await p.handleWebhook(hook(body))).signatureValid, false);
  assert.equal((await p.handleWebhook(hook(body, 'Basic wrong'))).signatureValid, false);
  const open = provider(impl, { webhookAuth: undefined });
  assert.equal((await open.handleWebhook(hook(body, HOOK_AUTH))).signatureValid, false);
  assert.equal(seen.length, 0);
});

test('an authenticated webhook takes its state from the API, not the payload', async () => {
  const { impl, seen } = fakeFetch([{ status: 200, body: { ...DELIVERY, delivery_status: 'picked_up' } }]);
  const body = {
    event_name: 'DASHER_DROPPED_OFF', // the payload claims more than is true
    external_delivery_id: 'leg-1',
    created_at: '2026-11-18T15:00:00Z',
  };
  const r = await provider(impl).handleWebhook(hook(body, HOOK_AUTH));
  assert.equal(r.signatureValid, true);
  assert.equal(seen[0].url, 'https://openapi.doordash.com/drive/v2/deliveries/leg-1');
  assert.equal(r.event?.status, 'picked_up');
  assert.equal(r.event?.externalId, 'leg-1');
  assert.equal(r.event?.eventId, 'leg-1:DASHER_DROPPED_OFF:2026-11-18T15:00:00Z');
});

test('when DoorDash cannot be reached the event name decides the state', async () => {
  const { impl } = fakeFetch([new TypeError('down'), new TypeError('down')]);
  const body = { event_name: 'DASHER_PICKED_UP', external_delivery_id: 'leg-1', created_at: 't' };
  const r = await provider(impl).handleWebhook(hook(body, HOOK_AUTH));
  assert.equal(r.event?.status, 'picked_up');
});

test('unknown events are acknowledged and ignored', async () => {
  const { impl, seen } = fakeFetch([]);
  const r = await provider(impl).handleWebhook(
    hook({ event_name: 'DELIVERY_BATCHED', external_delivery_id: 'leg-1' }, HOOK_AUTH),
  );
  assert.equal(r.signatureValid, true);
  assert.equal(r.event, undefined);
  assert.ok(r.ignored);
  assert.equal(seen.length, 0);
});

test('implausible values from DoorDash are dropped, not stored', async () => {
  const { impl } = fakeFetch([
    {
      status: 200,
      body: {
        ...DELIVERY,
        fee: 9_999_999,
        tracking_url: 'javascript:alert(1)',
        dropoff_time_actual: '2020-01-01T00:00:00Z',
      },
    },
  ]);
  const s = await provider(impl).getDelivery('leg-1');
  assert.equal(s.feeCents, undefined);
  assert.equal(s.trackingUrl, undefined);
  assert.equal(s.completedAt, undefined);
});

test('isConfigured needs all three credentials', () => {
  const { impl } = fakeFetch([]);
  assert.equal(provider(impl).isConfigured(), true);
  assert.equal(provider(impl, { keyId: undefined }).isConfigured(), false);
});

test('e164 handles the formats Crease stores', () => {
  assert.equal(e164('(718) 555-0142'), '+17185550142');
  assert.equal(e164('1-718-555-0142'), '+17185550142');
  assert.equal(e164('+1 717 659 9140'), '+17176599140');
  assert.equal(e164('555-0142'), undefined);
  assert.equal(e164(undefined), undefined);
});
