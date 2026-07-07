import { describe, it, beforeEach, afterEach, mock } from 'node:test';
import assert from 'node:assert/strict';
import { JiraClient } from '../lib/jira-client.js';

const TEST_CONFIG = {
  apiUrl: 'https://test.atlassian.net',
  email: 'test@example.com',
  apiToken: 'secret-token-123',
};

const expectedAuth = Buffer.from(`${TEST_CONFIG.email}:${TEST_CONFIG.apiToken}`).toString('base64');

function mockFetch(status, body, options = {}) {
  const { ok = status >= 200 && status < 300 } = options;
  return mock.fn(() =>
    Promise.resolve({
      ok,
      status,
      json: () => Promise.resolve(body),
      text: () => Promise.resolve(typeof body === 'string' ? body : JSON.stringify(body)),
    })
  );
}

describe('JiraClient', () => {
  let originalFetch;

  beforeEach(() => {
    originalFetch = globalThis.fetch;
  });

  afterEach(() => {
    globalThis.fetch = originalFetch;
  });

  describe('constructor', () => {
    it('sets baseUrl from config', () => {
      const client = new JiraClient(TEST_CONFIG);
      assert.equal(client.baseUrl, 'https://test.atlassian.net/rest/api/3');
    });

    it('does not expose base64 auth via JSON.stringify', () => {
      const client = new JiraClient(TEST_CONFIG);
      const json = JSON.stringify(client);
      assert.ok(!json.includes(expectedAuth), 'Base64 auth string leaked via JSON.stringify');
    });

    it('does not expose auth via Object.keys', () => {
      const client = new JiraClient(TEST_CONFIG);
      const keys = Object.keys(client);
      assert.ok(!keys.includes('#auth'), 'Private field visible in Object.keys');
    });
  });

  describe('makeRequest', () => {
    it('sends correct authorization header', async () => {
      globalThis.fetch = mockFetch(200, { ok: true });
      const client = new JiraClient(TEST_CONFIG);
      await client.makeRequest('GET', '/test');

      const call = globalThis.fetch.mock.calls[0];
      const [url, opts] = call.arguments;
      assert.equal(url, 'https://test.atlassian.net/rest/api/3/test');
      assert.equal(opts.headers['Authorization'], `Basic ${expectedAuth}`);
    });

    it('sends JSON body for POST', async () => {
      globalThis.fetch = mockFetch(200, { id: 1 });
      const client = new JiraClient(TEST_CONFIG);
      await client.makeRequest('POST', '/issue', { fields: { summary: 'Test' } });

      const [, opts] = globalThis.fetch.mock.calls[0].arguments;
      assert.equal(opts.method, 'POST');
      assert.equal(opts.body, JSON.stringify({ fields: { summary: 'Test' } }));
    });

    it('does not send body for GET', async () => {
      globalThis.fetch = mockFetch(200, {});
      const client = new JiraClient(TEST_CONFIG);
      await client.makeRequest('GET', '/issue/TEST-1');

      const [, opts] = globalThis.fetch.mock.calls[0].arguments;
      assert.equal(opts.body, undefined);
    });

    it('returns null for 204 No Content', async () => {
      globalThis.fetch = mockFetch(204, null, { ok: true });
      const client = new JiraClient(TEST_CONFIG);
      const result = await client.makeRequest('DELETE', '/issue/TEST-1');
      assert.equal(result, null);
    });

    it('redacts auth from error messages', async () => {
      globalThis.fetch = mockFetch(401, `Unauthorized: Basic ${expectedAuth}`, { ok: false });
      const client = new JiraClient(TEST_CONFIG);

      await assert.rejects(
        () => client.makeRequest('GET', '/test'),
        (err) => {
          assert.ok(!err.message.includes(expectedAuth), 'Auth leaked in error');
          assert.ok(err.message.includes('[REDACTED]'));
          assert.ok(err.message.includes('401'));
          return true;
        }
      );
    });
  });

  describe('createIssue', () => {
    it('posts to /issue endpoint', async () => {
      globalThis.fetch = mockFetch(201, { key: 'TEST-1' });
      const client = new JiraClient(TEST_CONFIG);
      const result = await client.createIssue({ fields: { summary: 'New issue' } });

      assert.equal(result.key, 'TEST-1');
      const [url, opts] = globalThis.fetch.mock.calls[0].arguments;
      assert.ok(url.endsWith('/issue'));
      assert.equal(opts.method, 'POST');
    });
  });

  describe('getIssue', () => {
    it('fetches issue by key', async () => {
      globalThis.fetch = mockFetch(200, { key: 'TEST-1', fields: { summary: 'Test' } });
      const client = new JiraClient(TEST_CONFIG);
      const result = await client.getIssue('TEST-1');

      assert.equal(result.key, 'TEST-1');
      const [url] = globalThis.fetch.mock.calls[0].arguments;
      assert.ok(url.endsWith('/issue/TEST-1'));
    });
  });

  describe('deleteIssue', () => {
    it('sends DELETE request', async () => {
      globalThis.fetch = mockFetch(204, null, { ok: true });
      const client = new JiraClient(TEST_CONFIG);
      await client.deleteIssue('TEST-1');

      const [url, opts] = globalThis.fetch.mock.calls[0].arguments;
      assert.ok(url.endsWith('/issue/TEST-1'));
      assert.equal(opts.method, 'DELETE');
    });
  });

  describe('getTransitions', () => {
    it('returns transitions array', async () => {
      globalThis.fetch = mockFetch(200, {
        transitions: [
          { id: '1', name: 'In Progress' },
          { id: '2', name: 'Done' },
        ],
      });
      const client = new JiraClient(TEST_CONFIG);
      const result = await client.getTransitions('TEST-1');

      assert.equal(result.length, 2);
      assert.equal(result[0].name, 'In Progress');
      const [url] = globalThis.fetch.mock.calls[0].arguments;
      assert.ok(url.endsWith('/issue/TEST-1/transitions'));
    });

    it('returns empty array when no transitions', async () => {
      globalThis.fetch = mockFetch(200, {});
      const client = new JiraClient(TEST_CONFIG);
      const result = await client.getTransitions('TEST-1');
      assert.deepEqual(result, []);
    });
  });

  describe('transitionIssue', () => {
    it('posts transition with correct body', async () => {
      globalThis.fetch = mockFetch(204, null, { ok: true });
      const client = new JiraClient(TEST_CONFIG);
      await client.transitionIssue('TEST-1', '42');

      const [url, opts] = globalThis.fetch.mock.calls[0].arguments;
      assert.ok(url.endsWith('/issue/TEST-1/transitions'));
      assert.equal(opts.method, 'POST');
      assert.deepEqual(JSON.parse(opts.body), { transition: { id: '42' } });
    });
  });

  describe('addComment', () => {
    it('posts comment to issue', async () => {
      globalThis.fetch = mockFetch(201, { id: '100' });
      const client = new JiraClient(TEST_CONFIG);
      const commentBody = { body: { type: 'doc', version: 1, content: [] } };
      const result = await client.addComment('TEST-1', commentBody);

      assert.equal(result.id, '100');
      const [url, opts] = globalThis.fetch.mock.calls[0].arguments;
      assert.ok(url.endsWith('/issue/TEST-1/comment'));
      assert.equal(opts.method, 'POST');
      assert.deepEqual(JSON.parse(opts.body), commentBody);
    });
  });

  describe('searchIssuesByLabel', () => {
    it('searches with JQL label query', async () => {
      globalThis.fetch = mockFetch(200, {
        issues: [{ key: 'TEST-1' }, { key: 'TEST-2' }],
      });
      const client = new JiraClient(TEST_CONFIG);
      const result = await client.searchIssuesByLabel('import-batch-abc');

      assert.equal(result.length, 2);
      const [url] = globalThis.fetch.mock.calls[0].arguments;
      assert.ok(url.includes('jql='));
      assert.ok(url.includes('import-batch-abc'));
    });

    it('returns empty array when no issues found', async () => {
      globalThis.fetch = mockFetch(200, {});
      const client = new JiraClient(TEST_CONFIG);
      const result = await client.searchIssuesByLabel('nonexistent');
      assert.deepEqual(result, []);
    });
  });

  describe('getUserByEmail', () => {
    it('returns accountId for found user', async () => {
      globalThis.fetch = mockFetch(200, [{ accountId: 'abc123' }]);
      const client = new JiraClient(TEST_CONFIG);
      const result = await client.getUserByEmail('user@example.com');
      assert.equal(result, 'abc123');
    });

    it('caches user lookups', async () => {
      globalThis.fetch = mockFetch(200, [{ accountId: 'abc123' }]);
      const client = new JiraClient(TEST_CONFIG);

      await client.getUserByEmail('user@example.com');
      await client.getUserByEmail('user@example.com');

      assert.equal(globalThis.fetch.mock.calls.length, 1);
    });

    it('returns null for unknown user', async () => {
      globalThis.fetch = mockFetch(200, []);
      const client = new JiraClient(TEST_CONFIG);
      const result = await client.getUserByEmail('nobody@example.com');
      assert.equal(result, null);
    });

    it('returns null on API error', async () => {
      globalThis.fetch = mockFetch(500, 'Internal error', { ok: false });
      const client = new JiraClient(TEST_CONFIG);
      const result = await client.getUserByEmail('user@example.com');
      assert.equal(result, null);
    });
  });

  describe('getAuthForRedaction', () => {
    it('returns the base64 auth string', () => {
      const client = new JiraClient(TEST_CONFIG);
      assert.equal(client.getAuthForRedaction(), expectedAuth);
    });
  });
});
