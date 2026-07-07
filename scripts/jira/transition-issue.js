#!/usr/bin/env node
/**
 * Transition a JIRA issue to a new status or add a comment.
 * Loads .env.jira from project root if JIRA vars are not set.
 *
 * Usage:
 *   node scripts/jira/transition-issue.js <issueKey> <transitionName>
 *   node scripts/jira/transition-issue.js MVP-123 "In Progress"
 *   node scripts/jira/transition-issue.js MVP-123 Done
 *   node scripts/jira/transition-issue.js MVP-123 comment "Your comment text"
 *   node scripts/jira/transition-issue.js --help
 *
 * Flags:
 *   --help, -h          Show help message
 *
 * Features:
 *   - Automatic retry with exponential backoff
 *   - Better error messages with suggestions
 *   - Auto-loads .env.jira configuration
 *   - Add comments to issues
 */

import { fileURLToPath } from 'url';
import { resolve } from 'path';
import { loadEnvJira } from './lib/env.js';
import { redactAuth } from './lib/redact.js';
import { JiraClient } from './lib/jira-client.js';

/** Show help text */
function showHelp() {
  console.log(`
🔄 JIRA Issue Transition & Comment Tool

Transition a JIRA issue to a new status or add a comment.

USAGE:
  node scripts/jira/transition-issue.js <issueKey> <transitionName>
  node scripts/jira/transition-issue.js <issueKey> comment "<comment text>"

ARGUMENTS:
  issueKey           JIRA issue key (e.g., MVP-123)
  transitionName     Target status (e.g., "In Progress", "Done")
  comment            Add a comment to the issue (use "comment" as second arg)

EXAMPLES:
  # Mark issue as in progress
  node scripts/jira/transition-issue.js MVP-123 "In Progress"

  # Mark issue as done
  node scripts/jira/transition-issue.js MVP-123 Done

  # Add a comment to an issue
  node scripts/jira/transition-issue.js MVP-123 comment "🔗 Pull Request: https://github.com/user/repo/pull/42"

ENVIRONMENT VARIABLES:
  JIRA_API_URL       JIRA instance URL (e.g., https://company.atlassian.net)
  JIRA_EMAIL         Your JIRA email
  JIRA_API_TOKEN     Your JIRA API token

  Set these in .env.jira in the project root.

FEATURES:
  ✅ Automatic retry with exponential backoff
  ✅ Better error messages with suggestions
  ✅ Auto-loads .env.jira configuration
  ✅ Add comments to issues
`);
}

/**
 * Transition an issue to a new status. Idempotent — if already at target, succeeds.
 * @param {JiraClient} client - JIRA API client
 * @param {string} key - Issue key (e.g., MVP-123)
 * @param {string} transitionName - Target status name (e.g., "In Progress", "Done")
 */
async function transition(client, key, transitionName) {
  // Get current issue status
  const issue = await client.getIssue(key);
  const currentStatus = issue.fields.status.name;

  // Get available transitions
  const transitions = await client.getTransitions(key);
  const nameLower = transitionName.toLowerCase();
  const t = transitions.find(
    (x) => x.name.toLowerCase() === nameLower || (x.to && x.to.name && x.to.name.toLowerCase() === nameLower)
  );

  // Already at target status — treat as success (idempotent)
  if (currentStatus.toLowerCase() === nameLower) {
    console.log(`ℹ️  ${key} is already in "${currentStatus}" — no transition needed`);
    return;
  }

  if (!t) {
    const names = transitions.map((x) => x.name || (x.to && x.to.name)).filter(Boolean);

    // Better error message
    console.error(`\n❌ Cannot transition ${key} to "${transitionName}"\n`);
    console.error(`Reason: Transition not available from current status`);
    console.error(`Current status: ${currentStatus}`);
    console.error(`Available transitions: ${names.join(', ') || 'None'}\n`);
    console.error(`Suggestions:`);
    console.error(`  - Check if the issue workflow allows this transition`);
    console.error(`  - Verify the transition name is correct`);
    console.error(`  - You may need to transition through intermediate states\n`);

    throw new Error(`Transition "${transitionName}" not available. Current: ${currentStatus}, Available: ${names.join(', ')}`);
  }

  await client.transitionIssue(key, t.id);
}

async function main() {
  loadEnvJira();

  const apiUrl = process.env.JIRA_API_URL;
  const email = process.env.JIRA_EMAIL;
  const apiToken = process.env.JIRA_API_TOKEN;

  // Check for help flag
  if (process.argv.includes('--help') || process.argv.includes('-h')) {
    showHelp();
    process.exit(0);
  }

  const issueKey = process.argv[2];
  const transitionName = (process.argv[3] || '').trim();

  if (!issueKey || !transitionName) {
    console.error('❌ Error: Missing required arguments\n');
    console.error('Usage: node scripts/jira/transition-issue.js <issueKey> <transitionName>');
    console.error('Example: node scripts/jira/transition-issue.js MVP-123 "In Progress"\n');
    console.error('Run with --help for more information');
    process.exit(1);
  }

  if (!apiUrl || !email || !apiToken) {
    console.error('❌ Missing JIRA environment variables:\n');
    if (!apiUrl) console.error('  - JIRA_API_URL');
    if (!email) console.error('  - JIRA_EMAIL');
    if (!apiToken) console.error('  - JIRA_API_TOKEN');
    console.error('\n💡 Set these in .env.jira in the project root or export them.\n');
    process.exit(1);
  }

  const client = new JiraClient({ apiUrl, email, apiToken });

  try {
    // Check if this is a comment command
    if (transitionName.toLowerCase() === 'comment') {
      const commentText = process.argv.slice(4).join(' ') || process.argv[4];
      if (!commentText) {
        console.error('❌ Error: Comment text is required\n');
        console.error('Usage: node scripts/jira/transition-issue.js <issueKey> comment "Your comment"');
        process.exit(1);
      }
      await client.addComment(issueKey, {
        body: {
          type: 'doc',
          version: 1,
          content: [
            {
              type: 'paragraph',
              content: [
                {
                  type: 'text',
                  text: commentText,
                },
              ],
            },
          ],
        },
      });
      console.log(`✅ ${issueKey} ← comment added`);
    } else {
      await transition(client, issueKey, transitionName);
      console.log(`✅ ${issueKey} → ${transitionName}`);
    }
  } catch (err) {
    console.error(`❌ Failed:`, redactAuth(err.message, client.getAuthForRedaction()));
    process.exit(1);
  }
}

// Run main only when executed directly (not when imported for testing)
const isDirectRun = process.argv[1] && fileURLToPath(import.meta.url) === resolve(process.argv[1]);
if (isDirectRun) {
  main();
}

export { transition, showHelp };
