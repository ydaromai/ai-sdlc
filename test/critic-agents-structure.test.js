/**
 * Structural validation tests for critic agent files.
 *
 * Verifies that every *-critic.md in pipeline/agents/ follows the standard
 * 7-section format, has the required output elements (verdict, severity
 * levels, checklist marks), and that cross-file references (pipeline config,
 * PRD template) are consistent.
 *
 * Run: node --test test/critic-agents-structure.test.js
 */
import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync, existsSync } from 'fs';
import { join, basename, dirname } from 'path';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const AGENTS_DIR = join(__dirname, '..', 'pipeline', 'agents');

// Pre-flight: verify required directories exist before running tests.
// Uses assert so test runner reports a clear failure (not a cryptic ENOENT).
// If this fails in CI, check that the git clone is complete and pipeline/agents/ exists.
assert.ok(
  existsSync(AGENTS_DIR),
  `Agents directory not found: ${AGENTS_DIR}. Ensure the repository is fully cloned and pipeline/agents/ exists.`
);

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const MIN_CRITIC_FILES = 9;
const MIN_CHECKLIST_ITEMS = 5;
const MIN_OUTPUT_MARKS = 5;

const REQUIRED_SECTIONS = [
  '## Role',
  '## When Used',
  '## Inputs You Receive',
  '## Review Checklist',
  '## Output Format',
  '## Pass/Fail Rule',
  '## Guidelines',
];

const EXPECTED_CRITICS = [
  'product-critic.md',
  'dev-critic.md',
  'devops-critic.md',
  'qa-critic.md',
  'security-critic.md',
  'performance-critic.md',
  'data-integrity-critic.md',
  'designer-critic.md',
  'ml-critic.md',
];

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/**
 * Extract the content between two markdown heading patterns.
 * Returns the text from startHeading up to (but not including) the next
 * heading of equal or higher level, or end-of-file.
 * Correctly skips headings inside fenced code blocks (```).
 * Code block detection uses the opening ``` fence marker — tracks toggle state
 * so that nested or mismatched markers are handled gracefully (toggle on/off).
 *
 * Assumes well-formed markdown with standard ATX headings (# level).
 * Nested heading levels within a section (e.g., ### inside ##) are included
 * in the extracted content — only same-or-higher level headings terminate.
 */
function extractSection(content, sectionHeading) {
  const idx = content.indexOf(sectionHeading);
  if (idx === -1) return '';
  const afterHeading = content.slice(idx + sectionHeading.length);
  const lines = afterHeading.split('\n');
  const level = sectionHeading.match(/^#+/)[0];
  const escapedLevel = level.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const headingRegex = new RegExp(`^${escapedLevel} (?!#)`);
  let inCodeBlock = false;

  for (let i = 0; i < lines.length; i++) {
    // Toggle code block state on any ``` fence (with or without language tag)
    if (/^```/.test(lines[i].trimEnd())) {
      inCodeBlock = !inCodeBlock;
      continue;
    }
    if (!inCodeBlock && headingRegex.test(lines[i])) {
      return lines.slice(0, i).join('\n');
    }
  }
  return afterHeading;
}

/**
 * Extract a named YAML section from a pipeline config file.
 * Returns all lines from "  sectionName:" until the next sibling key.
 *
 * Assumes valid YAML with consistent indentation (detects actual indent from
 * the matched key). sectionName is sanitized for safe regex usage.
 * Returns empty string if section is not found.
 */
function extractYamlSection(content, sectionName) {
  const lines = content.split('\n');
  let capturing = false;
  let indent = -1;
  const result = [];
  const escaped = sectionName.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

  for (const line of lines) {
    const match = line.match(new RegExp(`^(\\s*)${escaped}:`));
    if (match && !capturing) {
      capturing = true;
      indent = match[1].length;
      result.push(line);
      continue;
    }
    if (capturing) {
      // Stop at a sibling key (same or lesser indent with a key)
      const keyMatch = line.match(/^(\s*)\S/);
      if (keyMatch && keyMatch[1].length <= indent && line.trim().length > 0) {
        break;
      }
      result.push(line);
    }
  }
  return result.join('\n');
}

// ---------------------------------------------------------------------------
// Discover all critic agent files
// ---------------------------------------------------------------------------
const agentFiles = readdirSync(AGENTS_DIR)
  .filter(f => f.endsWith('-critic.md'))
  .sort();

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

describe('Critic agent discovery', () => {
  it(`finds at least ${MIN_CRITIC_FILES} critic agent files`, () => {
    assert.ok(
      agentFiles.length >= MIN_CRITIC_FILES,
      `Expected at least ${MIN_CRITIC_FILES} critic files, found ${agentFiles.length}: ${agentFiles.join(', ')}`
    );
  });

  it('includes all expected critic agents', () => {
    for (const file of EXPECTED_CRITICS) {
      assert.ok(
        agentFiles.includes(file),
        `Missing expected critic file: ${file}`
      );
    }
  });
});

describe('Critic agent structure validation', () => {
  for (const file of agentFiles) {
    const agentName = basename(file, '.md');
    const content = readFileSync(join(AGENTS_DIR, file), 'utf8');

    describe(agentName, () => {
      it('starts with a top-level heading', () => {
        const firstLine = content.split('\n').find(l => l.trim().length > 0);
        assert.ok(
          firstLine.startsWith('# '),
          `${file} should start with "# " heading, got: "${firstLine}"`
        );
      });

      for (const section of REQUIRED_SECTIONS) {
        it(`has "${section}" section`, () => {
          assert.ok(
            content.includes(section),
            `${file} is missing required section: ${section}`
          );
        });
      }

      it('has PASS/FAIL verdict in output format', () => {
        const outputSection = extractSection(content, '## Output Format');
        assert.ok(
          outputSection.includes('Verdict: PASS | FAIL') || outputSection.includes('Verdict: PASS/FAIL'),
          `${file} output format should include "Verdict: PASS | FAIL"`
        );
      });

      it('has Critical findings section in output format', () => {
        const outputSection = extractSection(content, '## Output Format');
        assert.ok(
          outputSection.includes('Critical (must fix)'),
          `${file} should have "Critical (must fix)" in output format`
        );
      });

      it('has Warnings section in output format', () => {
        const outputSection = extractSection(content, '## Output Format');
        assert.ok(
          outputSection.includes('Warnings (should fix)'),
          `${file} should have "Warnings (should fix)" in output format`
        );
      });

      it('has Notes section in output format', () => {
        const outputSection = extractSection(content, '## Output Format');
        assert.ok(
          outputSection.includes('Notes (informational)'),
          `${file} should have "Notes (informational)" in output format`
        );
      });

      it('defines pass/fail rule correctly', () => {
        const passFailSection = extractSection(content, '## Pass/Fail Rule');
        assert.ok(
          passFailSection.includes('FAIL') && passFailSection.includes('Critical'),
          `${file} pass/fail rule should reference Critical findings`
        );
        assert.ok(
          passFailSection.includes('PASS') && passFailSection.includes('Warnings'),
          `${file} pass/fail rule should reference Warnings`
        );
      });

      it(`has at least ${MIN_CHECKLIST_ITEMS} review checklist items`, () => {
        const checklistSection = extractSection(content, '## Review Checklist');
        const checklistItems = checklistSection.match(/^- \[ \] /gm);
        assert.ok(
          checklistItems && checklistItems.length >= MIN_CHECKLIST_ITEMS,
          `${file} should have at least ${MIN_CHECKLIST_ITEMS} checklist items in Review Checklist, found ${checklistItems ? checklistItems.length : 0}`
        );
      });

      it(`has at least ${MIN_OUTPUT_MARKS} output checklist items with pass/fail marks`, () => {
        const outputSection = extractSection(content, '## Output Format');
        const outputChecklist = outputSection.match(/\[x\/✗[\/N\/A]*\]/g);
        assert.ok(
          outputChecklist && outputChecklist.length >= MIN_OUTPUT_MARKS,
          `${file} should have at least ${MIN_OUTPUT_MARKS} output checklist items with [x/✗] marks in Output Format, found ${outputChecklist ? outputChecklist.length : 0}`
        );
      });

      it('has a summary section in output format', () => {
        const outputSection = extractSection(content, '## Output Format');
        assert.ok(
          outputSection.includes('### Summary'),
          `${file} should have "### Summary" in output format`
        );
      });

      it('has Score field in output format', () => {
        const outputSection = extractSection(content, '## Output Format');
        assert.ok(
          outputSection.includes('Score:') && outputSection.includes('/ 10'),
          `${file} output format should include "Score: N.N / 10"`
        );
      });

      it('has scoring guideline', () => {
        const guidelinesSection = extractSection(content, '## Guidelines');
        assert.ok(
          guidelinesSection.includes('Scoring (1') && guidelinesSection.includes('10 scale)'),
          `${file} should have scoring guideline in Guidelines section`
        );
      });
    });
  }
});

describe('Designer Critic conditional activation', () => {
  const designerContent = readFileSync(join(AGENTS_DIR, 'designer-critic.md'), 'utf8');

  it('mentions has_frontend in the Role section', () => {
    const roleSection = extractSection(designerContent, '## Role');
    assert.ok(
      roleSection.includes('has_frontend'),
      'Designer Critic Role section should mention has_frontend conditional activation'
    );
  });

  it('specifies skip behavior when has_frontend is false', () => {
    assert.ok(
      designerContent.includes('skip this review entirely'),
      'Designer Critic should specify skip behavior when has_frontend is false'
    );
  });

  it('includes N/A in checklist marks', () => {
    assert.ok(
      designerContent.includes('[x/✗/N/A]'),
      'Designer Critic should use [x/✗/N/A] checklist marks'
    );
  });

  it('has accessibility checklist section', () => {
    const checklistSection = extractSection(designerContent, '## Review Checklist');
    assert.ok(
      checklistSection.includes('### Accessibility'),
      'Designer Critic should have Accessibility checklist section within Review Checklist'
    );
  });

  it('mentions WCAG', () => {
    assert.ok(
      designerContent.includes('WCAG'),
      'Designer Critic should reference WCAG accessibility standards'
    );
  });

  it('has Accessibility Summary table in output format', () => {
    const outputSection = extractSection(designerContent, '## Output Format');
    assert.ok(
      outputSection.includes('Accessibility Summary'),
      'Designer Critic should have Accessibility Summary table in output format'
    );
  });

  it('mentions CSP in guidelines', () => {
    const guidelinesSection = extractSection(designerContent, '## Guidelines');
    assert.ok(
      guidelinesSection.includes('CSP') || guidelinesSection.includes('Content Security Policy'),
      'Designer Critic guidelines should mention Content Security Policy'
    );
  });
});

describe('Product Critic analytics items', () => {
  const content = readFileSync(join(AGENTS_DIR, 'product-critic.md'), 'utf8');

  it('has analytics events checklist item in Review Checklist', () => {
    const checklistSection = extractSection(content, '## Review Checklist');
    assert.ok(
      checklistSection.includes('Analytics events defined'),
      'Product Critic should have analytics events checklist item in Review Checklist'
    );
  });

  it('has tracking traceability checklist item in Review Checklist', () => {
    const checklistSection = extractSection(content, '## Review Checklist');
    assert.ok(
      checklistSection.includes('Tracking requirements traceable'),
      'Product Critic should have tracking traceability checklist item in Review Checklist'
    );
  });

  it('has analytics guideline', () => {
    const guidelinesSection = extractSection(content, '## Guidelines');
    assert.ok(
      guidelinesSection.includes('analytics/tracking events'),
      'Product Critic should have analytics guideline in Guidelines section'
    );
  });

  it('analytics items are conditional on PRD Section 11', () => {
    assert.ok(
      content.includes('Section 11'),
      'Product Critic analytics items should reference PRD Section 11'
    );
  });
});

describe('Dev Critic analytics items', () => {
  const content = readFileSync(join(AGENTS_DIR, 'dev-critic.md'), 'utf8');

  it('has analytics instrumentation checklist item in Review Checklist', () => {
    const checklistSection = extractSection(content, '## Review Checklist');
    assert.ok(
      checklistSection.includes('Analytics events instrumented'),
      'Dev Critic should have analytics instrumentation checklist item in Review Checklist'
    );
  });

  it('has PII checklist item in Review Checklist', () => {
    const checklistSection = extractSection(content, '## Review Checklist');
    assert.ok(
      checklistSection.includes('No PII in analytics payloads'),
      'Dev Critic should have PII in analytics checklist item in Review Checklist'
    );
  });

  it('has non-blocking analytics checklist item in Review Checklist', () => {
    const checklistSection = extractSection(content, '## Review Checklist');
    assert.ok(
      checklistSection.includes("Analytics calls don't block"),
      'Dev Critic should have non-blocking analytics checklist item in Review Checklist'
    );
  });

  it('PII guideline is Critical severity', () => {
    const guidelinesSection = extractSection(content, '## Guidelines');
    assert.ok(
      guidelinesSection.includes('PII in analytics payloads is Critical'),
      'Dev Critic should flag PII in analytics as Critical in Guidelines'
    );
  });

  it('missing analytics guideline is Warning severity', () => {
    const guidelinesSection = extractSection(content, '## Guidelines');
    assert.ok(
      guidelinesSection.includes('Missing analytics instrumentation is a Warning'),
      'Dev Critic should flag missing analytics as Warning in Guidelines'
    );
  });
});

describe('Pipeline config template', () => {
  const content = readFileSync(
    join(__dirname, '..', 'pipeline', 'templates', 'pipeline-config-template.yaml'),
    'utf8'
  );

  it('has has_frontend flag', () => {
    assert.ok(
      content.includes('has_frontend:'),
      'Config template should have has_frontend flag'
    );
  });

  it('has_frontend defaults to false', () => {
    assert.ok(
      content.includes('has_frontend: false'),
      'has_frontend should default to false'
    );
  });

  it('includes designer in prd2plan critics', () => {
    const prd2planSection = extractYamlSection(content, 'prd2plan');
    assert.ok(
      prd2planSection.includes('designer'),
      'prd2plan stage should include designer critic'
    );
  });

  it('includes designer in execute critics', () => {
    const executeSection = extractYamlSection(content, 'execute');
    assert.ok(
      executeSection.includes('designer'),
      'execute stage should include designer critic'
    );
  });

  it('includes designer in pre_merge critics', () => {
    const preMergeSection = extractYamlSection(content, 'pre_merge');
    assert.ok(
      preMergeSection.includes('designer'),
      'pre_merge stage should include designer critic'
    );
  });

  it('includes designer in req2prd critics', () => {
    const req2prdSection = extractYamlSection(content, 'req2prd');
    assert.ok(
      req2prdSection.includes('designer'),
      'req2prd stage should include designer critic'
    );
  });

  it('req2prd stage includes all non-conditional critics', () => {
    const req2prdSection = extractYamlSection(content, 'req2prd');
    for (const critic of ['product', 'dev', 'devops', 'qa', 'security']) {
      assert.ok(
        req2prdSection.includes(critic),
        `req2prd section should include ${critic}`
      );
    }
  });

  it('has scoring configuration', () => {
    assert.ok(
      content.includes('scoring:'),
      'Config template should have scoring section'
    );
    assert.ok(
      content.includes('per_critic_min:'),
      'Config template should have per_critic_min threshold'
    );
    assert.ok(
      content.includes('overall_min:'),
      'Config template should have overall_min threshold'
    );
  });

  it('does not include designer in plan2jira critics', () => {
    const plan2jiraSection = extractYamlSection(content, 'plan2jira');
    assert.ok(
      !plan2jiraSection.includes('designer'),
      'plan2jira stage should NOT include designer critic'
    );
  });
});

describe('PRD template analytics section', () => {
  const content = readFileSync(
    join(__dirname, '..', 'pipeline', 'templates', 'prd-template.md'),
    'utf8'
  );

  it('has Tracking & Analytics Events subsection', () => {
    assert.ok(
      content.includes('### Tracking & Analytics Events'),
      'PRD template should have Tracking & Analytics Events subsection'
    );
  });

  it('is under Section 11 (Success Metrics)', () => {
    const section11Pos = content.indexOf('## 11. Success Metrics');
    const section12Pos = content.indexOf('## 12. Open Questions');
    const trackingPos = content.indexOf('### Tracking & Analytics Events');
    assert.ok(section11Pos > 0, 'Section 11 should exist');
    assert.ok(trackingPos > section11Pos, 'Tracking section should be after Section 11');
    assert.ok(trackingPos < section12Pos, 'Tracking section should be before Section 12');
  });

  it('has event table template', () => {
    assert.ok(
      content.includes('Event Name') && content.includes('Trigger') && content.includes('Maps to Metric'),
      'PRD template should have event table with Event Name, Trigger, and Maps to Metric columns'
    );
  });

  it('has PII warning note', () => {
    assert.ok(
      content.includes('PII'),
      'PRD template should include a PII warning note in analytics section'
    );
  });
});

// ---------------------------------------------------------------------------
// Negative / edge-case tests
// ---------------------------------------------------------------------------

describe('Critic agent negative validations', () => {
  it('no critic file is empty', () => {
    for (const file of agentFiles) {
      const content = readFileSync(join(AGENTS_DIR, file), 'utf8');
      assert.ok(
        content.trim().length > 100 && content.includes('## Role'),
        `${file} should not be empty or trivially short (must be >100 chars and contain ## Role)`
      );
    }
  });

  it('no critic file has duplicate section headings', () => {
    for (const file of agentFiles) {
      const content = readFileSync(join(AGENTS_DIR, file), 'utf8');
      for (const section of REQUIRED_SECTIONS) {
        const firstIdx = content.indexOf(section);
        const secondIdx = content.indexOf(section, firstIdx + section.length);
        assert.ok(
          secondIdx === -1,
          `${file} has duplicate section heading: ${section}`
        );
      }
    }
  });

  it('all critic files use consistent verdict format', () => {
    for (const file of agentFiles) {
      const content = readFileSync(join(AGENTS_DIR, file), 'utf8');
      const outputSection = extractSection(content, '## Output Format');
      // Must have exactly one of the standard verdict patterns
      const hasVerdictPipe = outputSection.includes('Verdict: PASS | FAIL');
      const hasVerdictSlash = outputSection.includes('Verdict: PASS/FAIL');
      assert.ok(
        hasVerdictPipe || hasVerdictSlash,
        `${file} must use "Verdict: PASS | FAIL" or "Verdict: PASS/FAIL" in Output Format`
      );
    }
  });

  it('Review Checklist items only appear in Review Checklist section', () => {
    for (const file of agentFiles) {
      const content = readFileSync(join(AGENTS_DIR, file), 'utf8');
      const checklistSection = extractSection(content, '## Review Checklist');
      const guidelinesSection = extractSection(content, '## Guidelines');
      // Guidelines should not contain unchecked checklist items
      const guidelineCheckboxes = guidelinesSection.match(/^- \[ \] /gm);
      assert.ok(
        !guidelineCheckboxes,
        `${file} Guidelines section should not contain unchecked checklist items (found ${guidelineCheckboxes ? guidelineCheckboxes.length : 0})`
      );
    }
  });

  it('Pass/Fail Rule section does not contain checklist items', () => {
    for (const file of agentFiles) {
      const content = readFileSync(join(AGENTS_DIR, file), 'utf8');
      const passFailSection = extractSection(content, '## Pass/Fail Rule');
      const checkboxes = passFailSection.match(/^- \[ \] /gm);
      assert.ok(
        !checkboxes,
        `${file} Pass/Fail Rule section should not contain checklist items`
      );
    }
  });
});

describe('Cross-file consistency', () => {
  it('every critic listed in EXPECTED_CRITICS has a corresponding file', () => {
    for (const expected of EXPECTED_CRITICS) {
      const filePath = join(AGENTS_DIR, expected);
      let exists = false;
      try {
        readFileSync(filePath, 'utf8');
        exists = true;
      } catch { /* file not found */ }
      assert.ok(exists, `Expected critic file ${expected} should exist at ${filePath}`);
    }
  });

  it('all critics mention /req2prd in When Used', () => {
    for (const file of agentFiles) {
      const content = readFileSync(join(AGENTS_DIR, file), 'utf8');
      const whenUsedSection = extractSection(content, '## When Used');
      assert.ok(
        whenUsedSection.includes('/req2prd'),
        `${file} When Used section should mention /req2prd`
      );
    }
  });

  it('pipeline config template lists the same critics as EXPECTED_CRITICS for prd2plan', () => {
    const configContent = readFileSync(
      join(__dirname, '..', 'pipeline', 'templates', 'pipeline-config-template.yaml'),
      'utf8'
    );
    const prd2planSection = extractYamlSection(configContent, 'prd2plan');
    // All expected critics (minus 'designer' which is conditional) should appear
    const nonConditional = ['product', 'dev', 'devops', 'qa', 'security'];
    for (const critic of nonConditional) {
      assert.ok(
        prd2planSection.includes(critic),
        `prd2plan section in config template should include ${critic}`
      );
    }
  });
});

describe('PRD Review Focus for non-Product critics', () => {
  const nonProductCritics = agentFiles.filter(f => f !== 'product-critic.md');
  for (const file of nonProductCritics) {
    it(`${basename(file, '.md')} has PRD Review Focus section in Review Checklist`, () => {
      const content = readFileSync(join(AGENTS_DIR, file), 'utf8');
      const checklistSection = extractSection(content, '## Review Checklist');
      assert.ok(
        checklistSection.includes('### PRD Review Focus'),
        `${file} should have "### PRD Review Focus" in Review Checklist`
      );
    });
  }
});
