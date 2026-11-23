import { strict as assert } from 'node:assert';
import { test } from 'node:test';
import {
  isInviteCode,
  joinPathFromCookie,
  normalizeInviteCode,
  normalizeUsPhone,
  parseJoinForm,
  splitProspectAddress,
} from './join.ts';

const form = (entries: Record<string, string>) => (name: string) =>
  name in entries ? entries[name] : null;

const good = {
  name: 'Jane Laundromat',
  phone: '(718) 555-0142',
  line1: '203 Bond St',
  city: 'Brooklyn',
  state: 'ny',
  postal_code: '11217',
  price_per_lb: '$1.25',
  minimum_lbs: '10',
  turnaround_hours: '24',
};

test('invite codes are exactly 12 upper-case hex characters', () => {
  assert.equal(isInviteCode('A1B2C3D4E5F6'), true);
  assert.equal(isInviteCode('a1b2c3d4e5f6'), false);
  assert.equal(isInviteCode('A1B2C3D4E5F'), false);
  assert.equal(isInviteCode('A1B2C3D4E5FG'), false);
  assert.equal(normalizeInviteCode(' a1b2c3d4e5f6 '), 'A1B2C3D4E5F6');
  assert.equal(normalizeInviteCode('../../evil'), null);
});

test('the join cookie only ever becomes a /join/<code> path', () => {
  assert.equal(joinPathFromCookie('A1B2C3D4E5F6'), '/join/A1B2C3D4E5F6');
  assert.equal(joinPathFromCookie('https://evil.example/'), null);
  assert.equal(joinPathFromCookie('//evil.example'), null);
  assert.equal(joinPathFromCookie(undefined), null);
  assert.equal(joinPathFromCookie(''), null);
});

test('US phone numbers normalise to +1 and ten digits', () => {
  assert.equal(normalizeUsPhone('(718) 555-0142'), '+17185550142');
  assert.equal(normalizeUsPhone('1-718-555-0142'), '+17185550142');
  assert.equal(normalizeUsPhone('555-0142'), null);
  assert.equal(normalizeUsPhone('011 718 555 0142'), null);
  assert.equal(normalizeUsPhone('118 555 0142'), null);
});

test('a complete form parses into what claim_shop_invite takes', () => {
  const parsed = parseJoinForm(form(good));
  assert.ok('form' in parsed);
  assert.deepEqual(parsed.form, {
    name: 'Jane Laundromat',
    phone: '+17185550142',
    line1: '203 Bond St',
    city: 'Brooklyn',
    state: 'NY',
    postal_code: '11217',
    price_cents_per_lb: 125,
    minimum_lbs: 10,
    turnaround_hours: 24,
  });
});

test('minimum and ready time default when left blank', () => {
  const parsed = parseJoinForm(form({ ...good, minimum_lbs: '', turnaround_hours: '' }));
  assert.ok('form' in parsed);
  assert.equal(parsed.form.minimum_lbs, 0);
  assert.equal(parsed.form.turnaround_hours, 24);
});

test('each bad field gets a sentence the counter can act on', () => {
  const cases: [Partial<typeof good>, RegExp][] = [
    [{ name: '' }, /name/],
    [{ phone: '12' }, /phone/],
    [{ line1: '' }, /street/],
    [{ state: 'New York' }, /two letters/],
    [{ postal_code: '1121' }, /ZIP/],
    [{ price_per_lb: '0.10' }, /\$0\.50/],
    [{ price_per_lb: 'abc' }, /Price/],
    [{ minimum_lbs: '80' }, /Minimum/],
    [{ turnaround_hours: '1.5' }, /whole number/],
  ];
  for (const [patch, message] of cases) {
    const parsed = parseJoinForm(form({ ...good, ...patch } as Record<string, string>));
    assert.ok('error' in parsed, JSON.stringify(patch));
    assert.match(parsed.error, message);
  }
});

test('the canvass address splits into street and city', () => {
  assert.deepEqual(splitProspectAddress('203 Bond St, Brooklyn'), { line1: '203 Bond St', city: 'Brooklyn' });
  assert.deepEqual(splitProspectAddress('203 Bond St'), { line1: '203 Bond St', city: 'Brooklyn' });
  assert.deepEqual(splitProspectAddress(null), { line1: '', city: 'Brooklyn' });
});
