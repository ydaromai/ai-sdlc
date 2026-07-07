import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { redactAuth } from '../lib/redact.js';

describe('transition-issue.js redaction integration', () => {
  // These tests verify the redaction pattern used in transition-issue.js.
  // Since the module currently executes at top level (pre-TASK 3.1 refactor),
  // we test the redaction pattern directly rather than importing the module.
  // After TASK 3.1 makes the module importable, these can be upgraded to
  // actual module import tests.

  const auth = Buffer.from('test@example.com:secret-api-token-123').toString('base64');

  it('redacts auth from getIssue error path', () => {
    // Simulates: JIRA API 401: {"message":"Auth failed","auth":"<auth>"}
    const errorBody = `{"message":"Authentication failed","header":"Basic ${auth}"}`;
    const errorMsg = `JIRA API 401: ${redactAuth(errorBody, auth)}`;
    assert.ok(!errorMsg.includes(auth), 'Auth string leaked in getIssue error');
    assert.ok(errorMsg.includes('[REDACTED]'));
  });

  it('redacts auth from getTransitions error path', () => {
    const errorBody = `Forbidden: token ${auth} is expired`;
    const errorMsg = `JIRA API 403: ${redactAuth(errorBody, auth)}`;
    assert.ok(!errorMsg.includes(auth), 'Auth string leaked in getTransitions error');
  });

  it('redacts auth from transition error path', () => {
    const errorBody = `Server error with credentials ${auth}`;
    const errorMsg = `JIRA API 500: ${redactAuth(errorBody, auth)}`;
    assert.ok(!errorMsg.includes(auth), 'Auth string leaked in transition error');
  });

  it('redacts auth from addComment error path', () => {
    const errorBody = `Not found. Request auth: ${auth}`;
    const errorMsg = `JIRA API 404: ${redactAuth(errorBody, auth)}`;
    assert.ok(!errorMsg.includes(auth), 'Auth string leaked in addComment error');
  });

  it('redacts auth from top-level catch (err.message)', () => {
    // Simulates the catch block: console.error('Failed:', redactAuth(err.message, auth))
    const errMessage = `JIRA API 401: Authorization header contained ${auth}`;
    const output = redactAuth(errMessage, auth);
    assert.ok(!output.includes(auth), 'Auth string leaked in top-level catch');
  });

  it('handles error body with URL-encoded auth', () => {
    const encoded = encodeURIComponent(auth);
    const errorBody = `Redirect to /login?auth=${encoded}`;
    const errorMsg = `JIRA API 302: ${redactAuth(errorBody, auth)}`;
    assert.ok(!errorMsg.includes(encoded), 'URL-encoded auth leaked');
  });
});
