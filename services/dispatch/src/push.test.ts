import { strict as assert } from 'node:assert';
import { createVerify, generateKeyPairSync } from 'node:crypto';
import { test } from 'node:test';

// Imported late and behind these: config refuses to load without the service's
// own credentials, and signing a JWT is not a reason to need a database.
process.env.SUPABASE_URL ??= 'http://localhost:54321';
process.env.SUPABASE_SERVICE_ROLE_KEY ??= 'test';
process.env.SUPABASE_ANON_KEY ??= 'test';
process.env.INTERNAL_API_KEY ??= 'test';
const { apnsJwt } = await import('./push.js');

const { privateKey, publicKey } = generateKeyPairSync('ec', { namedCurve: 'P-256' });

test('the provider token carries the key id and the team', () => {
  const jwt = apnsJwt(privateKey, 'ABCD123456', 'TEAM123456', 1_754_400_000_000);
  const [header, payload, signature] = jwt.split('.');

  assert.deepEqual(JSON.parse(Buffer.from(header, 'base64url').toString()), {
    alg: 'ES256',
    kid: 'ABCD123456',
  });
  assert.deepEqual(JSON.parse(Buffer.from(payload, 'base64url').toString()), {
    iss: 'TEAM123456',
    iat: 1_754_400_000,
  });
  assert.ok(signature.length > 0);
});

test('the signature is the raw r||s pair APNs accepts, not DER', () => {
  // The whole failure mode: a DER signature is a valid ECDSA signature that
  // Apple rejects as 403 InvalidProviderToken, with nothing in the response to
  // say why. DER is variable-length and starts 0x30; P-1363 is always 64 bytes.
  const jwt = apnsJwt(privateKey, 'ABCD123456', 'TEAM123456');
  const [header, payload, signature] = jwt.split('.');
  const raw = Buffer.from(signature, 'base64url');

  assert.equal(raw.length, 64);
  assert.ok(
    createVerify('sha256')
      .update(`${header}.${payload}`)
      .verify({ key: publicKey, dsaEncoding: 'ieee-p1363' }, raw),
  );
});
