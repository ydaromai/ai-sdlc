import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, mkdtempSync, rmSync } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';
import {
  MarkdownParser,
  getHeadingId,
  summaryWithPlanId,
  updateDevPlanWithJiraLinks,
} from '../jira-import.js';

// ---------------------------------------------------------------------------
// Realistic complex dev plan fixture — 2 stories, 4 tasks, 8 subtasks
// Mimics the hierarchy produced by /prd2plan for a real feature.
// ---------------------------------------------------------------------------
const COMPLEX_DEV_PLAN = `# Dev Plan: Payment Gateway Integration

**PRD:** docs/prd/payment-gateway.md
**Date:** 2026-02-20

## Pipeline Status
- **Stage:** EXECUTING (Stage 4 of 4)
- **Progress:** 0/4 tasks complete

---

## EPIC: Payment Gateway Integration

Integrate Stripe payment gateway with checkout flow, webhook handling, and refund support.

---

## STORY 1: Checkout Flow Integration

Implement the end-to-end checkout flow with Stripe payment intents.

**Time Estimate:** ~8 hours
**Assignee:** alice@example.com

### TASK 1.1: Create payment service module
**Depends On:** None
**Parallel Group:** A
**Complexity:** Medium
**Time Estimate:** 3 hours
**Assignee:** alice@example.com
**Labels:** \`backend\`, \`payments\`

**Description:**
Create the core payment service that wraps the Stripe SDK.

**Implementation:**
1. Create \`lib/payments/stripe-client.js\`
2. Implement \`createPaymentIntent\`, \`confirmPayment\`, \`cancelPayment\`
3. Add retry logic for transient Stripe errors

**Required Tests:**
- **UT:** Test all three methods with mocked Stripe SDK

#### SUBTASK 1.1.1: Create Stripe client wrapper with auth config
**Time Estimate:** 1 hour

#### SUBTASK 1.1.2: Implement createPaymentIntent with currency support
**Time Estimate:** 1 hour

#### SUBTASK 1.1.3: Implement confirmPayment and cancelPayment
**Time Estimate:** 45 minutes

#### SUBTASK 1.1.4: Add retry logic for transient Stripe errors (429, 500)

---

### TASK 1.2: Build checkout API endpoint
**Depends On:** TASK 1.1
**Parallel Group:** B
**Complexity:** Medium
**Time Estimate:** 3 hours
**Assignee:** bob@example.com

**Description:**
Create the POST /api/checkout endpoint that orchestrates payment creation.

**Required Tests:**
- **UT:** Test endpoint handler with mocked payment service
- **IT:** Integration test with Stripe test mode

#### SUBTASK 1.2.1: Create POST /api/checkout route handler
#### SUBTASK 1.2.2: Add input validation (amount, currency, card token)
#### SUBTASK 1.2.3: Wire up payment service and handle errors

---

## STORY 2: Webhook & Refund Handling

Handle Stripe webhooks for payment status updates and implement refund flow.

**Time Estimate:** ~6 hours
**Priority:** High

### TASK 2.1: Implement Stripe webhook handler
**Depends On:** TASK 1.1
**Parallel Group:** B
**Complexity:** Complex
**Time Estimate:** 4 hours

**Description:**
Build the webhook endpoint that receives Stripe events and updates order status.

**Required Tests:**
- **UT:** Test webhook signature verification
- **IT:** Test with Stripe CLI webhook forwarding

#### SUBTASK 2.1.1: Create POST /api/webhooks/stripe endpoint
**Time Estimate:** 1 hour

#### SUBTASK 2.1.2: Implement webhook signature verification
**Time Estimate:** 1 hour

#### SUBTASK 2.1.3: Handle payment_intent.succeeded event
**Time Estimate:** 30 minutes

#### SUBTASK 2.1.4: Handle payment_intent.payment_failed event
**Time Estimate:** 30 minutes

#### SUBTASK 2.1.5: Handle charge.refunded event
**Time Estimate:** 30 minutes

---

### TASK 2.2: Build refund API endpoint
**Depends On:** TASK 2.1
**Parallel Group:** C
**Complexity:** Simple
**Time Estimate:** 2 hours

**Description:**
Create the POST /api/refunds endpoint.

#### SUBTASK 2.2.1: Create POST /api/refunds route handler
#### SUBTASK 2.2.2: Add refund amount validation and partial refund support

---

## Dependency Graph

\`\`\`
Group A: TASK 1.1 (Medium)
Group B: TASK 1.2 (Medium), TASK 2.1 (Complex)
Group C: TASK 2.2 (Simple)
\`\`\`
`;

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

describe('Complex breakdown parsing', () => {

  describe('full hierarchy', () => {
    let data;

    it('parses without error', () => {
      const parser = new MarkdownParser(COMPLEX_DEV_PLAN);
      data = parser.parse();
      assert.ok(data, 'parse() should return a truthy object');
    });

    it('extracts the Epic', () => {
      assert.ok(data.epic, 'epic should exist');
      assert.equal(data.epic.summary, 'Payment Gateway Integration');
      assert.ok(data.epic.description.includes('Stripe payment gateway'));
    });

    it('extracts all stories', () => {
      assert.equal(data.stories.length, 2);
      assert.equal(data.stories[0].id, 'STORY-1');
      assert.equal(data.stories[0].summary, 'Checkout Flow Integration');
      assert.equal(data.stories[1].id, 'STORY-2');
      assert.equal(data.stories[1].summary, 'Webhook & Refund Handling');
    });

    it('extracts story metadata', () => {
      assert.equal(data.stories[0].estimate, '~8 hours');
      assert.equal(data.stories[0].assignee, 'alice@example.com');
      assert.equal(data.stories[1].priority, 'High');
    });

    it('extracts all tasks under correct stories', () => {
      // Story 1 has tasks 1.1 and 1.2
      assert.equal(data.stories[0].tasks.length, 2);
      assert.equal(data.stories[0].tasks[0].id, 'TASK-1.1');
      assert.equal(data.stories[0].tasks[0].summary, 'Create payment service module');
      assert.equal(data.stories[0].tasks[1].id, 'TASK-1.2');
      assert.equal(data.stories[0].tasks[1].summary, 'Build checkout API endpoint');

      // Story 2 has tasks 2.1 and 2.2
      assert.equal(data.stories[1].tasks.length, 2);
      assert.equal(data.stories[1].tasks[0].id, 'TASK-2.1');
      assert.equal(data.stories[1].tasks[1].id, 'TASK-2.2');
    });

    it('extracts task metadata', () => {
      const task11 = data.stories[0].tasks[0];
      assert.equal(task11.estimate, '3 hours');
      assert.equal(task11.assignee, 'alice@example.com');
      assert.deepEqual(task11.labels, ['backend', 'payments']);

      const task12 = data.stories[0].tasks[1];
      assert.equal(task12.estimate, '3 hours');
      assert.equal(task12.assignee, 'bob@example.com');
    });

    it('extracts all subtasks under correct tasks', () => {
      // TASK 1.1 has 4 subtasks (1.1.1 - 1.1.4)
      const task11 = data.stories[0].tasks[0];
      assert.equal(task11.subtasks.length, 4);
      assert.equal(task11.subtasks[0].id, 'SUBTASK-1.1.1');
      assert.equal(task11.subtasks[0].summary, 'Create Stripe client wrapper with auth config');
      assert.equal(task11.subtasks[1].id, 'SUBTASK-1.1.2');
      assert.equal(task11.subtasks[2].id, 'SUBTASK-1.1.3');
      assert.equal(task11.subtasks[3].id, 'SUBTASK-1.1.4');

      // TASK 1.2 has 3 subtasks (1.2.1 - 1.2.3)
      const task12 = data.stories[0].tasks[1];
      assert.equal(task12.subtasks.length, 3);
      assert.equal(task12.subtasks[0].id, 'SUBTASK-1.2.1');
      assert.equal(task12.subtasks[1].id, 'SUBTASK-1.2.2');
      assert.equal(task12.subtasks[2].id, 'SUBTASK-1.2.3');

      // TASK 2.1 has 5 subtasks (2.1.1 - 2.1.5)
      const task21 = data.stories[1].tasks[0];
      assert.equal(task21.subtasks.length, 5);
      assert.equal(task21.subtasks[0].id, 'SUBTASK-2.1.1');
      assert.equal(task21.subtasks[4].id, 'SUBTASK-2.1.5');

      // TASK 2.2 has 2 subtasks (2.2.1 - 2.2.2)
      const task22 = data.stories[1].tasks[1];
      assert.equal(task22.subtasks.length, 2);
      assert.equal(task22.subtasks[0].id, 'SUBTASK-2.2.1');
      assert.equal(task22.subtasks[1].id, 'SUBTASK-2.2.2');
    });

    it('subtask metadata is extracted', () => {
      const subtask111 = data.stories[0].tasks[0].subtasks[0];
      assert.equal(subtask111.estimate, '1 hour');

      const subtask113 = data.stories[0].tasks[0].subtasks[2];
      assert.equal(subtask113.estimate, '45 minutes');
    });

    it('counts total issues correctly', () => {
      let totalTasks = 0;
      let totalSubtasks = 0;
      data.stories.forEach(story => {
        totalTasks += story.tasks.length;
        story.tasks.forEach(task => {
          totalSubtasks += task.subtasks.length;
        });
      });

      assert.equal(data.stories.length, 2, '2 stories');
      assert.equal(totalTasks, 4, '4 tasks');
      assert.equal(totalSubtasks, 14, '14 subtasks');
      // Total: 1 epic + 2 stories + 4 tasks + 14 subtasks = 21
      assert.equal(1 + data.stories.length + totalTasks + totalSubtasks, 21);
    });
  });
});

describe('JIRA issue mapping output', () => {

  describe('dry-run mapping simulation', () => {
    // Simulate what IssueCreator.createdIssues would contain after a dry-run
    // by walking the parsed structure and generating DRYRUN keys.
    function simulateDryRunMapping(data) {
      const mapping = new Map();

      if (data.epic) {
        mapping.set(data.epic.id, `${data.epic.id}-DRYRUN`);
      }
      for (const story of data.stories) {
        mapping.set(story.id, `${story.id}-DRYRUN`);
        for (const task of story.tasks) {
          mapping.set(task.id, `${task.id}-DRYRUN`);
          for (const subtask of task.subtasks) {
            mapping.set(subtask.id, `${subtask.id}-DRYRUN`);
          }
        }
      }
      return mapping;
    }

    // Simulate real JIRA key assignment (PROJ-1, PROJ-2, ...)
    function simulateRealMapping(data, projectKey) {
      const mapping = new Map();
      let seq = 1;

      if (data.epic) {
        mapping.set(data.epic.id, `${projectKey}-${seq++}`);
      }
      for (const story of data.stories) {
        mapping.set(story.id, `${projectKey}-${seq++}`);
        for (const task of story.tasks) {
          mapping.set(task.id, `${projectKey}-${seq++}`);
          for (const subtask of task.subtasks) {
            mapping.set(subtask.id, `${projectKey}-${seq++}`);
          }
        }
      }
      return mapping;
    }

    let data;
    let dryMapping;
    let realMapping;

    it('builds mapping from parsed data', () => {
      const parser = new MarkdownParser(COMPLEX_DEV_PLAN);
      data = parser.parse();
      dryMapping = simulateDryRunMapping(data);
      realMapping = simulateRealMapping(data, 'PAY');
      assert.ok(dryMapping.size > 0);
    });

    it('mapping contains all hierarchy levels', () => {
      // Epic
      assert.ok(dryMapping.has('EPIC'), 'mapping should have EPIC');

      // Stories
      assert.ok(dryMapping.has('STORY-1'));
      assert.ok(dryMapping.has('STORY-2'));

      // Tasks
      assert.ok(dryMapping.has('TASK-1.1'));
      assert.ok(dryMapping.has('TASK-1.2'));
      assert.ok(dryMapping.has('TASK-2.1'));
      assert.ok(dryMapping.has('TASK-2.2'));

      // Subtasks (all 14)
      assert.ok(dryMapping.has('SUBTASK-1.1.1'));
      assert.ok(dryMapping.has('SUBTASK-1.1.2'));
      assert.ok(dryMapping.has('SUBTASK-1.1.3'));
      assert.ok(dryMapping.has('SUBTASK-1.1.4'));
      assert.ok(dryMapping.has('SUBTASK-1.2.1'));
      assert.ok(dryMapping.has('SUBTASK-1.2.2'));
      assert.ok(dryMapping.has('SUBTASK-1.2.3'));
      assert.ok(dryMapping.has('SUBTASK-2.1.1'));
      assert.ok(dryMapping.has('SUBTASK-2.1.2'));
      assert.ok(dryMapping.has('SUBTASK-2.1.3'));
      assert.ok(dryMapping.has('SUBTASK-2.1.4'));
      assert.ok(dryMapping.has('SUBTASK-2.1.5'));
      assert.ok(dryMapping.has('SUBTASK-2.2.1'));
      assert.ok(dryMapping.has('SUBTASK-2.2.2'));
    });

    it('mapping has correct total count', () => {
      // 1 epic + 2 stories + 4 tasks + 14 subtasks = 21
      assert.equal(dryMapping.size, 21);
    });

    it('real mapping produces sequential JIRA keys', () => {
      assert.equal(realMapping.get('EPIC'), 'PAY-1');
      assert.equal(realMapping.get('STORY-1'), 'PAY-2');
      assert.equal(realMapping.get('TASK-1.1'), 'PAY-3');
      assert.equal(realMapping.get('SUBTASK-1.1.1'), 'PAY-4');
      assert.equal(realMapping.get('SUBTASK-1.1.2'), 'PAY-5');
      assert.equal(realMapping.get('SUBTASK-1.1.3'), 'PAY-6');
      assert.equal(realMapping.get('SUBTASK-1.1.4'), 'PAY-7');
      assert.equal(realMapping.get('TASK-1.2'), 'PAY-8');
      assert.equal(realMapping.get('SUBTASK-1.2.1'), 'PAY-9');
      assert.equal(realMapping.get('SUBTASK-1.2.2'), 'PAY-10');
      assert.equal(realMapping.get('SUBTASK-1.2.3'), 'PAY-11');
      assert.equal(realMapping.get('STORY-2'), 'PAY-12');
      assert.equal(realMapping.get('TASK-2.1'), 'PAY-13');
      assert.equal(realMapping.get('SUBTASK-2.1.1'), 'PAY-14');
      assert.equal(realMapping.get('SUBTASK-2.1.5'), 'PAY-18');
      assert.equal(realMapping.get('TASK-2.2'), 'PAY-19');
      assert.equal(realMapping.get('SUBTASK-2.2.1'), 'PAY-20');
      assert.equal(realMapping.get('SUBTASK-2.2.2'), 'PAY-21');
    });

    it('mapping serializes to JSON correctly (as jira-issue-mapping.json)', () => {
      const json = JSON.stringify({
        batchId: 'test-batch-123',
        createdAt: '2026-02-20T12:00:00Z',
        filePath: 'docs/dev_plans/payment-gateway.md',
        issues: Object.fromEntries(realMapping),
      }, null, 2);

      const parsed = JSON.parse(json);
      assert.equal(parsed.batchId, 'test-batch-123');
      assert.equal(Object.keys(parsed.issues).length, 21);
      assert.equal(parsed.issues['EPIC'], 'PAY-1');
      assert.equal(parsed.issues['SUBTASK-1.1.1'], 'PAY-4');
      assert.equal(parsed.issues['SUBTASK-2.2.2'], 'PAY-21');
    });
  });

  describe('subtask lookup pattern for /execute reconciliation', () => {
    // This tests the pattern used by execute.md to find subtask JIRA keys
    // for a given task: "find all entries where key starts with SUBTASK-{N.M}."

    function getSubtaskKeysForTask(mapping, taskNumber) {
      const prefix = `SUBTASK-${taskNumber}.`;
      const result = [];
      for (const [id, jiraKey] of mapping) {
        if (id.startsWith(prefix)) {
          result.push({ id, jiraKey });
        }
      }
      return result;
    }

    let realMapping;

    it('builds mapping for lookup tests', () => {
      const parser = new MarkdownParser(COMPLEX_DEV_PLAN);
      const data = parser.parse();
      realMapping = new Map();
      let seq = 1;
      if (data.epic) realMapping.set(data.epic.id, `PAY-${seq++}`);
      for (const story of data.stories) {
        realMapping.set(story.id, `PAY-${seq++}`);
        for (const task of story.tasks) {
          realMapping.set(task.id, `PAY-${seq++}`);
          for (const subtask of task.subtasks) {
            realMapping.set(subtask.id, `PAY-${seq++}`);
          }
        }
      }
    });

    it('finds subtasks for TASK 1.1 (4 subtasks)', () => {
      const subtasks = getSubtaskKeysForTask(realMapping, '1.1');
      assert.equal(subtasks.length, 4);
      assert.equal(subtasks[0].id, 'SUBTASK-1.1.1');
      assert.equal(subtasks[0].jiraKey, 'PAY-4');
      assert.equal(subtasks[3].id, 'SUBTASK-1.1.4');
      assert.equal(subtasks[3].jiraKey, 'PAY-7');
    });

    it('finds subtasks for TASK 1.2 (3 subtasks)', () => {
      const subtasks = getSubtaskKeysForTask(realMapping, '1.2');
      assert.equal(subtasks.length, 3);
      assert.equal(subtasks[0].id, 'SUBTASK-1.2.1');
      assert.equal(subtasks[2].id, 'SUBTASK-1.2.3');
    });

    it('finds subtasks for TASK 2.1 (5 subtasks)', () => {
      const subtasks = getSubtaskKeysForTask(realMapping, '2.1');
      assert.equal(subtasks.length, 5);
      assert.equal(subtasks[0].id, 'SUBTASK-2.1.1');
      assert.equal(subtasks[4].id, 'SUBTASK-2.1.5');
    });

    it('finds subtasks for TASK 2.2 (2 subtasks)', () => {
      const subtasks = getSubtaskKeysForTask(realMapping, '2.2');
      assert.equal(subtasks.length, 2);
    });

    it('returns empty array for task with no subtasks', () => {
      const subtasks = getSubtaskKeysForTask(realMapping, '3.1');
      assert.equal(subtasks.length, 0);
    });

    it('does not cross-match TASK 1.1 subtasks when looking for TASK 1.12', () => {
      // SUBTASK-1.1.1 should NOT match prefix "SUBTASK-1.12."
      const subtasks = getSubtaskKeysForTask(realMapping, '1.12');
      assert.equal(subtasks.length, 0);
    });

    it('does not cross-match TASK 2.1 subtasks when looking for TASK 2.10', () => {
      const subtasks = getSubtaskKeysForTask(realMapping, '2.10');
      assert.equal(subtasks.length, 0);
    });
  });
});

describe('dev plan JIRA link injection for all levels', () => {
  let tempDir;

  function writeTempFile(content) {
    const filePath = join(tempDir, 'test-plan.md');
    writeFileSync(filePath, content, 'utf8');
    return filePath;
  }

  function readTempFile(filePath) {
    return readFileSync(filePath, 'utf8');
  }

  it('injects JIRA links at all 4 hierarchy levels', () => {
    tempDir = mkdtempSync(join(tmpdir(), 'jira-breakdown-'));

    const content = [
      '## EPIC: Test Feature',
      '',
      '## STORY 1: First Story',
      '',
      '### TASK 1.1: First Task',
      '',
      '#### SUBTASK 1.1.1: First Subtask',
      '',
      '#### SUBTASK 1.1.2: Second Subtask',
      '',
      '### TASK 1.2: Second Task',
      '',
      '## STORY 2: Second Story',
      '',
      '### TASK 2.1: Third Task',
      '',
      '#### SUBTASK 2.1.1: Third Subtask',
    ].join('\n');

    const createdIssues = new Map([
      ['EPIC', 'PAY-1'],
      ['STORY-1', 'PAY-2'],
      ['TASK-1.1', 'PAY-3'],
      ['SUBTASK-1.1.1', 'PAY-4'],
      ['SUBTASK-1.1.2', 'PAY-5'],
      ['TASK-1.2', 'PAY-6'],
      ['STORY-2', 'PAY-7'],
      ['TASK-2.1', 'PAY-8'],
      ['SUBTASK-2.1.1', 'PAY-9'],
    ]);

    const filePath = writeTempFile(content);
    updateDevPlanWithJiraLinks(filePath, content, createdIssues, 'https://test.atlassian.net');

    const result = readTempFile(filePath);

    // Verify all JIRA links injected
    assert.ok(result.includes('**JIRA:** [PAY-1](https://test.atlassian.net/browse/PAY-1)'), 'Epic JIRA link');
    assert.ok(result.includes('**JIRA:** [PAY-2](https://test.atlassian.net/browse/PAY-2)'), 'Story 1 JIRA link');
    assert.ok(result.includes('**JIRA:** [PAY-3](https://test.atlassian.net/browse/PAY-3)'), 'Task 1.1 JIRA link');
    assert.ok(result.includes('**JIRA:** [PAY-4](https://test.atlassian.net/browse/PAY-4)'), 'Subtask 1.1.1 JIRA link');
    assert.ok(result.includes('**JIRA:** [PAY-5](https://test.atlassian.net/browse/PAY-5)'), 'Subtask 1.1.2 JIRA link');
    assert.ok(result.includes('**JIRA:** [PAY-6](https://test.atlassian.net/browse/PAY-6)'), 'Task 1.2 JIRA link');
    assert.ok(result.includes('**JIRA:** [PAY-7](https://test.atlassian.net/browse/PAY-7)'), 'Story 2 JIRA link');
    assert.ok(result.includes('**JIRA:** [PAY-8](https://test.atlassian.net/browse/PAY-8)'), 'Task 2.1 JIRA link');
    assert.ok(result.includes('**JIRA:** [PAY-9](https://test.atlassian.net/browse/PAY-9)'), 'Subtask 2.1.1 JIRA link');

    // Count total JIRA links — should be exactly 9
    const jiraLinkCount = (result.match(/\*\*JIRA:\*\*/g) || []).length;
    assert.equal(jiraLinkCount, 9, 'should have 9 JIRA links total');

    rmSync(tempDir, { recursive: true });
  });

  it('preserves ordering — JIRA link appears immediately after heading', () => {
    tempDir = mkdtempSync(join(tmpdir(), 'jira-breakdown-'));

    const content = [
      '## EPIC: Test',
      '',
      '## STORY 1: A Story',
      '',
      '### TASK 1.1: A Task',
      '',
      '#### SUBTASK 1.1.1: A Subtask',
      'Some description text here',
    ].join('\n');

    const createdIssues = new Map([
      ['EPIC', 'X-1'],
      ['STORY-1', 'X-2'],
      ['TASK-1.1', 'X-3'],
      ['SUBTASK-1.1.1', 'X-4'],
    ]);

    const filePath = writeTempFile(content);
    updateDevPlanWithJiraLinks(filePath, content, createdIssues, 'https://j.atlassian.net');

    const lines = readTempFile(filePath).split('\n');

    // Each heading should be immediately followed by its JIRA link
    for (let i = 0; i < lines.length; i++) {
      const id = getHeadingId(lines[i]);
      if (id && createdIssues.has(id)) {
        assert.ok(
          lines[i + 1].startsWith('**JIRA:**'),
          `Line after "${lines[i]}" should be a JIRA link, got: "${lines[i + 1]}"`
        );
      }
    }

    rmSync(tempDir, { recursive: true });
  });
});

describe('summaryWithPlanId for all hierarchy levels', () => {
  it('prepends plan id for each level', () => {
    assert.equal(summaryWithPlanId('STORY-3', 'Webhook Handling'), '3 Webhook Handling');
    assert.equal(summaryWithPlanId('TASK-2.1', 'Create endpoint'), '2.1 Create endpoint');
    assert.equal(summaryWithPlanId('SUBTASK-1.2.3', 'Add validation'), '1.2.3 Add validation');
    assert.equal(summaryWithPlanId('SUBTASK-2.1.5', 'Handle refund event'), '2.1.5 Handle refund event');
  });

  it('handles deep subtask numbering', () => {
    // Edge case: subtask numbers with larger digits
    assert.equal(summaryWithPlanId('SUBTASK-10.5.12', 'Deep nesting'), '10.5.12 Deep nesting');
  });
});

describe('getHeadingId for all hierarchy levels', () => {
  it('identifies Epic', () => {
    assert.equal(getHeadingId('## EPIC: Payment Gateway Integration'), 'EPIC');
  });

  it('identifies Stories', () => {
    assert.equal(getHeadingId('## STORY 1: Checkout Flow'), 'STORY-1');
    assert.equal(getHeadingId('## STORY 2: Webhook Handling'), 'STORY-2');
  });

  it('identifies Tasks', () => {
    assert.equal(getHeadingId('### TASK 1.1: Create service'), 'TASK-1.1');
    assert.equal(getHeadingId('### TASK 2.2: Build endpoint'), 'TASK-2.2');
  });

  it('identifies Subtasks (#### format)', () => {
    assert.equal(getHeadingId('#### SUBTASK 1.1.1: Create wrapper'), 'SUBTASK-1.1.1');
    assert.equal(getHeadingId('#### SUBTASK 2.1.5: Handle event'), 'SUBTASK-2.1.5');
  });

  it('identifies Subtasks (### format)', () => {
    assert.equal(getHeadingId('### SUBTASK 1.1.1: Create wrapper'), 'SUBTASK-1.1.1');
  });

  it('identifies Subtasks (hyphen format)', () => {
    assert.equal(getHeadingId('### SUBTASK-1.2.3: Some task'), 'SUBTASK-1.2.3');
  });

  it('returns null for non-issue headings', () => {
    assert.equal(getHeadingId('## Pipeline Status'), null);
    assert.equal(getHeadingId('## Dependency Graph'), null);
    assert.equal(getHeadingId('### Required Tests:'), null);
  });
});
