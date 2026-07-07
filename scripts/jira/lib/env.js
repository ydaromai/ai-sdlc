/**
 * Shared environment loader for JIRA scripts.
 * Resolves .env.jira relative to the project root (derived from this file's location),
 * NOT from process.cwd(), to avoid breakage when scripts are invoked from a different directory.
 */

import { readFileSync, existsSync } from 'fs';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
// lib/ is inside scripts/jira/, so project root is 3 levels up
const projectRoot = join(__dirname, '..', '..', '..');

/**
 * Load .env.jira from the project root if JIRA vars are not already set.
 * Parses lines like `export KEY=value` and sets them on process.env.
 */
export function loadEnvJira() {
  if (process.env.JIRA_API_URL && process.env.JIRA_EMAIL && process.env.JIRA_API_TOKEN) return;
  const envPath = join(projectRoot, '.env.jira');
  if (!existsSync(envPath)) return;
  try {
    const content = readFileSync(envPath, 'utf8');
    for (const line of content.split('\n')) {
      const m = line.match(/^export\s+([A-Za-z_][A-Za-z0-9_]*)=(.*)$/);
      if (m) process.env[m[1]] = m[2].replace(/^["']|["']$/g, '').trim();
    }
  } catch (_) { /* ignore */ }
}
