import { describe, it } from 'node:test';
import assert from 'node:assert/strict';

describe('transition-issue.js testability', () => {
  it('can be imported without side effects', async () => {
    // If the module has side effects (env reads, API calls, process.exit),
    // this import will fail or hang.
    const mod = await import('../transition-issue.js');
    assert.ok(mod, 'Module imported successfully');
  });

  it('exports transition as a function', async () => {
    const { transition } = await import('../transition-issue.js');
    assert.equal(typeof transition, 'function');
  });

  it('exports showHelp as a function', async () => {
    const { showHelp } = await import('../transition-issue.js');
    assert.equal(typeof showHelp, 'function');
  });
});
