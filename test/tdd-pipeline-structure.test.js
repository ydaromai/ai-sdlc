/**
 * Structural / integrity tests for the ported TDD pipeline command files.
 *
 * The TDD commands were ported from a private repo into the ai-sdlc bundle.
 * This suite locks in the invariants that porting had to establish and that a
 * future edit could silently break:
 *
 *   1. No leftover absolute/home paths or the old `dev-pipeline` repo name.
 *   2. No dependency on the excluded machine-global `port-manager.sh` / `.ports`.
 *   3. Every bundled reference (`{{AISDLC_ROOT}}/...`) resolves to a real file.
 *   4. Commands that read bundled files carry the "Resolve Root" Setup section.
 *   5. Both orchestrators expose the lights-out (`--unattended`) mode, and the
 *      `tdd-unattended.sh` driver exists and is executable.
 *
 * Run: node --test test/tdd-pipeline-structure.test.js
 */
import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, existsSync, statSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const ROOT = join(__dirname, '..');
const COMMANDS = join(ROOT, 'commands');

// The 13 ported command files (11 tdd-* + the two closure deps).
const PORTED = [
  'tdd-fullpipeline', 'tdd-figma-fullpipeline', 'tdd-design-brief',
  'tdd-figma-analysis', 'tdd-figma-design-system', 'tdd-mock-analysis',
  'tdd-source-analysis', 'tdd-test-plan', 'tdd-develop-tests',
  'tdd-develop-tier2-tests', 'tdd-code-connect', 'execute', 'scaffold',
];

// Commands that read bundled files and therefore must carry the Setup section.
const NEEDS_SETUP = [
  'tdd-fullpipeline', 'tdd-figma-fullpipeline', 'tdd-design-brief',
  'tdd-figma-analysis', 'tdd-mock-analysis', 'tdd-test-plan',
  'tdd-develop-tests', 'tdd-develop-tier2-tests', 'execute',
];

const ORCHESTRATORS = ['tdd-fullpipeline', 'tdd-figma-fullpipeline'];

const SETUP_HEADING = '## Setup — Resolve the ai-sdlc plugin root';

// Pre-flight
assert.ok(existsSync(COMMANDS), `commands/ directory not found: ${COMMANDS}`);

const read = (name) => readFileSync(join(COMMANDS, `${name}.md`), 'utf8');

describe('TDD pipeline port — file presence', () => {
  for (const name of PORTED) {
    it(`commands/${name}.md exists`, () => {
      assert.ok(existsSync(join(COMMANDS, `${name}.md`)), `missing commands/${name}.md`);
    });
  }
});

describe('TDD pipeline port — no leftover private-repo / machine paths', () => {
  for (const name of PORTED) {
    it(`${name}.md has no dev-pipeline / home / absolute paths`, () => {
      const c = read(name);
      assert.ok(!/\/Users\//.test(c), `${name}.md contains an absolute /Users/ path`);
      assert.ok(!/~\/Projects\//.test(c), `${name}.md contains a ~/Projects/ home path`);
      assert.ok(!/dev-pipeline/.test(c), `${name}.md still references "dev-pipeline"`);
    });
    it(`${name}.md has no port-manager / .ports dependency`, () => {
      const c = read(name);
      assert.ok(!/port-manager/.test(c), `${name}.md references the excluded port-manager`);
      assert.ok(!/\.ports\//.test(c), `${name}.md references the excluded .ports registry`);
    });
  }
});

describe('TDD pipeline port — Setup / root-resolution section', () => {
  for (const name of NEEDS_SETUP) {
    it(`${name}.md carries the Resolve-Root Setup section`, () => {
      assert.ok(read(name).includes(SETUP_HEADING), `${name}.md is missing "${SETUP_HEADING}"`);
    });
  }

  // Every {{AISDLC_ROOT}}/... reference must resolve to a real bundled file.
  for (const name of PORTED) {
    it(`${name}.md — all {{AISDLC_ROOT}} references resolve`, () => {
      const c = read(name);
      const re = /\{\{AISDLC_ROOT\}\}\/([A-Za-z0-9._/-]+\.(?:md|sh|py|json|yaml|yml))/g;
      const missing = [];
      let m;
      while ((m = re.exec(c)) !== null) {
        const rel = m[1];
        if (!existsSync(join(ROOT, rel))) missing.push(rel);
      }
      assert.deepEqual(missing, [], `${name}.md references non-existent bundled files: ${missing.join(', ')}`);
    });
  }
});

describe('TDD pipeline — lights-out (dark factory) mode', () => {
  for (const name of ORCHESTRATORS) {
    it(`${name}.md documents the --unattended flag and Unattended Mode`, () => {
      const c = read(name);
      assert.ok(c.includes('--unattended'), `${name}.md does not mention --unattended`);
      assert.ok(/Unattended Mode/.test(c), `${name}.md has no Unattended Mode section`);
      assert.ok(/pipeline_status.*blocked|"blocked"/.test(c), `${name}.md never sets the blocked hard-stop state`);
    });
  }

  it('tdd-unattended.sh driver exists and is executable', () => {
    const driver = join(ROOT, 'pipeline', 'scripts', 'tdd-unattended.sh');
    assert.ok(existsSync(driver), 'pipeline/scripts/tdd-unattended.sh is missing');
    assert.ok((statSync(driver).mode & 0o111) !== 0, 'tdd-unattended.sh is not executable');
  });
});
