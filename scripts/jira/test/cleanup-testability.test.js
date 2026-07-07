import { describe, it } from 'node:test';
import assert from 'node:assert/strict';

describe('cleanup-import.js testability', () => {
  it('can be imported without side effects', async () => {
    // If the module has side effects (env reads, API calls, process.exit),
    // this import will fail or hang.
    const mod = await import('../cleanup-import.js');
    assert.ok(mod, 'Module imported successfully');
  });

  it('exports deleteByBatch as a function', async () => {
    const { deleteByBatch } = await import('../cleanup-import.js');
    assert.equal(typeof deleteByBatch, 'function');
  });

  it('exports deleteByFile as a function', async () => {
    const { deleteByFile } = await import('../cleanup-import.js');
    assert.equal(typeof deleteByFile, 'function');
  });

  it('exports listImports as a function', async () => {
    const { listImports } = await import('../cleanup-import.js');
    assert.equal(typeof listImports, 'function');
  });
});
