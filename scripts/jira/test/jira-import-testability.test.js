import { describe, it } from 'node:test';
import assert from 'node:assert/strict';

describe('jira-import.js testability', () => {
  it('can be imported without side effects', async () => {
    // If the module has side effects (CLI parsing, API calls, process.exit),
    // this import will fail or hang.
    const mod = await import('../jira-import.js');
    assert.ok(mod, 'Module imported successfully');
  });

  it('exports MarkdownParser as a class', async () => {
    const { MarkdownParser } = await import('../jira-import.js');
    assert.equal(typeof MarkdownParser, 'function');
  });

  it('exports getHeadingId as a function', async () => {
    const { getHeadingId } = await import('../jira-import.js');
    assert.equal(typeof getHeadingId, 'function');
  });

  it('exports planItemIdFromIssueId as a function', async () => {
    const { planItemIdFromIssueId } = await import('../jira-import.js');
    assert.equal(typeof planItemIdFromIssueId, 'function');
  });

  it('exports summaryWithPlanId as a function', async () => {
    const { summaryWithPlanId } = await import('../jira-import.js');
    assert.equal(typeof summaryWithPlanId, 'function');
  });

  it('exports updateDevPlanWithJiraLinks as a function', async () => {
    const { updateDevPlanWithJiraLinks } = await import('../jira-import.js');
    assert.equal(typeof updateDevPlanWithJiraLinks, 'function');
  });
});
