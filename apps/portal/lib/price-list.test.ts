import { strict as assert } from 'node:assert';
import { test } from 'node:test';
import { codeFor, parseDollars, parseServiceItemForm, priceLine } from './price-list.ts';

function form(entries: Record<string, string>) {
  return (name: string) => (name in entries ? entries[name] : null);
}

const laundry = {
  label: 'Wash & fold',
  service_type: 'wash_fold',
  unit: 'pound',
  price: '2.00',
  minimum: '10',
  active: 'on',
};

test('a per-pound laundry rate with a minimum parses to cents and pounds', () => {
  const result = parseServiceItemForm(form(laundry));
  assert.ok('item' in result);
  assert.equal(result.item.unit_price_cents, 200);
  assert.equal(result.item.minimum_units, 10);
  assert.equal(result.item.active, true);
  assert.equal(result.item.turnaround_hours, null);
});

test('dollars are read the way people type them', () => {
  assert.equal(parseDollars('2'), 200);
  assert.equal(parseDollars('$2.5'), 250);
  assert.equal(parseDollars(' 34.99 '), 3499);
  assert.equal(parseDollars('2.999'), null);
  assert.equal(parseDollars('two'), null);
  assert.equal(parseDollars('-2'), null);
});

test('a free service is refused, not saved', () => {
  const result = parseServiceItemForm(form({ ...laundry, price: '0' }));
  assert.ok('error' in result);
});

test('an extra zero is caught', () => {
  const result = parseServiceItemForm(form({ ...laundry, price: '2000' }));
  assert.ok('error' in result);
});

test('dry cleaning cannot be priced by the pound', () => {
  const result = parseServiceItemForm(form({ ...laundry, service_type: 'dry_clean' }));
  assert.ok('error' in result);
});

test('a per-item line carries no weight minimum even if one was typed', () => {
  const result = parseServiceItemForm(
    form({ label: 'Comforter', service_type: 'wash_fold', unit: 'piece', price: '30', minimum: '10' }),
  );
  assert.ok('item' in result);
  assert.equal(result.item.minimum_units, 0);
  assert.equal(result.item.active, false, 'unticked means not offered');
});

test('turnaround must be inside the column check', () => {
  assert.ok('error' in parseServiceItemForm(form({ ...laundry, turnaround_hours: '0' })));
  assert.ok('error' in parseServiceItemForm(form({ ...laundry, turnaround_hours: '400' })));
  const ok = parseServiceItemForm(form({ ...laundry, turnaround_hours: '24' }));
  assert.ok('item' in ok && ok.item.turnaround_hours === 24);
});

test('an unknown service type is refused', () => {
  assert.ok('error' in parseServiceItemForm(form({ ...laundry, service_type: 'tailoring' })));
});

test('codes are unique per shop across service types', () => {
  assert.equal(codeFor('Wash & Fold', 'wash_fold', []), 'wash_fold_wash_fold');
  assert.equal(codeFor('Wash & Fold', 'wash_fold', ['wash_fold_wash_fold']), 'wash_fold_wash_fold_2');
  assert.equal(codeFor('!!!', 'press', []), 'press_item');
});

test('the price line reads the way the app shows it', () => {
  assert.equal(priceLine({ unit: 'pound', unit_price_cents: 200, minimum_units: '10.00' }), '$2.00 / lb · 10 lb minimum');
  assert.equal(priceLine({ unit: 'piece', unit_price_cents: 3499, minimum_units: 0 }), '$34.99 each');
});
