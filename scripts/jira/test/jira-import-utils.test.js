import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, mkdtempSync, rmSync } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';
import {
  getHeadingId,
  planItemIdFromIssueId,
  summaryWithPlanId,
  updateDevPlanWithJiraLinks,
} from '../jira-import.js';

describe('getHeadingId', () => {
  it('parses EPIC heading', () => {
    assert.equal(getHeadingId('## EPIC: My Epic Title'), 'EPIC');
  });

  it('parses numbered EPIC heading', () => {
    assert.equal(getHeadingId('## EPIC-1: My Epic Title'), 'EPIC-1');
  });

  it('parses STORY heading', () => {
    assert.equal(getHeadingId('## STORY 1: User Authentication'), 'STORY-1');
  });

  it('parses STORY with multi-digit number', () => {
    assert.equal(getHeadingId('## STORY 12: Advanced Feature'), 'STORY-12');
  });

  it('parses TASK heading', () => {
    assert.equal(getHeadingId('### TASK 1.1: Create Schema'), 'TASK-1.1');
  });

  it('parses TASK with deep nesting', () => {
    assert.equal(getHeadingId('### TASK 2.3: Implement API'), 'TASK-2.3');
  });

  it('parses SUBTASK heading (#### format)', () => {
    assert.equal(getHeadingId('#### SUBTASK 1.1.1: Write Migration'), 'SUBTASK-1.1.1');
  });

  it('parses SUBTASK heading (### format)', () => {
    assert.equal(getHeadingId('### SUBTASK 1.1.1: Write Migration'), 'SUBTASK-1.1.1');
  });

  it('parses SUBTASK with hyphen format', () => {
    assert.equal(getHeadingId('### SUBTASK-1.2.3: Some task'), 'SUBTASK-1.2.3');
  });

  it('returns null for non-heading lines', () => {
    assert.equal(getHeadingId('This is just a paragraph'), null);
  });

  it('returns null for empty string', () => {
    assert.equal(getHeadingId(''), null);
  });

  it('returns null for plain markdown heading', () => {
    assert.equal(getHeadingId('## Some Random Heading'), null);
  });

  it('returns null for heading without colon', () => {
    assert.equal(getHeadingId('## STORY 1 Missing Colon'), null);
  });
});

describe('planItemIdFromIssueId', () => {
  it('returns "1" for EPIC', () => {
    assert.equal(planItemIdFromIssueId('EPIC'), '1');
  });

  it('returns number for EPIC-N format', () => {
    assert.equal(planItemIdFromIssueId('EPIC-2'), '2');
  });

  it('returns story number for STORY-N', () => {
    assert.equal(planItemIdFromIssueId('STORY-1'), '1');
  });

  it('returns task number for TASK-N.N', () => {
    assert.equal(planItemIdFromIssueId('TASK-1.1'), '1.1');
  });

  it('returns subtask number for SUBTASK-N.N.N', () => {
    assert.equal(planItemIdFromIssueId('SUBTASK-1.1.1'), '1.1.1');
  });

  it('returns empty string for null', () => {
    assert.equal(planItemIdFromIssueId(null), '');
  });

  it('returns empty string for empty string', () => {
    assert.equal(planItemIdFromIssueId(''), '');
  });

  it('returns empty string for unrecognized format', () => {
    assert.equal(planItemIdFromIssueId('UNKNOWN-1'), '');
  });
});

describe('summaryWithPlanId', () => {
  it('prepends plan id to summary', () => {
    assert.equal(summaryWithPlanId('TASK-1.1', 'Create Schema'), '1.1 Create Schema');
  });

  it('prepends plan id for STORY', () => {
    assert.equal(summaryWithPlanId('STORY-2', 'User Auth'), '2 User Auth');
  });

  it('prepends plan id for SUBTASK', () => {
    assert.equal(summaryWithPlanId('SUBTASK-1.1.1', 'Write Migration'), '1.1.1 Write Migration');
  });

  it('skips if summary already starts with plan id', () => {
    assert.equal(summaryWithPlanId('TASK-1.1', '1.1 Create Schema'), '1.1 Create Schema');
  });

  it('skips if summary starts with plan id followed by dot', () => {
    assert.equal(summaryWithPlanId('TASK-1.1', '1.1. Create Schema'), '1.1. Create Schema');
  });

  it('returns summary unchanged when issueId is null', () => {
    assert.equal(summaryWithPlanId(null, 'Some summary'), 'Some summary');
  });

  it('returns summary unchanged when issueId has no plan id', () => {
    assert.equal(summaryWithPlanId('UNKNOWN', 'Some summary'), 'Some summary');
  });

  it('returns summary unchanged when summary is null', () => {
    assert.equal(summaryWithPlanId('TASK-1.1', null), null);
  });

  it('returns summary unchanged when summary is empty', () => {
    assert.equal(summaryWithPlanId('TASK-1.1', ''), '');
  });
});

describe('updateDevPlanWithJiraLinks', () => {
  let tempDir;

  function writeTempFile(content) {
    const filePath = join(tempDir, 'test-plan.md');
    writeFileSync(filePath, content, 'utf8');
    return filePath;
  }

  function readTempFile(filePath) {
    return readFileSync(filePath, 'utf8');
  }

  it('inserts JIRA link after EPIC heading', () => {
    tempDir = mkdtempSync(join(tmpdir(), 'jira-test-'));
    const content = '## EPIC: My Epic\n\nSome description';
    const createdIssues = new Map([['EPIC', 'MVP-100']]);
    const filePath = writeTempFile(content);

    updateDevPlanWithJiraLinks(filePath, content, createdIssues, 'https://test.atlassian.net');

    const result = readTempFile(filePath);
    assert.ok(result.includes('**JIRA:** [MVP-100](https://test.atlassian.net/browse/MVP-100)'));
    rmSync(tempDir, { recursive: true });
  });

  it('inserts JIRA link after STORY heading', () => {
    tempDir = mkdtempSync(join(tmpdir(), 'jira-test-'));
    const content = '## STORY 1: User Auth\n\nDescription here';
    const createdIssues = new Map([['STORY-1', 'MVP-101']]);
    const filePath = writeTempFile(content);

    updateDevPlanWithJiraLinks(filePath, content, createdIssues, 'https://test.atlassian.net');

    const result = readTempFile(filePath);
    assert.ok(result.includes('**JIRA:** [MVP-101](https://test.atlassian.net/browse/MVP-101)'));
    rmSync(tempDir, { recursive: true });
  });

  it('inserts JIRA link after TASK heading', () => {
    tempDir = mkdtempSync(join(tmpdir(), 'jira-test-'));
    const content = '### TASK 1.1: Create Schema\n\nTask details';
    const createdIssues = new Map([['TASK-1.1', 'MVP-102']]);
    const filePath = writeTempFile(content);

    updateDevPlanWithJiraLinks(filePath, content, createdIssues, 'https://test.atlassian.net');

    const result = readTempFile(filePath);
    assert.ok(result.includes('**JIRA:** [MVP-102](https://test.atlassian.net/browse/MVP-102)'));
    rmSync(tempDir, { recursive: true });
  });

  it('replaces existing JIRA link line', () => {
    tempDir = mkdtempSync(join(tmpdir(), 'jira-test-'));
    const content = '## STORY 1: User Auth\n**JIRA:** [OLD-1](https://old.atlassian.net/browse/OLD-1)\n\nDescription';
    const createdIssues = new Map([['STORY-1', 'MVP-200']]);
    const filePath = writeTempFile(content);

    updateDevPlanWithJiraLinks(filePath, content, createdIssues, 'https://test.atlassian.net');

    const result = readTempFile(filePath);
    assert.ok(result.includes('**JIRA:** [MVP-200](https://test.atlassian.net/browse/MVP-200)'));
    assert.ok(!result.includes('OLD-1'));
    rmSync(tempDir, { recursive: true });
  });

  it('leaves non-matched headings untouched', () => {
    tempDir = mkdtempSync(join(tmpdir(), 'jira-test-'));
    const content = '## STORY 1: Auth\n\n## STORY 2: Dashboard\n\nDesc';
    const createdIssues = new Map([['STORY-1', 'MVP-101']]);
    const filePath = writeTempFile(content);

    updateDevPlanWithJiraLinks(filePath, content, createdIssues, 'https://test.atlassian.net');

    const result = readTempFile(filePath);
    assert.ok(result.includes('**JIRA:** [MVP-101]'));
    // STORY 2 should remain without a JIRA link
    const lines = result.split('\n');
    const story2Index = lines.findIndex(l => l.includes('STORY 2'));
    assert.ok(story2Index >= 0);
    assert.ok(!lines[story2Index + 1]?.includes('**JIRA:**'));
    rmSync(tempDir, { recursive: true });
  });

  it('strips trailing slash from JIRA base URL', () => {
    tempDir = mkdtempSync(join(tmpdir(), 'jira-test-'));
    const content = '## EPIC: Test\n\nDesc';
    const createdIssues = new Map([['EPIC', 'MVP-100']]);
    const filePath = writeTempFile(content);

    updateDevPlanWithJiraLinks(filePath, content, createdIssues, 'https://test.atlassian.net/');

    const result = readTempFile(filePath);
    assert.ok(result.includes('https://test.atlassian.net/browse/MVP-100'));
    assert.ok(!result.includes('//browse'));
    rmSync(tempDir, { recursive: true });
  });
});
