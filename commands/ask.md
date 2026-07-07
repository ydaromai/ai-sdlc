# /ask — Ask anything, change nothing

You are executing the **ask** command. Answer any question the user has — about the codebase, architecture, debugging, dependencies, best practices, or anything else — using only read-only tools. Never create, modify, or delete files.

**Input:** A question via `$ARGUMENTS`
**Output:** A clear, structured answer with references. No files created or modified.

**Usage:**
- `/ask How does the validate skill work?`
- `/ask What npm packages does this project use?`
- `/ask What is the latest Node.js LTS version?`
- `/ask Where are JIRA tickets created in the pipeline?`

---

## Hard Rule: Read-Only

**ALLOWED tools:**
- Read, Glob, Grep — explore files and search the codebase
- WebFetch, WebSearch — look things up online
- Task (Explore subagent only) — deep multi-file research
- AskUserQuestion — clarify the question if needed
- Bash (read-only commands only) — `git log`, `git diff`, `git status`, `ls`, `cat`, `node -e`, `npm list`, `jq`, `wc`, etc.

**FORBIDDEN — do NOT use under any circumstances:**
- Write, Edit, NotebookEdit — never create or modify files
- Bash commands that modify state — no `git commit`, `git push`, `git checkout`, `git reset`, `rm`, `mkdir`, `mv`, `cp`, `touch`, `npm install`, `npm run`, `brew`, `chmod`, `chown`, or any command that writes to disk
- Task with code-writing subagents — no feature-dev, code-architect, or similar
- Skill tool — do not chain into other skills

If the question asks you to make changes, **refuse politely** and suggest using the appropriate skill instead (e.g., `/use-expert` for code changes, `/execute-plan` to run a dev plan, `/req2prd` for PRD creation).

---

## Step 1: Understand the question

Parse `$ARGUMENTS` and classify the question type:

| Type | Signals | Primary tools |
|------|---------|---------------|
| **Codebase** | "where is", "how does X work", "what does this do" | Read, Glob, Grep, Task/Explore |
| **Architecture** | "how are things structured", "what pattern", "flow" | Read, Glob, Grep, Task/Explore |
| **Dependency** | "what packages", "what version", "npm", "dependencies" | Read (`package.json`, lock files), Bash (`npm list`) |
| **Git/history** | "when was", "who changed", "last commit", "diff" | Bash (`git log`, `git diff`, `git blame`) |
| **External/web** | "latest version of", "best practice for", "how to" | WebSearch, WebFetch |
| **Debugging** | "why does X fail", "what's wrong with" | Read, Grep, Bash (read-only inspection) |
| **Config/infra** | "what env vars", "how is CI set up", "Docker" | Read, Glob, Grep |

If the question is ambiguous, use AskUserQuestion to clarify before researching.

## Step 2: Research

Gather the information needed to answer the question:

1. **Codebase questions** — Use Glob to find relevant files, Read to examine them, Grep to trace references. For complex questions spanning many files, use the Task tool with an Explore subagent.

2. **Web questions** — Use WebSearch to find current information, then WebFetch to read specific pages if needed. Always include source URLs in your answer.

3. **Mixed questions** — Combine both approaches as needed.

Keep research focused. Don't read every file in the repo — target only what's relevant to the question.

## Step 3: Answer

Present a clear, structured answer:

- **Lead with the direct answer** — don't bury it under context
- **Reference specific files** using `path/to/file.js:42` format so the user can navigate directly
- **Quote key code snippets** when they clarify the answer (keep them short)
- **Include source URLs** for any web-sourced information, in a `Sources:` section at the end
- **Suggest next steps** if the question implies the user wants to take action (point them to the right skill)

If you cannot find the answer, say so clearly rather than guessing.
