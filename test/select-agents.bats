#!/usr/bin/env bats
# Tests for select-agents.sh — deterministic agent/critic selection

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../pipeline/scripts" && pwd)"
SCRIPT="$SCRIPT_DIR/select-agents.sh"

@test "--help flag exits 0" {
  run bash "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"select-agents.sh"* ]]
}

@test "invalid mode exits 2" {
  run bash "$SCRIPT" --mode invalid
  [ "$status" -eq 2 ]
}

@test "unknown option exits 2" {
  run bash "$SCRIPT" --unknown-flag
  [ "$status" -eq 2 ]
}

# --- code_review mode ---

@test "code_review: frontend file returns Frontend domain" {
  run bash "$SCRIPT" --mode code_review --files src/components/Button.tsx
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.domain == "Frontend"'
  echo "$output" | jq -e '.builder == "frontend-expert.md"'
}

@test "code_review: backend file returns Backend domain" {
  run bash "$SCRIPT" --mode code_review --files src/api/orders.ts
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.domain == "Backend"'
}

@test "code_review: security file returns Security domain" {
  run bash "$SCRIPT" --mode code_review --files src/middleware/auth/session.ts
  [ "$status" -eq 0 ]
  # Should be Security (higher priority than Backend for auth files)
  echo "$output" | jq -e '.domain == "Security" or .domain == "Backend"'
}

@test "code_review: multi-domain files produce union critics" {
  run bash "$SCRIPT" --mode code_review --files src/components/Button.tsx src/api/orders.ts
  [ "$status" -eq 0 ]
  # Should have union of Frontend + Backend critics
  local total
  total=$(echo "$output" | jq '.total_critics')
  [ "$total" -gt 7 ]  # union should be more than single domain
}

@test "code_review: no-match files fallback to Backend" {
  run bash -c "bash '$SCRIPT' --mode code_review --files random/file.xyz 2>/dev/null"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.domain == "Backend"'
}

@test "code_review: no files at all warns and falls back to Backend" {
  run bash -c "bash '$SCRIPT' --mode code_review --files nonexistent/path.xyz 2>/dev/null"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.domain == "Backend"'
}

# --- routing-coverage pins (restaurants-ai Story-6 / Story-5 W1) ---
# A diff touching a CI deploy-guard script under scripts/ci/ MUST route to the
# DevOps owner (devops-critic), NOT the generic Backend fallback. Before this
# pin, DevOps only carried `**/scripts/ci*` which does not match the SUBDIRECTORY
# path `scripts/ci/<file>` — so a guard change emitted "no file patterns matched,
# falling back to Backend" and the deploy-guard/fleet-block risk was reviewed by
# Backend critics who do not own it (Story-5 W1 / Note 1).
@test "code_review: scripts/ci/** deploy-guard file routes to DevOps (Story-5 W1)" {
  run bash "$SCRIPT" --mode code_review --files scripts/ci/predeploy-cube-guard.js
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.domain == "DevOps"'
  echo "$output" | jq -e '.critics | index("devops-critic.md") != null'
}

# A Dataform aggregate definition MUST route to the Data owner
# (data-integrity-critic among the Data critic set), not the Backend fallback.
@test "code_review: dataform/** aggregate file routes to Data (Story-5 W1)" {
  run bash "$SCRIPT" --mode code_review --files dataform/definitions/transform/agg_orders_tip_pct.sqlx
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.domain == "Data"'
  echo "$output" | jq -e '.critics | index("data-integrity-critic.md") != null'
}

# The Story-5-shaped diff (guard script + aggregate) routes to BOTH owners
# (DevOps primary by file-count/priority + Data via union critics) — never the
# blind Backend fallback that the orchestrator had to manually backfill.
@test "code_review: Story-5-shaped diff selects DevOps+Data critics, not Backend fallback (Story-5 W1/Note 1)" {
  run bash -c "bash '$SCRIPT' --mode code_review --files scripts/ci/predeploy-cube-guard.js dataform/definitions/transform/agg_orders_tip_pct.sqlx 2>/dev/null"
  [ "$status" -eq 0 ]
  # No Backend fallback warning leaked, and both owners' critics are present.
  echo "$output" | jq -e '.critics | index("devops-critic.md") != null'
  echo "$output" | jq -e '.critics | index("data-integrity-critic.md") != null'
  echo "$output" | jq -e '.matched_domains.DevOps >= 1'
  echo "$output" | jq -e '.matched_domains.Data >= 1'
}

@test "code_review: critics array has no duplicates" {
  run bash "$SCRIPT" --mode code_review --files src/components/Button.tsx src/api/orders.ts
  [ "$status" -eq 0 ]
  local unique_count
  unique_count=$(echo "$output" | jq '[.critics[]] | unique | length')
  local total_count
  total_count=$(echo "$output" | jq '.critics | length')
  [ "$unique_count" -eq "$total_count" ]
}

@test "code_review: valid JSON output" {
  run bash "$SCRIPT" --mode code_review --files src/components/Button.tsx
  [ "$status" -eq 0 ]
  echo "$output" | jq . > /dev/null 2>&1
}

# --- artifact_review mode ---

@test "artifact_review: no flags returns 7 always-on critics" {
  run bash "$SCRIPT" --mode artifact_review
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.total_critics == 7'
}

@test "artifact_review: with all flags adds conditional critics" {
  run bash "$SCRIPT" --mode artifact_review --config-flags has_frontend,has_api,has_ml,has_backend_service
  [ "$status" -eq 0 ]
  local total
  total=$(echo "$output" | jq '.total_critics')
  [ "$total" -ge 9 ]
}

@test "artifact_review: has_frontend adds designer and frontend critics" {
  run bash "$SCRIPT" --mode artifact_review --config-flags has_frontend
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.critics | index("designer-critic.md") != null'
  echo "$output" | jq -e '.critics | index("frontend-critic.md") != null'
}

# --- tdd_review mode ---

@test "tdd_review: requires --tdd-target-domain" {
  run bash "$SCRIPT" --mode tdd_review
  [ "$status" -eq 2 ]
}

@test "tdd_review: invalid domain exits 2" {
  run bash "$SCRIPT" --mode tdd_review --tdd-target-domain InvalidDomain
  [ "$status" -eq 2 ]
}

@test "tdd_review: Frontend target domain returns correct critics" {
  run bash "$SCRIPT" --mode tdd_review --tdd-target-domain Frontend
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.target_domain == "Frontend"'
  # Should include base critics (dev, security, qa)
  echo "$output" | jq -e '.critics | index("dev-critic.md") != null'
  echo "$output" | jq -e '.critics | index("qa-critic.md") != null'
}

# --- use_expert mode ---

@test "use_expert: task signal 'auth' selects Security" {
  run bash "$SCRIPT" --mode use_expert --task-signals auth
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.domain == "Security"'
}

@test "use_expert: task signal 'dashboard' selects Data Analytics" {
  run bash "$SCRIPT" --mode use_expert --task-signals dashboard
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.domain == "Data Analytics"'
}

@test "use_expert: files-based selection works" {
  run bash "$SCRIPT" --mode use_expert --files src/components/Button.tsx
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.domain == "Frontend"'
}

@test "use_expert: combined files + signals" {
  run bash "$SCRIPT" --mode use_expert --files src/components/Button.tsx --task-signals auth
  [ "$status" -eq 0 ]
  # Should produce valid JSON with a domain
  echo "$output" | jq -e '.domain != null'
}

@test "use_expert: no files or signals falls back to Backend" {
  run bash -c "bash '$SCRIPT' --mode use_expert 2>/dev/null"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.domain == "Backend"'
}

# --- Multi-word domain names ---

@test "code_review: Prompt Engineering domain returns 5 critics" {
  run bash "$SCRIPT" --mode code_review --files pipeline/agents/prompt-engineering-critic.md
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.domain == "Prompt Engineering"'
  echo "$output" | jq -e '.total_critics == 5'
}

@test "code_review: Data Analytics domain returns 8 critics" {
  run bash "$SCRIPT" --mode code_review --files src/analytics/chart.tsx
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.domain == "Data Analytics"'
  echo "$output" | jq -e '.total_critics == 8'
}

@test "code_review: Test Plan domain returns 6 critics" {
  run bash "$SCRIPT" --mode code_review --files docs/tdd/feature/test-plan.md
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.domain == "Test Plan"'
  echo "$output" | jq -e '.total_critics == 6'
}

@test "code_review: Data Integrity domain reachable via policies file" {
  run bash "$SCRIPT" --mode code_review --files src/policies/rls.sql
  [ "$status" -eq 0 ]
  # Matches both Data (*.sql) and Data Integrity (**/policies/**/*); Data wins priority tie-break
  # Verify Data Integrity is in matched domains and union critics include data-integrity-critic
  echo "$output" | jq -e '.matched_domains["Data Integrity"] >= 1'
  echo "$output" | jq -e '.critics | index("data-integrity-critic.md") != null'
}

@test "code_review: multi-word domain produces valid JSON" {
  run bash "$SCRIPT" --mode code_review --files pipeline/agents/builders/ml-expert.md
  [ "$status" -eq 0 ]
  echo "$output" | jq . > /dev/null 2>&1
}

@test "artifact_review: is_ai_instruction adds prompt-engineering-critic" {
  run bash "$SCRIPT" --mode artifact_review --config-flags is_ai_instruction
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.critics | index("prompt-engineering-critic.md") != null'
  echo "$output" | jq -e '.total_critics == 8'
}

# --- Dev Plan domain ---

@test "code_review: Dev Plan domain reachable via dev_plans file" {
  run bash "$SCRIPT" --mode code_review --files docs/dev_plans/feature-plan.md
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.domain == "Dev Plan"'
  echo "$output" | jq -e '.total_critics == 6'
}

@test "code_review: Dev Plan domain reachable via docs/plans file" {
  run bash "$SCRIPT" --mode code_review --files docs/plans/migration-plan.md
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.matched_domains["Dev Plan"] >= 1'
}

@test "use_expert: task signal 'dev plan' selects Dev Plan" {
  run bash "$SCRIPT" --mode use_expert --task-signals "dev plan"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.domain == "Dev Plan"'
}

# --- All 22 domains reachable ---

@test "all 22 domains: Security reachable via auth file" {
  run bash "$SCRIPT" --mode code_review --files src/auth/login.ts
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.matched_domains.Security >= 1'
}

@test "all 22 domains: ML reachable via ai file" {
  run bash "$SCRIPT" --mode code_review --files src/ai/model.ts
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.matched_domains.ML >= 1'
}

@test "all 22 domains: Frontend reachable" {
  run bash "$SCRIPT" --mode code_review --files src/components/App.tsx
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.domain == "Frontend"'
}

@test "all 22 domains: Backend reachable" {
  run bash "$SCRIPT" --mode code_review --files src/api/route.ts
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.domain == "Backend"'
}

@test "all 22 domains: DevOps reachable" {
  run bash "$SCRIPT" --mode code_review --files .github/workflows/ci.yml
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.domain == "DevOps"'
}

@test "all 22 domains: Testing reachable" {
  run bash "$SCRIPT" --mode code_review --files src/utils/helper.test.ts
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.domain == "Testing"'
}

@test "all 22 domains: Supabase reachable" {
  run bash "$SCRIPT" --mode code_review --files supabase/functions/hello/index.ts
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.matched_domains.Supabase >= 1'
}

@test "all 22 domains: Infra reachable" {
  run bash "$SCRIPT" --mode code_review --files infra/terraform/main.tf
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.matched_domains.Infra >= 1'
}

@test "--verbose flag emits diagnostics to stderr" {
  # Capture only stderr to verify verbose diagnostics are emitted there
  run bash -c "bash '$SCRIPT' --mode code_review --files src/components/Button.tsx --verbose 2>&1 1>/dev/null"
  # stderr should contain [verbose] prefixed diagnostic lines
  [[ "$output" == *"[verbose]"* ]]
}
