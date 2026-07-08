# /scaffold — Foundation Scaffold Stage

You are executing the **scaffold** stage. This stage prepares a new venture project by forking the Foundation starter project and configuring it for the specific venture.

**Input:** Approved dev plan + pipeline.config.yaml with foundation settings
**Output:** A working, deployed baseline project — ready for domain code

---

## Prerequisites

- `assumes_foundation: true` in pipeline.config.yaml
- `foundation.repo_url` in pipeline.config.yaml (default: the Foundation repo URL)
- `foundation.target_dir` in pipeline.config.yaml (the venture's project directory)
- Approved dev plan exists at the configured path

---

## Steps

### Step 1: Read Configuration

Read `pipeline.config.yaml` and extract:
- `foundation.repo_url` — the Foundation repo to fork/clone
- `foundation.target_dir` — where to create the venture project
- `foundation.venture_name` — the venture's name (used for renaming)
- `foundation.supabase_project_ref` — Supabase project reference (optional, can link later)
- `foundation.roles` — custom role definitions if different from defaults (admin/manager/viewer)

Validate all required fields are present. If missing, halt and report which fields need to be added.

### Step 2: Fork/Clone Foundation

1. Clone the foundation repo into the target directory:
   ```bash
   git clone <repo_url> <target_dir>
   cd <target_dir>
   rm -rf .git
   git init
   ```
2. If a remote is configured (`foundation.remote_url`), add it:
   ```bash
   git remote add origin <remote_url>
   ```

### Step 2.5: Configure Ports (optional)

The Foundation starter ships with sensible default ports (Supabase local defaults, dev server on the framework default). Skip this step unless you need explicit ports — e.g. to run several projects in parallel without collisions.

If `foundation.ports` is set in `pipeline.config.yaml`, patch the scaffolded project to use those values (otherwise leave the Foundation defaults as-is):

1. **Patch Supabase config.toml** (only if `supabase/config.toml` exists) with the configured ports:
   - `[api] port`, `[db] port`, `[studio] port`
   - `[auth] site_url` → `http://127.0.0.1:<app-port>`
   - `[auth] additional_redirect_urls` → update port references
   - All other Supabase port fields (shadow, pooler, inbucket, analytics, inspector)
2. **Patch app config** — point Playwright, Vite, or Next.js at the configured port via an env var with the default as fallback:
   - Playwright: `baseURL` and `webServer.url` → `process.env.BASE_URL || 'http://localhost:<app-port>'`
   - Vite: `server.port` → `parseInt(process.env.PORT || '<app-port>')`
   - Next.js: reads `PORT` env var natively — no code change needed

### Step 3: Configure for Venture

Apply venture-specific configuration:

1. **Rename project:**
   - Update `package.json`: name, description
   - Update `README.md`: project name, description
   - Update any Vercel project references

2. **Generate environment file:**
   - Copy `.env.example` to `.env.local`
   - Fill in venture-specific values from pipeline.config.yaml, using the configured or default ports:
     - `NEXT_PUBLIC_SUPABASE_URL` → `http://127.0.0.1:<supabase-api-port>`
     - `SUPABASE_DB_URL` → `postgresql://postgres:postgres@127.0.0.1:<supabase-db-port>/postgres`
     - `NEXT_PUBLIC_SUPABASE_ANON_KEY`
     - Any other required env vars

3. **Link Supabase project (if ref provided):**
   ```bash
   supabase link --project-ref <supabase_project_ref>
   ```

4. **Update role definitions (if custom roles):**
   - Modify `src/lib/roles.ts` with venture-specific roles
   - Update seed data if roles changed
   - Update any role-based UI components

5. **Install dependencies:**
   ```bash
   npm install
   ```

### Step 4: Verify Foundation Works

Run verification checks to ensure the scaffolded project is healthy:

1. **Build check:**
   ```bash
   npm run build
   ```
   Must exit 0.

2. **Lint check:**
   ```bash
   npm run lint
   ```
   Must exit 0.

3. **Unit tests:**
   ```bash
   npm test
   ```
   Must pass (66+ tests from foundation).

4. **Type check:**
   ```bash
   npx tsc --noEmit
   ```
   Must exit 0.

If any check fails, report the failure and halt. Do not proceed to execution with a broken baseline.

### Step 5: Initial Commit

Create the initial commit for the venture:
```bash
git add -A
# Safety check: ensure .env files are not staged (covers nested paths in monorepos)
git diff --cached --name-only | grep -iE '\.env|\.pem$|\.key$|credentials\.json|serviceAccountKey' | xargs -r git reset HEAD -- 2>/dev/null || true
git diff --cached --name-only | grep -iE '\.env|\.pem$|\.key$|credentials\.json|serviceAccountKey' && { echo "ERROR: secret file still staged after unstage attempt — review .gitignore before committing"; exit 1; } || true
git commit -m "scaffold: initialize <venture_name> from foundation"
```

If a remote is configured, push:
```bash
git push -u origin main
```

### Step 6: Report

Return:
1. Venture name and target directory
2. Verification results (build, lint, tests, typecheck)
3. Whether Supabase was linked
4. Whether custom roles were applied
5. Whether remote was configured and pushed
6. Any warnings or issues

---

## Error Handling

- **Clone fails:** Check repo URL, network connectivity, permissions
- **Build fails:** Foundation may have been updated with breaking changes. Report the error and suggest checking foundation repo for recent changes.
- **Supabase link fails:** Non-blocking. Report as warning — user can link manually later.
- **Tests fail:** Blocking. Foundation tests must pass before domain code is added.

---

## Pipeline Config Schema

Add these fields to `pipeline.config.yaml`:

```yaml
pipeline:
  assumes_foundation: true    # Enable foundation-aware pipeline behavior

  foundation:
    repo_url: "https://github.com/user/foundation.git"  # Foundation repo
    target_dir: "../my-venture"                           # Where to scaffold
    venture_name: "My Venture"                            # Project display name
    supabase_project_ref: ""                              # Optional Supabase ref
    remote_url: ""                                        # Optional git remote
    roles:                                                # Custom roles (optional)
      - admin
      - manager
      - viewer
```
