import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { parseTimeEstimate } from '../lib/parse-utils.js';

describe('parseTimeEstimate', () => {
  it('parses "8 hours" to "8h"', () => {
    assert.equal(parseTimeEstimate('8 hours'), '8h');
  });

  it('parses "2 days" to "2d"', () => {
    assert.equal(parseTimeEstimate('2 days'), '2d');
  });

  it('parses "30 minutes" to "30m"', () => {
    assert.equal(parseTimeEstimate('30 minutes'), '30m');
  });

  it('parses "1 week" to "1w"', () => {
    assert.equal(parseTimeEstimate('1 week'), '1w');
  });

  it('parses "~4 hours" (approximation) to "4h"', () => {
    assert.equal(parseTimeEstimate('~4 hours'), '4h');
  });

  it('parses "2-3 days" (range) to "2d" (lower bound)', () => {
    assert.equal(parseTimeEstimate('2-3 days'), '2d');
  });

  it('parses "1 hour" (singular) to "1h"', () => {
    assert.equal(parseTimeEstimate('1 hour'), '1h');
  });

  it('parses "1 day" (singular) to "1d"', () => {
    assert.equal(parseTimeEstimate('1 day'), '1d');
  });

  it('parses "1 minute" (singular) to "1m"', () => {
    assert.equal(parseTimeEstimate('1 minute'), '1m');
  });

  it('returns null for null input', () => {
    assert.equal(parseTimeEstimate(null), null);
  });

  it('returns null for undefined input', () => {
    assert.equal(parseTimeEstimate(undefined), null);
  });

  it('returns null for empty string', () => {
    assert.equal(parseTimeEstimate(''), null);
  });

  it('returns null for unrecognized format', () => {
    assert.equal(parseTimeEstimate('ASAP'), null);
  });
});
