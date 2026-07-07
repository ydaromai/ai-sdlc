import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { redactAuth } from '../lib/redact.js';

describe('cleanup-import.js redaction integration', () => {
  // These tests verify the redaction pattern used in cleanup-import.js.
  // Since the module currently executes at top level (pre-TASK 3.2 refactor),
  // we test the redaction pattern directly.

  const auth = Buffer.from('admin@test.com:my-secret-token-xyz').toString('base64');

  it('redacts auth from JiraClient.makeRequest error path', () => {
    const errorBody = `{"error":"Unauthorized","details":"Basic ${auth}"}`;
    const errorMsg = `JIRA API error (401): ${redactAuth(errorBody, auth)}`;
    assert.ok(!errorMsg.includes(auth), 'Auth string leaked in makeRequest error');
    assert.ok(errorMsg.includes('[REDACTED]'));
  });

  it('redacts auth from per-issue delete catch block', () => {
    // Simulates: Failed to delete MVP-123: JIRA API error (403): <auth in body>
    const errMessage = `JIRA API error (403): Forbidden with token ${auth}`;
    const output = redactAuth(errMessage, auth);
    assert.ok(!output.includes(auth), 'Auth string leaked in delete catch');
  });

  it('redacts from top-level cleanup catch block', () => {
    const errMessage = `Network error: could not reach https://jira.test/rest?auth=${encodeURIComponent(auth)}`;
    const output = redactAuth(errMessage, auth);
    assert.ok(!output.includes(auth), 'Auth string leaked in top-level catch');
    assert.ok(!output.includes(encodeURIComponent(auth)), 'URL-encoded auth leaked');
  });
});
