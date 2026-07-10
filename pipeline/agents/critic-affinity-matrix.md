# Critic Affinity Matrix

> **NOTE:** The programmatic source of truth for critic selection is `pipeline/scripts/agent-config.json` with `pipeline/scripts/select-agents.sh`. This file is retained as human-readable documentation and fallback for when the script is unavailable. New domains SHOULD be added to agent-config.json first; update this file to keep it in sync.

Human-readable reference for which critics review which builder domains. For programmatic selection, use `select-agents.sh`. This file is retained as documentation and fallback.

---

## How to Use

### Code Review (execute, use_expert, tdd-develop-tests, tdd-develop-tier2-tests)
1. Identify the builder domain (from domain routing in execute.md Step 3b, or task analysis)
2. Look up the domain in the **Code Review Matrix** below
3. Spawn ONLY the listed critics (core + domain-matched)

### Artifact Review (req2prd, prd2plan)
Use the **Artifact Review** section — all critics with PRD/Plan review checklists apply.

### Standalone Validation (/validate)
- If `--domain <Domain>` is provided → use Code Review Matrix for that domain
- If target is a PRD/Plan file → use Artifact Review section
- If target is a code diff without domain → infer domain from file patterns (same rules as execute.md Step 3b Domain Expert Selection table)
- If `--all` flag → use all 20 critics (override matrix)

### TDD Test Review (tdd-develop-tests, tdd-develop-tier2-tests)
Use "Testing" domain (3 core) PLUS the domain of the **code under test** (inferred from the test plan's target file patterns using execute.md Step 3b routing table). Example: tests targeting `src/components/**` → Testing core (3) + Frontend domain critics (3) = 6 total.

---

## Code Review Matrix

### Core Critics (always included)

| Critic | Persona File | Why Always-On |
|--------|-------------|---------------|
| **Dev** | `dev-critic.md` | Code quality, patterns, conventions |
| **Security** | `security-critic.md` | Security is non-negotiable |
| **QA** | `qa-critic.md` | Test coverage, test quality |
| **Product** | `product-critic.md` | PRD alignment for user-facing features |

**Product Critic Exceptions** — excluded for infrastructure-only domains where tasks don't map to PRD user stories:
- Infra, DevOps, Testing, Observability, Dependencies → core = **Dev + Security + QA (3)**
- All other domains → core = **Dev + Security + QA + Product (4)**
- Note: Security domain **keeps** Product critic because security tasks often touch user-facing auth flows (login, signup, password reset) that must align with PRD requirements

### Domain-Matched Critics

| Builder Domain | Domain Critics (beyond core) | Total |
|---|---|---|
| **Frontend** | frontend-critic, designer-critic, performance-critic | **7** |
| **Backend** | performance-critic, api-contract-critic, observability-critic, dependency-critic | **8** |
| **Data** | data-critic, data-integrity-critic, performance-critic | **7** |
| **Data Analytics** | data-analytics-critic, data-critic, performance-critic, designer-critic | **8** |
| **AI Data Analytics** | ai-data-analytics-critic, data-analytics-critic, ml-critic, performance-critic | **8** |
| **Infra** | infra-critic, devops-critic | **5** |
| **Security** | data-integrity-critic, dependency-critic | **6** |
| **ML** | ml-critic, performance-critic | **6** |
| **Testing** | *(core covers it)* | **3** |
| **DevOps** | devops-critic, infra-critic, observability-critic, dependency-critic | **7** |
| **Designer** | designer-critic, frontend-critic | **6** |
| **Performance** | performance-critic, observability-critic | **6** |
| **Product** | designer-critic | **5** |
| **API** | api-contract-critic, performance-critic | **6** |
| **Observability** | observability-critic, devops-critic, performance-critic | **6** |
| **Data Integrity** | data-integrity-critic, data-critic, supabase-critic, performance-critic | **8** |
| **Integration** | integration-critic, api-contract-critic, performance-critic | **7** |
| **Supabase** | supabase-critic, data-integrity-critic, data-critic, performance-critic | **8** |
| **Prompt Engineering** | prompt-engineering-critic | **5** |
| **Test Plan** | performance-critic, designer-critic | **6** |
| **PRD** | performance-critic, data-integrity-critic | **6** |
| **Dev Plan** | devops-critic, performance-critic | **6** |
| **Dependencies** | dependency-critic | **4** |

### Multi-Domain Tasks

When a task uses multiple builders (cross-domain), **UNION** the critic sets from all involved domains and deduplicate. Example: Frontend + Backend task → Dev, Security, QA, Product, frontend-critic, designer-critic, performance-critic, api-contract-critic, observability-critic, dependency-critic = **10 critics**.

**Dependencies domain routing note:** the Dependencies domain matches dependency manifests and lockfiles (`package.json`, `package-lock.json`, `requirements.txt`, `pyproject.toml`, `go.mod`, `Cargo.toml`, `Gemfile`, `pom.xml`, `build.gradle`, `composer.json`, and friends). In a mixed diff the code domain stays primary while Dependencies contributes `dependency-critic` via union — so any change that adds or bumps a package gets registry verification (anti-slopsquatting) automatically.

### Persona File Paths

All critic persona files are at: `{{AISDLC_ROOT}}/pipeline/agents/<name>-critic.md`

Full list:
- `product-critic.md`, `dev-critic.md`, `devops-critic.md`, `qa-critic.md`
- `security-critic.md`, `performance-critic.md`, `data-integrity-critic.md`
- `observability-critic.md`, `api-contract-critic.md`, `designer-critic.md`
- `frontend-critic.md`, `ml-critic.md`, `data-critic.md`
- `data-analytics-critic.md`, `ai-data-analytics-critic.md`, `infra-critic.md`
- `integration-critic.md`, `supabase-critic.md`, `dependency-critic.md`
- `prompt-engineering-critic.md`

---

## Artifact Review (PRD, Dev Plan)

When reviewing PRDs or Dev Plans (not code), use ALL critics that have a **PRD Review Focus** section. These artifacts are cross-domain by nature and benefit from comprehensive review.

### Always-on for artifact review

| Critic | Reviews |
|--------|---------|
| Product | Requirements completeness, scope, user stories |
| Dev | Technical feasibility, architecture, task granularity |
| DevOps | Deployment considerations, environment requirements |
| QA | Testability, acceptance criteria, test strategy |
| Security | Security requirements, threat model |
| Performance | Performance requirements, scalability expectations |
| Data Integrity | Data model, migration safety, referential integrity |

### Conditional for artifact review (based on pipeline.config.yaml)

| Critic | Condition |
|--------|-----------|
| Observability | `has_backend_service: true` |
| API Contract | `has_api: true` |
| Designer | `has_frontend: true` |
| Frontend | `has_frontend: true` |
| ML | `has_ml: true` |
| Prompt Engineering | artifact being reviewed IS an AI instruction file (agent persona, command definition, or constraint doc in `pipeline/agents/**`, `commands/**`, or `docs/ai_definitions/**`) |

### Not used for artifact review

Data, Data Analytics, AI Data Analytics, Infra, Integration, Supabase, Dependency — these are code-review-only critics for artifact purposes. Dependency Critic runs where dependency changes actually land (manifests and lockfiles in code review), not on PRDs/plans — its PRD Review Focus is exercised only when it is explicitly included (e.g., via `/validate --critics=dependency`).

---

## Quick Reference

```
Code review:  3-8 critics per task (domain-matched)
Artifact review: 7-12 critics (comprehensive, cross-domain)
Standalone /validate: follows code or artifact rules based on target type
TDD test review: 3 core + target domain critics
```
