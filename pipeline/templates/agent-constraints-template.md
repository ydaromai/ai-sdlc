# Universal Agent Constraints

**Version:** 1.0.0
**Status:** Active
**Scope:** All AI agents across all tasks

---

## Overview and Philosophy

This document defines the **universal behavioral constraints** that govern all AI agents working on this project. These constraints ensure:

- **Safety:** Agents cannot deviate from assigned scope or introduce breaking changes
- **Quality:** All code meets minimum standards for testing, coverage, and maintainability
- **Consistency:** All agents follow the same workflows, patterns, and conventions
- **Traceability:** All work is linked to JIRA, tracked in git, and auditable
- **Recoverability:** Failures are detected, reported, and escalated appropriately

---

## Core Behavioral Rules

### 1. Scope Enforcement

**Rule:** Agents MUST NOT modify files outside their explicit scope.

#### Allowed Modifications

Agents may modify:

1. **Explicitly Listed Files:** All files listed in the subtask's "Files to Create/Modify" section
2. **Test Files:** Any files in `test/` or `__tests__/` directory that test the code being created/modified
3. **Documentation:** `README.md` or files in `docs/` when implementation changes require doc updates
4. **Permission Required:** Any other files require explicit coordinator approval

#### Forbidden Actions

Agents MUST NOT:

- Modify files in different stories or tasks
- Refactor existing code "while we're here"
- Change unrelated functionality
- Skip required tests or validation steps
- Create files in unauthorized directories

---

### 2. Bug Discovery and Handling

**Rule:** When agents encounter bugs in existing code, they MUST fix them.

#### Bug Discovery Protocol

When an agent discovers a bug:

1. **Document:** Note the bug (file, line number, symptoms, impact)
2. **Fix:** Implement the fix as part of current work
3. **Test:** Add or update tests to prevent regression
4. **Commit:** Document the fix in commit message
5. **Report:** Add bug details and fix to PR description

---

### 3. Git Workflow Standards

#### Branch Naming Convention

```
feat/story-{S}-task-{T}-{slug}
```

#### Commit Style: Granular

- Create one commit per logical subtask completion
- Do NOT squash commits during development

#### Commit Message Format

Use **Conventional Commits** format:

```
{type}({scope}): {brief description}

{detailed explanation of what and why}

JIRA: {TASK-KEY}
```

**Types:** feat, fix, test, docs, refactor, chore

#### Commit Validation

Before committing, agents MUST verify:
- All tests pass
- Linting is clean
- No `console.log` or `debugger` statements in production code
- No secrets or credentials in files
- Commit message follows format

---

### 4. Pull Request Process

#### PR Title Format

```
[TASK-{S}.{T}] {Brief description}
```

#### PR Creation Checklist

Before creating a PR, agent MUST complete:

- [ ] All subtasks in task completed
- [ ] All tests passing
- [ ] Linting clean
- [ ] All acceptance criteria met
- [ ] Documentation updated if needed
- [ ] No scope violations

---

### 5. Testing Requirements

#### Test Execution

Agents MUST run all relevant test commands as defined in `pipeline.config.yaml`.

#### Test Failure Handling

If tests fail:
1. Analyze error, fix code, retry
2. Up to 3 attempts
3. After 3 failures: Escalate with WIP PR

---

### 6. Code Quality Standards

#### Prohibited Patterns

**NEVER allowed in production code:**
- `console.log()` or `debugger` statements
- Hardcoded secrets or credentials
- Magic numbers (use named constants)
- Commented-out code (delete it)

---

### 7. Security Requirements

#### Secrets Management

**Rule:** NEVER commit secrets to git.

- Reference environment variables
- Use `.env.local` files (gitignored)

#### Input Validation

- Validate all external inputs
- Use parameterized queries
- Sanitize user-provided data

---

### 8. Timeouts and Recovery

**Per Subtask:** Maximum 60 minutes

#### Escalation Process

When to escalate:
- Timeout exceeded (>60 minutes on subtask)
- Test failures after 3 retries
- Scope violation detected
- Unexpected blocker encountered

---

### 9. Project-Specific Patterns

> **Customize this section** for your project's tech stack, conventions, and patterns.
> Examples: framework conventions, database patterns, API design standards, i18n requirements.

---

### 10. Pre-Delivery Validation

Before presenting any PR or deliverable to the user, agents MUST verify:

- [ ] Dev server starts without errors
- [ ] Core user flow works end-to-end
- [ ] No console errors in browser (if frontend)
- [ ] All health check endpoints respond (if backend service)

---

## Summary: The Essential Rules

1. **Stay in scope:** Only modify allowed files
2. **Fix bugs:** If you find it, fix it
3. **Test everything:** All tests pass
4. **Follow git workflow:** Proper branches, commits, PRs
5. **60 minute timeout:** Escalate if stuck
6. **No secrets:** Ever. Use environment variables
7. **Quality first:** Linting, documentation
8. **Report blockers:** Clear, detailed, actionable
9. **One task = one PR:** No scope creep
10. **Pre-delivery validation:** Verify it works before presenting
