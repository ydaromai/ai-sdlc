import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { redactAuth } from '../lib/redact.js';

describe('redactAuth', () => {
  it('redacts a normal Base64 auth string', () => {
    const auth = Buffer.from('user@test.com:token123').toString('base64');
    const text = `Error: API returned 401. Auth: ${auth}`;
    const result = redactAuth(text, auth);
    assert.ok(!result.includes(auth));
    assert.ok(result.includes('[REDACTED]'));
  });

  it('redacts Base64 containing + character', () => {
    // Force a Base64 string with + by using specific input
    const auth = 'dXNlcj8+OnRva2Vu'; // contains special chars when decoded
    const text = `Failed with auth ${auth} in header`;
    const result = redactAuth(text, auth);
    assert.ok(!result.includes(auth));
    assert.ok(result.includes('[REDACTED]'));
  });

  it('redacts Base64 containing / character', () => {
    const auth = 'YS9iL2M6dG9rZW4='; // a/b/c:token in Base64
    const text = `JIRA API error: ${auth}`;
    const result = redactAuth(text, auth);
    assert.ok(!result.includes(auth));
  });

  it('redacts Base64 containing = padding', () => {
    const auth = Buffer.from('short:t').toString('base64'); // will have = padding
    const text = `Error with ${auth} visible`;
    const result = redactAuth(text, auth);
    assert.ok(!result.includes(auth));
    assert.ok(result.includes('[REDACTED]'));
  });

  it('returns text unchanged for empty auth string', () => {
    const text = 'Some error message';
    assert.equal(redactAuth(text, ''), text);
  });

  it('returns text unchanged for null auth string', () => {
    const text = 'Some error message';
    assert.equal(redactAuth(text, null), text);
  });

  it('returns text unchanged for undefined auth string', () => {
    const text = 'Some error message';
    assert.equal(redactAuth(text, undefined), text);
  });

  it('returns text unchanged when auth string is not present', () => {
    const text = 'JIRA API error (404): Not found';
    const result = redactAuth(text, 'some-auth-token');
    assert.equal(result, text);
  });

  it('redacts multiple occurrences', () => {
    const auth = 'secret123';
    const text = `First ${auth} and second ${auth}`;
    const result = redactAuth(text, auth);
    assert.ok(!result.includes(auth));
    assert.equal(result, 'First [REDACTED] and second [REDACTED]');
  });

  it('redacts URL-encoded form of auth string', () => {
    const auth = 'user+name/path=:token+val';
    const encoded = encodeURIComponent(auth);
    const text = `Redirect URL contained ${encoded} in query`;
    const result = redactAuth(text, auth);
    assert.ok(!result.includes(encoded));
    assert.ok(result.includes('[REDACTED]'));
  });

  it('redacts both raw and URL-encoded forms in same text', () => {
    const auth = 'a+b/c=d';
    const encoded = encodeURIComponent(auth);
    const text = `Raw: ${auth}, Encoded: ${encoded}`;
    const result = redactAuth(text, auth);
    assert.ok(!result.includes(auth));
    assert.ok(!result.includes(encoded));
  });

  it('handles non-string text gracefully', () => {
    assert.equal(redactAuth(null, 'auth'), null);
    assert.equal(redactAuth(undefined, 'auth'), undefined);
    assert.equal(redactAuth(123, 'auth'), 123);
  });
});
