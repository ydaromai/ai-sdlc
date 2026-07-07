import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { MarkdownParser } from '../jira-import.js';

describe('MarkdownParser', () => {
  describe('happy path', () => {
    it('parses Epic, Stories, Tasks, and Subtasks', () => {
      const md = `## EPIC: My Feature

## STORY 1: First Story
**Time Estimate:** 8 hours

### TASK 1.1: First Task
**Time Estimate:** 4 hours

#### SUBTASK 1.1.1: First Subtask

#### SUBTASK 1.1.2: Second Subtask

### TASK 1.2: Second Task

## STORY 2: Second Story

### TASK 2.1: Third Task
`;
      const parser = new MarkdownParser(md);
      const data = parser.parse();

      assert.equal(data.epic.summary, 'My Feature');
      assert.equal(data.stories.length, 2);
      assert.equal(data.stories[0].id, 'STORY-1');
      assert.equal(data.stories[0].summary, 'First Story');
      assert.equal(data.stories[0].tasks.length, 2);
      assert.equal(data.stories[0].tasks[0].id, 'TASK-1.1');
      assert.equal(data.stories[0].tasks[0].subtasks.length, 2);
      assert.equal(data.stories[0].tasks[0].subtasks[0].id, 'SUBTASK-1.1.1');
      assert.equal(data.stories[0].tasks[0].subtasks[1].id, 'SUBTASK-1.1.2');
      assert.equal(data.stories[0].tasks[1].id, 'TASK-1.2');
      assert.equal(data.stories[1].id, 'STORY-2');
      assert.equal(data.stories[1].tasks.length, 1);
      assert.equal(data.stories[1].tasks[0].id, 'TASK-2.1');
    });
  });

  describe('dual format support', () => {
    it('parses # STORY-N: format', () => {
      const md = `## EPIC: Test

# STORY-1: First Story

## TASK-1.1: A Task

### SUBTASK-1.1.1: A Subtask
`;
      const parser = new MarkdownParser(md);
      const data = parser.parse();

      assert.equal(data.stories.length, 1);
      assert.equal(data.stories[0].id, 'STORY-1');
      assert.equal(data.stories[0].tasks.length, 1);
      assert.equal(data.stories[0].tasks[0].id, 'TASK-1.1');
      assert.equal(data.stories[0].tasks[0].subtasks.length, 1);
    });

    it('parses EPIC-N format', () => {
      const md = `## EPIC-1: Numbered Epic

## STORY 1: A Story
`;
      const parser = new MarkdownParser(md);
      const data = parser.parse();

      assert.equal(data.epic.id, 'EPIC-1');
      assert.equal(data.epic.summary, 'Numbered Epic');
    });
  });

  describe('metadata extraction', () => {
    it('extracts Assignee, Priority, Time Estimate, and Labels', () => {
      const md = `## EPIC: Test
**Assignee:** alice@example.com
**Priority:** High
**Labels:** \`backend\`, \`urgent\`

## STORY 1: A Story
**Assignee:** bob@example.com
**Time Estimate:** 16 hours
**Labels:** \`frontend\`

### TASK 1.1: A Task
**Assignee:** charlie@example.com
**Time Estimate:** 4 hours
**Labels:** \`api\`
`;
      const parser = new MarkdownParser(md);
      const data = parser.parse();

      assert.equal(data.epic.assignee, 'alice@example.com');
      assert.equal(data.epic.priority, 'High');
      assert.deepEqual(data.epic.labels, ['backend', 'urgent']);

      assert.equal(data.stories[0].assignee, 'bob@example.com');
      assert.equal(data.stories[0].estimate, '16 hours');
      assert.deepEqual(data.stories[0].labels, ['frontend']);

      assert.equal(data.stories[0].tasks[0].assignee, 'charlie@example.com');
      assert.equal(data.stories[0].tasks[0].estimate, '4 hours');
      assert.deepEqual(data.stories[0].tasks[0].labels, ['api']);
    });
  });

  describe('edge cases', () => {
    it('handles SUBTASK before TASK without crashing', () => {
      const md = `## EPIC: Test

## STORY 1: A Story

### SUBTASK 1.1.1: Orphan Subtask

### TASK 1.1: Late Task
`;
      const parser = new MarkdownParser(md);
      // Should not throw
      const data = parser.parse();
      assert.equal(data.stories.length, 1);
      assert.equal(data.stories[0].tasks.length, 1);
      assert.equal(data.stories[0].tasks[0].id, 'TASK-1.1');
    });

    it('handles empty input', () => {
      const parser = new MarkdownParser('');
      const data = parser.parse();
      assert.equal(data.epic, null);
      assert.equal(data.stories.length, 0);
    });

    it('handles Epic only (no stories)', () => {
      const md = `## EPIC: Solo Epic
Some description text
`;
      const parser = new MarkdownParser(md);
      const data = parser.parse();
      assert.equal(data.epic.summary, 'Solo Epic');
      assert.equal(data.stories.length, 0);
    });

    it('handles multiple stories with tasks flushed correctly', () => {
      const md = `## EPIC: Test

## STORY 1: First

### TASK 1.1: Task A

## STORY 2: Second

### TASK 2.1: Task B
`;
      const parser = new MarkdownParser(md);
      const data = parser.parse();

      assert.equal(data.stories.length, 2);
      assert.equal(data.stories[0].tasks.length, 1);
      assert.equal(data.stories[0].tasks[0].id, 'TASK-1.1');
      assert.equal(data.stories[1].tasks.length, 1);
      assert.equal(data.stories[1].tasks[0].id, 'TASK-2.1');
    });
  });
});
