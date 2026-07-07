#!/usr/bin/env node
/**
 * Jira Issue Importer
 * 
 * Parses task breakdown markdown and creates issues in Jira via REST API.
 * 
 * Usage:
 *   node scripts/jira/jira-import.js --file=docs/dev_plans/breakdown.md --dry-run
 *   node scripts/jira/jira-import.js --file=docs/dev_plans/breakdown.md --create --update-file
 *   node scripts/jira/jira-import.js --help
 * 
 * Flags:
 *   --file=<path>      Path to breakdown markdown file (required)
 *   --create           Create issues in JIRA (default: preview only)
 *   --dry-run          Preview without creating issues
 *   --update-file      Update markdown file with JIRA links
 *   --force            Skip idempotency check (re-import even if already imported)
 *   --tasks-as-subtasks Use when JIRA hierarchy is fixed (Story→Sub-task only); creates Tasks and Subtasks as Sub-tasks under Story
 *   --help             Show this help message
 * 
 * Environment Variables:
 *   JIRA_API_URL - Jira instance URL (e.g., https://yourcompany.atlassian.net)
 *   JIRA_EMAIL - Your Jira email
 *   JIRA_API_TOKEN - Your Jira API token
 *   JIRA_PROJECT_KEY - Project key (e.g., MVP)
 */

import { readFileSync, writeFileSync, existsSync } from 'fs';
import { fileURLToPath } from 'url';
import { dirname, join, resolve } from 'path';
import { createInterface } from 'readline';
import { randomBytes } from 'node:crypto';
import { markdownToADF, prependAuditTrail } from './lib/markdown-to-adf.js';
import { redactAuth } from './lib/redact.js';
import { loadEnvJira } from './lib/env.js';
import { retryWithBackoff, sleep } from './lib/retry.js';
import { parseTimeEstimate } from './lib/parse-utils.js';
import { JiraClient } from './lib/jira-client.js';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

loadEnvJira();

/** Generate a batch ID for this import run (not a security credential — used as a local identifier only) */
function generateBatchId() {
  const timestamp = Date.now().toString(36);
  const random = randomBytes(4).toString('hex');
  return `${timestamp}-${random}`;
}

// sleep and retryWithBackoff are now imported from ./lib/retry.js

/** Prompt user for input */
async function promptUser(question, options = null) {
  const rl = createInterface({
    input: process.stdin,
    output: process.stdout,
  });

  return new Promise((resolve) => {
    if (options) {
      console.log(`\n${question}`);
      options.forEach((opt, i) => console.log(`  ${i + 1}. ${opt}`));
      rl.question('\nChoice: ', (answer) => {
        rl.close();
        resolve(answer.trim());
      });
    } else {
      rl.question(`\n${question} `, (answer) => {
        rl.close();
        resolve(answer.trim());
      });
    }
  });
}

/** Load import history */
function loadImportHistory() {
  const historyPath = join(process.cwd(), '.jira-import-history.json');
  if (!existsSync(historyPath)) {
    return {};
  }
  try {
    return JSON.parse(readFileSync(historyPath, 'utf8'));
  } catch (_) {
    return {};
  }
}

/** Save import history */
function saveImportHistory(history) {
  const historyPath = join(process.cwd(), '.jira-import-history.json');
  writeFileSync(historyPath, JSON.stringify(history, null, 2));
}

/** Check if file was already imported and prompt user */
async function checkIdempotency(filePath, force) {
  if (force) return true;

  const history = loadImportHistory();
  const existing = history[filePath];
  
  if (existing) {
    console.log(`\n⚠️  This plan was already imported:`);
    console.log(`   Epic: ${existing.epicKey}`);
    console.log(`   Date: ${new Date(existing.importDate).toLocaleString()}`);
    console.log(`   Issues: ${existing.issueCount}`);
    console.log(`   Batch: ${existing.batchId}`);
    
    const answer = await promptUser(
      'What would you like to do?',
      ['Skip (cancel)', 'Re-import (create new issues)', 'Continue anyway']
    );
    
    if (!answer || !['1', '2', '3'].includes(answer)) {
      console.log('\n❌ Import cancelled.\n');
      process.exit(0);
    }

    if (answer === '1') {
      console.log('\n❌ Import cancelled.\n');
      process.exit(0);
    }

    if (answer === '2') {
      console.log('\n⚠️  This will create duplicate issues in JIRA!');
      const confirm = await promptUser('Are you sure? (yes/no):');
      if (confirm.toLowerCase() !== 'yes') {
        console.log('\n❌ Import cancelled.\n');
        process.exit(0);
      }
    }
    
    return true;
  }
  
  return true;
}

// Configuration
const config = {
  apiUrl: process.env.JIRA_API_URL,
  email: process.env.JIRA_EMAIL,
  apiToken: process.env.JIRA_API_TOKEN,
  projectKey: process.env.JIRA_PROJECT_KEY,
};

// Validate config
function validateConfig() {
  const missing = [];
  if (!config.apiUrl) missing.push('JIRA_API_URL');
  if (!config.email) missing.push('JIRA_EMAIL');
  if (!config.apiToken) missing.push('JIRA_API_TOKEN');
  
  if (missing.length > 0) {
    console.error('❌ Missing required environment variables:');
    missing.forEach(v => console.error(`   - ${v}`));
    console.error('\nSet them with:');
    console.error('  export JIRA_API_URL=https://yourcompany.atlassian.net');
    console.error('  export JIRA_EMAIL=your.email@company.com');
    console.error('  export JIRA_API_TOKEN=your_api_token');
    console.error('  export JIRA_PROJECT_KEY=MVP');
    process.exit(1);
  }
}

// Parse command line arguments
function parseArgs() {
  const args = {
    file: null,
    dryRun: false,
    create: false,
    updateFile: false,
    force: false,
    tasksAsSubtasks: false,
    help: false,
  };
  
  process.argv.slice(2).forEach(arg => {
    if (arg.startsWith('--file=')) {
      args.file = arg.slice('--file='.length);
    } else if (arg === '--dry-run') {
      args.dryRun = true;
    } else if (arg === '--create') {
      args.create = true;
    } else if (arg === '--update-file') {
      args.updateFile = true;
    } else if (arg === '--force') {
      args.force = true;
    } else if (arg === '--tasks-as-subtasks') {
      args.tasksAsSubtasks = true;
    } else if (arg === '--help' || arg === '-h') {
      args.help = true;
    }
  });
  
  if (args.help) {
    showHelp();
    process.exit(0);
  }
  
  if (!args.file) {
    console.error('❌ Error: --file parameter required\n');
    console.error('Usage: node scripts/jira/jira-import.js --file=<path> [options]\n');
    console.error('Run with --help for more information');
    process.exit(1);
  }
  
  return args;
}

// Show help text
function showHelp() {
  console.log(`
📋 JIRA Issue Importer

Import task breakdowns from Markdown to JIRA with full hierarchy support.

USAGE:
  node scripts/jira/jira-import.js --file=<path> [options]

OPTIONS:
  --file=<path>           Path to breakdown markdown file (required)
  --create                Create issues in JIRA (default: preview only)
  --dry-run               Preview without creating issues
  --update-file           Update markdown file with JIRA links after import
  --force                 Skip idempotency check (re-import even if already imported)
  --tasks-as-subtasks     Use when JIRA hierarchy is fixed (Epic→Story→Sub-task only):
                          create plan-level Tasks and Subtasks as JIRA Sub-tasks under Story
  --help, -h              Show this help message

EXAMPLES:
  # Preview what would be created
  node scripts/jira/jira-import.js --file=docs/dev_plans/breakdown.md --dry-run

  # Create issues and update file with JIRA links
  node scripts/jira/jira-import.js --file=docs/dev_plans/breakdown.md --create --update-file

  # Force re-import (creates duplicates)
  node scripts/jira/jira-import.js --file=docs/dev_plans/breakdown.md --create --force

ENVIRONMENT VARIABLES:
  JIRA_API_URL        JIRA instance URL (e.g., https://company.atlassian.net)
  JIRA_EMAIL          Your JIRA email
  JIRA_API_TOKEN      Your JIRA API token (from id.atlassian.com/manage-profile/security/api-tokens)
  JIRA_PROJECT_KEY    Project key (e.g., MVP)

  These can be set in .env.jira in the project root:
    export JIRA_API_URL=https://yourcompany.atlassian.net
    export JIRA_EMAIL=your.email@company.com
    export JIRA_API_TOKEN=your_token
    export JIRA_PROJECT_KEY=MVP

FEATURES:
  ✅ Idempotency - prevents duplicate imports
  ✅ Batch IDs - track related issues for cleanup
  ✅ Audit trail - import metadata in issue descriptions
  ✅ Assignee lookup - automatic email to accountId mapping
  ✅ Retry logic - handles rate limiting automatically
  ✅ Rich formatting - Markdown converted to ADF for JIRA

DOCUMENTATION:
  See scripts/jira/README.md for detailed information
  See docs/ai_definitions/WORKFLOW_PLAN_TO_JIRA_TO_EXECUTION.md for workflow guide
`);
}

// JiraClient is now imported from ./lib/jira-client.js

// Markdown parser
class MarkdownParser {
  constructor(content) {
    this.content = content;
    this.lines = content.split('\n');
  }
  
  parse() {
    const result = {
      epic: null,
      stories: [],
    };
    
    let currentStory = null;
    let currentTask = null;
    let currentSubtask = null;
    let currentSection = null;
    let descriptionLines = [];
    
    for (let i = 0; i < this.lines.length; i++) {
      const line = this.lines[i];
      
      // Epic (supports both formats)
      if (line.match(/^## EPIC(-\d+)?:/)) {
        const match = line.match(/^## (EPIC(?:-\d+)?): (.+)/);
        if (match) {
          result.epic = {
            id: match[1],
            summary: match[2],
            description: '',
            assignee: null,
            priority: null,
            labels: [],
            estimate: null,
          };
          currentSection = 'epic';
          descriptionLines = [];
        }
      }
      
      // Story (supports both "## STORY 1:" and "# STORY-1:")
      else if (line.match(/^#{1,2} STORY[- ]\d+:/)) {
        // Flush current subtask into current task, then current task to previous story (so 1.2.1 is under 1.2, and 1.2 is under Story 1)
        if (currentSubtask && currentTask) {
          currentTask.subtasks.push(currentSubtask);
          currentSubtask = null;
        }
        if (currentTask && currentStory) {
          currentStory.tasks.push(currentTask);
          currentTask = null;
        }
        if (currentStory) {
          result.stories.push(currentStory);
        }
        const match = line.match(/^#{1,2} STORY[- ](\d+): (.+)/);
        if (match) {
          currentStory = {
            id: `STORY-${match[1]}`,
            summary: match[2],
            description: '',
            assignee: null,
            priority: null,
            labels: [],
            estimate: null,
            tasks: [],
          };
          currentSection = 'story';
          descriptionLines = [];
        }
      }
      
      // Task (supports both "### TASK 1.1:" and "## TASK-1.1:")
      else if (line.match(/^#{2,3} TASK[- ][\d.]+:/)) {
        // Flush current subtask into current task before moving to next task
        if (currentSubtask && currentTask) {
          currentTask.subtasks.push(currentSubtask);
          currentSubtask = null;
        }
        // Only push current task to current story if task's story number matches (e.g. don't push 1.2 to Story 2)
        if (currentTask && currentStory) {
          const taskStoryNum = currentTask.id.replace(/^TASK-(\d+).*/, '$1');
          const storyNum = currentStory.id.replace(/^STORY-(\d+)$/, '$1');
          if (taskStoryNum === storyNum) {
            currentStory.tasks.push(currentTask);
          }
        }
        const match = line.match(/^#{2,3} TASK[- ]([\d.]+): (.+)/);
        if (match) {
          currentTask = {
            id: `TASK-${match[1]}`,
            summary: match[2],
            description: '',
            assignee: null,
            estimate: null,
            labels: [],
            dependencies: [],
            subtasks: [],
          };
          currentSection = 'task';
          descriptionLines = [];
        }
      }
      
      // Subtask (supports "### SUBTASK-1.1.1:" and "#### SUBTASK 1.1.1:" for dev plans)
      else if (line.match(/^#{3,4} SUBTASK[- ]?[\d.]+:/)) {
        if (currentSubtask && currentTask) {
          currentTask.subtasks.push(currentSubtask);
        } else if (currentSubtask) {
          console.warn(`Warning: SUBTASK ${currentSubtask.id} found without a parent TASK — skipping`);
        }
        const match = line.match(/^#{3,4} SUBTASK[- ]?([\d.]+): (.+)/);
        if (match) {
          currentSubtask = {
            id: `SUBTASK-${match[1]}`,
            summary: match[2],
            description: '',
            assignee: null,
            estimate: null,
            labels: [],
          };
          currentSection = 'subtask';
          descriptionLines = [];
        }
      }
      
      // Metadata parsing
      else if (line.match(/^\*\*Assignee:\*\*/)) {
        const match = line.match(/^\*\*Assignee:\*\* (.+)/);
        if (match && currentSection) {
          const assignee = match[1].trim();
          if (currentSection === 'epic' && result.epic) result.epic.assignee = assignee;
          else if (currentSection === 'story' && currentStory) currentStory.assignee = assignee;
          else if (currentSection === 'task' && currentTask) currentTask.assignee = assignee;
          else if (currentSection === 'subtask' && currentSubtask) currentSubtask.assignee = assignee;
        }
      }
      
      else if (line.match(/^\*\*Priority:\*\*/)) {
        const match = line.match(/^\*\*Priority:\*\* (.+)/);
        if (match && currentSection) {
          const priority = match[1].trim();
          if (currentSection === 'epic' && result.epic) result.epic.priority = priority;
          else if (currentSection === 'story' && currentStory) currentStory.priority = priority;
        }
      }
      
      else if (line.match(/^\*\*Time Estimate:\*\*/)) {
        const match = line.match(/^\*\*Time Estimate:\*\* (.+)/);
        if (match && currentSection) {
          const estimate = match[1].trim();
          if (currentSection === 'story' && currentStory) currentStory.estimate = estimate;
          else if (currentSection === 'task' && currentTask) currentTask.estimate = estimate;
          else if (currentSection === 'subtask' && currentSubtask) currentSubtask.estimate = estimate;
        }
      }
      
      else if (line.match(/^\*\*Labels:\*\*/)) {
        const match = line.match(/^\*\*Labels:\*\* (.+)/);
        if (match && currentSection) {
          const labels = match[1].split(',').map(l => l.trim().replace(/`/g, ''));
          if (currentSection === 'epic' && result.epic) result.epic.labels = labels;
          else if (currentSection === 'story' && currentStory) currentStory.labels = labels;
          else if (currentSection === 'task' && currentTask) currentTask.labels = labels;
          else if (currentSection === 'subtask' && currentSubtask) currentSubtask.labels = labels;
        }
      }
      
      // Collect description lines
      else if (line.trim() && !line.match(/^(---|###|##|#|\*\*)/)) {
        descriptionLines.push(line);
      }
      
      // Save accumulated description when hitting a new section
      if (line.match(/^(#{1,3} |---)/)) {
        if (descriptionLines.length > 0) {
          const desc = descriptionLines.join('\n').trim();
          if (currentSection === 'epic' && result.epic) result.epic.description = desc;
          else if (currentSection === 'story' && currentStory) currentStory.description = desc;
          else if (currentSection === 'task' && currentTask) currentTask.description = desc;
          else if (currentSection === 'subtask' && currentSubtask) currentSubtask.description = desc;
          descriptionLines = [];
        }
      }
    }
    
    // Push final items
    if (currentSubtask && currentTask) currentTask.subtasks.push(currentSubtask);
    if (currentTask && currentStory) currentStory.tasks.push(currentTask);
    if (currentStory) result.stories.push(currentStory);
    
    return result;
  }
}

/**
 * Derive plan item id for JIRA title from parsed issue id.
 * EPIC -> "1", STORY-1 -> "1", TASK-1.1 -> "1.1", SUBTASK-1.1.1 -> "1.1.1"
 * @param {string} issueId - e.g. "EPIC", "STORY-1", "TASK-1.1", "SUBTASK-1.1.1"
 * @returns {string} - e.g. "1", "1", "1.1", "1.1.1"
 */
function planItemIdFromIssueId(issueId) {
  if (!issueId) return '';
  if (issueId === 'EPIC') return '1';
  const epicNum = issueId.match(/^EPIC-(\d+)$/);
  if (epicNum) return epicNum[1];
  const m = issueId.match(/^STORY-(\d+)$/);
  if (m) return m[1];
  const m2 = issueId.match(/^TASK-([\d.]+)$/);
  if (m2) return m2[1];
  const m3 = issueId.match(/^SUBTASK-([\d.]+)$/);
  if (m3) return m3[1];
  return '';
}

/**
 * Prepend plan item id to summary for JIRA title (e.g. "1.1.1 Create SQL schema file...").
 * Skips if summary already starts with the plan id.
 */
function summaryWithPlanId(issueId, summary) {
  const planId = planItemIdFromIssueId(issueId);
  if (!planId || !summary) return summary;
  const trimmed = summary.trim();
  if (trimmed.startsWith(planId + ' ') || trimmed.startsWith(planId + '.')) return trimmed;
  return `${planId} ${trimmed}`;
}

// Issue creator
class IssueCreator {
  constructor(jiraClient, projectKey, dryRun = false, batchId = null, filePath = null, tasksAsSubtasks = false) {
    this.client = jiraClient;
    this.projectKey = projectKey;
    this.dryRun = dryRun;
    this.batchId = batchId;
    this.filePath = filePath;
    this.tasksAsSubtasks = tasksAsSubtasks;
    this.createdIssues = new Map(); // id -> jira key
  }
  
  /**
   * Create an Epic in JIRA.
   * @param {object} epic - Parsed epic (id, summary, description, ...)
   * @param {number} epicsCount - Total number of epics in this import; preceding number in summary only when epicsCount > 1
   */
  async createEpic(epic, epicsCount = 1) {
    const summary = epicsCount > 1 ? summaryWithPlanId(epic.id, epic.summary) : (epic.summary || '').trim();
    console.log(`\n📦 Creating Epic: ${summary}`);
    
    const issueData = {
      fields: {
        project: { key: this.projectKey },
        issuetype: { name: 'Epic' },
        summary,
        description: this.formatDescription(epic.description),
        // customfield_10011 (Epic Name) is not available in next-gen projects — skip it
      },
    };
    
    // Add batch label
    const labels = [...epic.labels];
    const batchLabel = this.getBatchLabel();
    if (batchLabel) {
      labels.push(batchLabel);
    }
    if (labels.length > 0) {
      issueData.fields.labels = labels;
    }
    
    // Assignee lookup
    if (epic.assignee) {
      const accountId = await this.getAssigneeAccountId(epic.assignee);
      if (accountId) {
        issueData.fields.assignee = { accountId };
      }
    }
    
    if (this.dryRun) {
      console.log('   [DRY RUN] Would create:', JSON.stringify(issueData, null, 2));
      this.createdIssues.set(epic.id, `${epic.id}-DRYRUN`);
      return `${epic.id}-DRYRUN`;
    }
    
    try {
      const result = await this.client.createIssue(issueData);
      console.log(`   ✅ Created: ${result.key}`);
      this.createdIssues.set(epic.id, result.key);
      return result.key;
    } catch (error) {
      console.error(`   ❌ Failed to create epic: ${error.message}`);
      throw error;
    }
  }
  
  async createStory(story, epicKey) {
    const summary = summaryWithPlanId(story.id, story.summary);
    console.log(`\n📄 Creating Story: ${summary}`);
    
    const issueData = {
      fields: {
        project: { key: this.projectKey },
        issuetype: { name: 'Story' },
        summary,
        description: this.formatDescription(story.description),
        parent: { key: epicKey },
      },
    };
    
    if (story.estimate) {
      const parsed = parseTimeEstimate(story.estimate);
      if (parsed) {
        issueData.fields.timetracking = { originalEstimate: parsed };
      }
    }

    // Add batch label
    const labels = [...story.labels];
    const batchLabel = this.getBatchLabel();
    if (batchLabel) {
      labels.push(batchLabel);
    }
    if (labels.length > 0) {
      issueData.fields.labels = labels;
    }
    
    // Assignee lookup
    if (story.assignee) {
      const accountId = await this.getAssigneeAccountId(story.assignee);
      if (accountId) {
        issueData.fields.assignee = { accountId };
      }
    }
    
    if (this.dryRun) {
      console.log('   [DRY RUN] Would create:', JSON.stringify(issueData, null, 2));
      this.createdIssues.set(story.id, `${story.id}-DRYRUN`);
      return `${story.id}-DRYRUN`;
    }
    
    try {
      const result = await this.client.createIssue(issueData);
      console.log(`   ✅ Created: ${result.key}`);
      this.createdIssues.set(story.id, result.key);
      return result.key;
    } catch (error) {
      console.error(`   ❌ Failed to create story: ${error.message}`);
      throw error;
    }
  }
  
  async createTask(task, storyKey) {
    const summary = summaryWithPlanId(task.id, task.summary);
    console.log(`\n  📋 Creating Task: ${summary}`);

    // When --tasks-as-subtasks: JIRA hierarchy is fixed (Story→Sub-task only); create as Sub-task under Story
    const issueData = {
      fields: {
        project: { key: this.projectKey },
        issuetype: { name: this.tasksAsSubtasks ? 'Subtask' : 'Task' },
        summary,
        description: this.formatDescription(task.description),
        parent: { key: storyKey },
      },
    };
    
    if (task.estimate) {
      const parsed = parseTimeEstimate(task.estimate);
      if (parsed) {
        issueData.fields.timetracking = { originalEstimate: parsed };
      }
    }

    // Add batch label
    const labels = [...task.labels];
    const batchLabel = this.getBatchLabel();
    if (batchLabel) {
      labels.push(batchLabel);
    }
    if (labels.length > 0) {
      issueData.fields.labels = labels;
    }
    
    // Assignee lookup
    if (task.assignee) {
      const accountId = await this.getAssigneeAccountId(task.assignee);
      if (accountId) {
        issueData.fields.assignee = { accountId };
      }
    }
    
    if (this.dryRun) {
      console.log('     [DRY RUN] Would create');
      this.createdIssues.set(task.id, `${task.id}-DRYRUN`);
      return `${task.id}-DRYRUN`;
    }
    
    try {
      const result = await this.client.createIssue(issueData);
      console.log(`     ✅ Created: ${result.key}`);
      this.createdIssues.set(task.id, result.key);
      return result.key;
    } catch (error) {
      console.error(`     ❌ Failed to create task: ${error.message}`);
      throw error;
    }
  }
  
  async createSubtask(subtask, parentKey) {
    const summary = summaryWithPlanId(subtask.id, subtask.summary);
    console.log(`\n    ⚡ Creating Subtask: ${summary}`);

    // When --tasks-as-subtasks, parentKey is storyKey (Sub-tasks are flat under Story)
    const issueData = {
      fields: {
        project: { key: this.projectKey },
        issuetype: { name: 'Subtask' },
        summary,
        description: this.formatDescription(subtask.description),
        parent: { key: parentKey },
      },
    };
    
    if (subtask.estimate) {
      const parsed = parseTimeEstimate(subtask.estimate);
      if (parsed) {
        issueData.fields.timetracking = { originalEstimate: parsed };
      }
    }

    // Add batch label
    const labels = [...subtask.labels];
    const batchLabel = this.getBatchLabel();
    if (batchLabel) {
      labels.push(batchLabel);
    }
    if (labels.length > 0) {
      issueData.fields.labels = labels;
    }
    
    // Assignee lookup
    if (subtask.assignee) {
      const accountId = await this.getAssigneeAccountId(subtask.assignee);
      if (accountId) {
        issueData.fields.assignee = { accountId };
      }
    }
    
    if (this.dryRun) {
      console.log('       [DRY RUN] Would create');
      this.createdIssues.set(subtask.id, `${subtask.id}-DRYRUN`);
      return `${subtask.id}-DRYRUN`;
    }
    
    try {
      const result = await this.client.createIssue(issueData);
      console.log(`       ✅ Created: ${result.key}`);
      this.createdIssues.set(subtask.id, result.key);
      return result.key;
    } catch (error) {
      console.error(`       ❌ Failed to create subtask: ${error.message}`);
      throw error;
    }
  }
  
  formatDescription(text) {
    // Convert markdown to ADF
    let adf = markdownToADF(text);
    
    // Prepend audit trail if we have batch info
    if (this.batchId && this.filePath) {
      adf = prependAuditTrail(adf, this.filePath, this.batchId);
    }
    
    return adf;
  }
  
  getBatchLabel() {
    return this.batchId ? `import-batch-${this.batchId}` : null;
  }
  
  async getAssigneeAccountId(assigneeEmail) {
    if (!assigneeEmail || !this.client) {
      return null;
    }
    
    return await this.client.getUserByEmail(assigneeEmail);
  }
  
  saveMapping(outputPath) {
    const mapping = {
      batchId: this.batchId,
      createdAt: new Date().toISOString(),
      filePath: this.filePath,
      issues: Object.fromEntries(this.createdIssues),
    };
    writeFileSync(outputPath, JSON.stringify(mapping, null, 2));
    console.log(`\n💾 Issue mapping saved to: ${outputPath}`);
  }
}

/**
 * Extract JIRA issue id from a dev plan / breakdown heading line for lookup in createdIssues.
 * @param {string} line - One line of markdown
 * @returns {string|null} - Id like 'EPIC', 'STORY-1', 'TASK-1.1', 'SUBTASK-1.1.1' or null
 */
function getHeadingId(line) {
  let m;
  if ((m = line.match(/^## (EPIC(?:-\d+)?):/))) return m[1];
  if ((m = line.match(/^## STORY (\d+):/))) return `STORY-${m[1]}`;
  if ((m = line.match(/^### TASK ([\d.]+):/))) return `TASK-${m[1]}`;
  if ((m = line.match(/^#### SUBTASK ([\d.]+):/))) return `SUBTASK-${m[1]}`;
  if ((m = line.match(/^### SUBTASK ([\d.]+):/))) return `SUBTASK-${m[1]}`; // dev plan style: ### SUBTASK 1.1.1:
  if ((m = line.match(/^### SUBTASK-?([\d.]+):/))) return `SUBTASK-${m[1]}`;
  return null;
}

/**
 * Update dev plan markdown file with JIRA issue keys and links after import.
 * Inserts "**JIRA:** [KEY](url)" after each Epic/Story/Task/Subtask heading when we have a key.
 * Replaces any existing **JIRA:** line that immediately follows a heading.
 *
 * @param {string} filePath - Absolute path to the markdown file
 * @param {string} content - Current file content
 * @param {Map<string, string>} createdIssues - Map of id (e.g. STORY-1) -> JIRA key (e.g. MVP-123)
 * @param {string} jiraBaseUrl - JIRA base URL (e.g. https://company.atlassian.net)
 */
function updateDevPlanWithJiraLinks(filePath, content, createdIssues, jiraBaseUrl) {
  const lines = content.split('\n');
  const out = [];
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    const id = getHeadingId(line);
    if (id && createdIssues.has(id)) {
      const key = createdIssues.get(id);
      const url = `${jiraBaseUrl.replace(/\/$/, '')}/browse/${key}`;
      out.push(line);
      out.push(`**JIRA:** [${key}](${url})`);
      continue;
    }
    // Skip existing **JIRA:** line that follows a heading we just output (avoid duplicate)
    if (line.match(/^\*\*JIRA:\*\* \[.+\]\(.+\)/)) {
      const prevId = i > 0 ? getHeadingId(lines[i - 1]) : null;
      if (prevId && createdIssues.has(prevId)) continue;
    }
    out.push(line);
  }
  writeFileSync(filePath, out.join('\n'), 'utf8');
  console.log(`\n📝 Dev plan updated with JIRA links: ${filePath}`);
}

// Main execution
async function main() {
  const args = parseArgs();
  
  console.log('🚀 Jira Issue Importer\n');
  console.log(`📄 File: ${args.file}`);
  console.log(`🏷️  Mode: ${args.dryRun ? 'DRY RUN' : (args.create ? 'CREATE' : 'PREVIEW')}\n`);
  
  if (args.create) {
    validateConfig();
  }
  
  // Check idempotency (unless --force or --dry-run)
  if (args.create && !args.dryRun) {
    await checkIdempotency(args.file, args.force);
  }
  
  // Read and parse markdown file
  console.log('📖 Reading markdown file...');
  const filePath = join(process.cwd(), args.file);
  const content = readFileSync(filePath, 'utf8');
  
  console.log('🔍 Parsing issues...');
  const parser = new MarkdownParser(content);
  const data = parser.parse();
  
  // Display summary
  console.log('\n📊 Parsed Issues:');
  console.log(`   Epic: ${data.epic?.summary || 'None'}`);
  console.log(`   Stories: ${data.stories.length}`);
  
  let totalTasks = 0;
  let totalSubtasks = 0;
  data.stories.forEach(story => {
    totalTasks += story.tasks.length;
    story.tasks.forEach(task => {
      totalSubtasks += task.subtasks.length;
    });
  });
  
  console.log(`   Tasks: ${totalTasks}`);
  console.log(`   Subtasks: ${totalSubtasks}`);
  const totalIssues = 1 + data.stories.length + totalTasks + totalSubtasks;
  console.log(`   Total Issues: ${totalIssues}`);
  
  if (!args.create && !args.dryRun) {
    console.log('\n💡 Run with --dry-run to preview, or --create to actually create issues.');
    return;
  }
  
  // Generate batch ID for this import
  const batchId = generateBatchId();
  console.log(`\n🏷️  Batch ID: ${batchId}`);
  
  // Create issues
  const jiraClient = args.create ? new JiraClient(config) : null;
  const creator = new IssueCreator(jiraClient, config.projectKey, args.dryRun, batchId, args.file, args.tasksAsSubtasks);
  if (args.tasksAsSubtasks) {
    console.log('📌 Using --tasks-as-subtasks: plan Tasks and Subtasks will be created as JIRA Sub-tasks under each Story\n');
  }
  
  try {
    // Create Epic (preceding number in summary only when more than one epic)
    let epicKey = null;
    const epicsList = (data.epics && data.epics.length > 0) ? data.epics : (data.epic ? [data.epic] : []);
    if (epicsList.length > 0) {
      epicKey = await creator.createEpic(epicsList[0], epicsList.length);
      
      // Create Stories, then Tasks under each Story, then Sub-tasks under each Task (or all as Sub-tasks under Story when --tasks-as-subtasks)
      for (const story of data.stories) {
        const storyKey = await creator.createStory(story, epicKey);
        for (const task of story.tasks) {
          const taskKey = await creator.createTask(task, storyKey);
          const subtaskParent = creator.tasksAsSubtasks ? storyKey : taskKey;
          for (const subtask of task.subtasks) {
            await creator.createSubtask(subtask, subtaskParent);
          }
        }
      }
    }
    
    // Save mapping
    const mappingPath = join(process.cwd(), 'jira-issue-mapping.json');
    creator.saveMapping(mappingPath);
    
    // Save import history (only on successful create, not dry-run)
    if (args.create && !args.dryRun && epicKey) {
      const history = loadImportHistory();
      history[args.file] = {
        epicKey,
        importDate: new Date().toISOString(),
        batchId,
        issueCount: totalIssues,
      };
      saveImportHistory(history);
      console.log('\n📝 Import history updated');
    }
    
    // Update dev plan file with JIRA keys and links (only when --create and --update-file)
    if (args.updateFile && args.create && !args.dryRun) {
      updateDevPlanWithJiraLinks(filePath, content, creator.createdIssues, config.apiUrl);
    }
    
    console.log('\n✅ Import complete!');
    
    if (!args.dryRun) {
      console.log(`\n💡 To clean up this import if needed:`);
      console.log(`   node scripts/jira/cleanup-import.js --batch=${batchId}`);
    }
    
  } catch (error) {
    console.error('\n❌ Import failed:', error.message);
    if (error.stack) {
      console.error('\nStack trace:');
      console.error(error.stack);
    }
    process.exit(1);
  }
}

// Run main only when executed directly (not when imported for testing)
const isDirectRun = process.argv[1] && fileURLToPath(import.meta.url) === resolve(process.argv[1]);
if (isDirectRun) {
  main();
}

export { MarkdownParser, getHeadingId, planItemIdFromIssueId, summaryWithPlanId, updateDevPlanWithJiraLinks };
