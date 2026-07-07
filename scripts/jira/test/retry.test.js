import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { retryWithBackoff, sleep, MAX_RETRIES, RETRY_BASE_DELAY_MS } from '../lib/retry.js';

describe('retry constants', () => {
  it('exports MAX_RETRIES as 3', () => {
    assert.equal(MAX_RETRIES, 3);
  });

  it('exports RETRY_BASE_DELAY_MS as 1000', () => {
    assert.equal(RETRY_BASE_DELAY_MS, 1000);
  });
});

describe('sleep', () => {
  it('resolves after the specified delay', async () => {
    const start = Date.now();
    await sleep(50);
    const elapsed = Date.now() - start;
    assert.ok(elapsed >= 40, `Expected >= 40ms, got ${elapsed}ms`);
  });
});

describe('retryWithBackoff', () => {
  it('succeeds on first try', async () => {
    let calls = 0;
    const result = await retryWithBackoff(async () => {
      calls++;
      return 'ok';
    });
    assert.equal(result, 'ok');
    assert.equal(calls, 1);
  });

  it('retries on 429 error and succeeds', async () => {
    let calls = 0;
    const result = await retryWithBackoff(async () => {
      calls++;
      if (calls === 1) throw new Error('429 Too Many Requests');
      return 'ok';
    }, 3);
    assert.equal(result, 'ok');
    assert.equal(calls, 2);
  });

  it('retries on 503 error and succeeds', async () => {
    let calls = 0;
    const result = await retryWithBackoff(async () => {
      calls++;
      if (calls === 1) throw new Error('503 Service Unavailable');
      return 'ok';
    }, 3);
    assert.equal(result, 'ok');
    assert.equal(calls, 2);
  });

  it('retries on rate limit message and succeeds', async () => {
    let calls = 0;
    const result = await retryWithBackoff(async () => {
      calls++;
      if (calls === 1) throw new Error('rate limit exceeded');
      return 'ok';
    }, 3);
    assert.equal(result, 'ok');
    assert.equal(calls, 2);
  });

  it('throws after max retries exceeded on 429', async () => {
    let calls = 0;
    await assert.rejects(
      () => retryWithBackoff(async () => {
        calls++;
        throw new Error('429 Too Many Requests');
      }, 2),
      { message: '429 Too Many Requests' }
    );
    assert.equal(calls, 2);
  });

  it('does not retry on non-retryable errors', async () => {
    let calls = 0;
    await assert.rejects(
      () => retryWithBackoff(async () => {
        calls++;
        throw new Error('404 Not Found');
      }, 3),
      { message: '404 Not Found' }
    );
    assert.equal(calls, 1);
  });

  it('throws immediately on non-retryable error even with retries left', async () => {
    let calls = 0;
    await assert.rejects(
      () => retryWithBackoff(async () => {
        calls++;
        throw new Error('400 Bad Request');
      }, 3),
      { message: '400 Bad Request' }
    );
    assert.equal(calls, 1);
  });
});
