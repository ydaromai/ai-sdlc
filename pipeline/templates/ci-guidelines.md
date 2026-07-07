# CI/CD Guidelines — Build Minutes Optimization

Reference document for generating and reviewing CI/CD workflows.
All GitHub Actions workflows MUST follow these rules.

## Trigger Rules

1. **CI workflows** (lint, test, typecheck, build) use `pull_request` trigger ONLY — never `push`
   - Deploy workflows handle `push` to `main`
   - This prevents double CI runs on every merge

2. **Branch scope**: Always restrict to `[main]` — never use `'**'` (all branches)

3. **Path filters**: Always include `paths-ignore` on CI workflows:
   ```yaml
   paths-ignore:
     - 'docs/**'
     - '*.md'
     - '.github/**/*.md'
   ```

4. **Concurrency**: Always add to prevent stacking runs:
   ```yaml
   concurrency:
     group: ci-${{ github.ref }}
     cancel-in-progress: true
   ```

## Vercel Integration

- If the project deploys to Vercel via GitHub Actions (not Git integration), add to `vercel.json`:
  ```json
  { "ignoreCommand": "exit 0" }
  ```
  This prevents Vercel's Git integration from also triggering a build (double builds).

- If the project relies on Vercel's Git integration for deploys (no GH Actions deploy), do NOT add `ignoreCommand`.

## Deploy Workflows

- Deploy workflows trigger on `push` to `main` — this is correct
- Do NOT re-run lint/test/typecheck in deploy workflows if a CI workflow already gates PRs
- If deploy needs CI gate, use `workflow_call` to reuse the CI workflow (counts minutes once)

## Scheduled Workflows

- Never use intervals shorter than 30 minutes (`*/30 * * * *`) unless there's a strong justification
- Edge function warmup: `*/30` is sufficient — cold starts are typically < 5s
- Consider whether scheduled work can be done via pg_cron, Supabase cron, or external services instead of GitHub Actions

## Job Structure

- Prefer fewer jobs with sequential steps over many parallel jobs that each do `npm ci`
- Each job pays the setup tax (checkout + install). A single job running lint → typecheck → test → build is cheaper than 4 parallel jobs
- Exception: when job independence matters for partial failure visibility, parallel is OK — but use dependency caching

## Caching

- Always cache dependencies (`cache: pnpm` or `cache: npm` in setup-node)
- For Turborepo projects, cache `.turbo` directory
- For Playwright, cache `~/.cache/ms-playwright`

## Template: Minimal CI Workflow

```yaml
name: CI

on:
  pull_request:
    branches: [main]
    paths-ignore:
      - 'docs/**'
      - '*.md'
      - '.github/**/*.md'

concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: true

jobs:
  ci:
    name: Lint, Test & Build
    runs-on: ubuntu-latest
    timeout-minutes: 15
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: 20
          cache: npm
      - run: npm ci
      - run: npm run lint
      - run: npx tsc --noEmit
      - run: npm test
      - run: npm run build
```
