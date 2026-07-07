import { describe, it, beforeEach, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { loadEnvJira } from '../lib/env.js';

describe('loadEnvJira', () => {
  const originalEnv = {};

  beforeEach(() => {
    // Save and clear JIRA env vars
    for (const key of ['JIRA_API_URL', 'JIRA_EMAIL', 'JIRA_API_TOKEN', 'JIRA_PROJECT_KEY']) {
      originalEnv[key] = process.env[key];
      delete process.env[key];
    }
  });

  afterEach(() => {
    // Restore original env vars
    for (const [key, value] of Object.entries(originalEnv)) {
      if (value === undefined) {
        delete process.env[key];
      } else {
        process.env[key] = value;
      }
    }
  });

  it('exports loadEnvJira as a function', () => {
    assert.equal(typeof loadEnvJira, 'function');
  });

  it('does not throw when .env.jira does not exist', () => {
    assert.doesNotThrow(() => loadEnvJira());
  });

  it('skips loading when all JIRA env vars are already set', () => {
    process.env.JIRA_API_URL = 'https://test.atlassian.net';
    process.env.JIRA_EMAIL = 'test@test.com';
    process.env.JIRA_API_TOKEN = 'token123';
    // Should return early without error
    assert.doesNotThrow(() => loadEnvJira());
    // Values should remain unchanged
    assert.equal(process.env.JIRA_API_URL, 'https://test.atlassian.net');
  });
});
