import { strict as assert } from 'node:assert';
import { test } from 'node:test';
import { isIOS } from './useragent.ts';

// Real strings. Made-up user-agents test the regex, not the world.
const IPHONE =
  'Mozilla/5.0 (iPhone; CPU iPhone OS 18_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.1 Mobile/15E148 Safari/604.1';
const IPAD_NATIVE =
  'Mozilla/5.0 (iPad; CPU OS 18_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.1 Mobile/15E148 Safari/604.1';
const IPAD_DESKTOP_MODE =
  'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.1 Safari/605.1.15 Mobile/15E148';
const MAC_SAFARI =
  'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.1 Safari/605.1.15';
const ANDROID =
  'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36';
const WINDOWS =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

test('an iPhone is an iPhone', () => {
  assert.equal(isIOS(IPHONE), true);
});

test('an iPad that says so is an iPad', () => {
  assert.equal(isIOS(IPAD_NATIVE), true);
});

test('an iPad pretending to be a Mac is still an iPad', () => {
  // The default since iPadOS 13. Missing this sends every iPad the web flow
  // forever and the mistake never shows up in a log.
  assert.equal(isIOS(IPAD_DESKTOP_MODE), true);
});

test('a Mac is not an iPad', () => {
  // The other half of the same trap: matching "Macintosh" alone would send
  // every desktop Safari visitor to the App Store.
  assert.equal(isIOS(MAC_SAFARI), false);
});

test('Android and Windows are not iOS', () => {
  assert.equal(isIOS(ANDROID), false);
  assert.equal(isIOS(WINDOWS), false);
});

test('a missing user-agent is not iOS', () => {
  assert.equal(isIOS(''), false);
});
