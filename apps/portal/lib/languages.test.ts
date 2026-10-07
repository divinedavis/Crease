import { test } from 'node:test';
import assert from 'node:assert/strict';
import { NOTE_LANGUAGES, noteLanguage } from './languages.ts';

test('only listed languages are accepted', () => {
  assert.equal(noteLanguage('ko'), 'ko');
  assert.equal(noteLanguage(' zh-Hans '), 'zh-Hans');
  assert.equal(noteLanguage('klingon'), null);
  assert.equal(noteLanguage(''), null);
  assert.equal(noteLanguage(undefined), null);
});

test('every code satisfies the database check in migration 0049', () => {
  for (const { code } of NOTE_LANGUAGES) {
    assert.match(code, /^[a-z]{2}(-[A-Za-z]{2,4})?$/, code);
  }
});
