# Issue #366 — New cited evidence since latest E-O-R-C version

## Objective and constraints
Keep every authorized live citation visible in the existing Workbench and mark only citations absent from the latest registered version's citation set. Capture citation UUID identity atomically at version registration under the existing target lock, encrypt the baseline with the clinical-record DEK, and never expose excerpt/plaintext in metadata, audit, or outbox. Removed or legally deleted citations are never live; authorization remains patient-scoped. No registered version means all current citations are initial context, with no invented historical baseline. Pre-existing versions without a captured baseline are also treated as unknown/initial context rather than inferred from timestamps. No E-O-R-C text diff or major UI.

## Setup and strategy
- Branch `feat/366-new-cited-evidence`, base `7b2e800` (`origin/main`, includes #363). Existing unrelated branch left untouched.
- TDD: ON, explicitly selected by user for #366; observe RED before source implementation, GREEN after. Runner: `MIX_TEST_PARTITION=_366_evidence mix test <test path>` using project test alias to create/migrate isolated `alethea_test_366_evidence` (do not run plain default-db tests). Database is local; never drop an existing database. Read `mix help test` before running.
- Delivery: user chose `stacked-to-main` after T1 exceeded the ~400-line forecast. T1 branch `feat/366-new-cited-evidence` targets `main`; T2 will branch from T1 and target T1. No PR opened or push authorized. Tests and behavior in each commit; do not trim coverage to hit a size heuristic.
- Verification gate: focused domain/Workbench tests on isolated DB, then `mix precommit` after all changes; assess formatter's potential global churn first and report if the alias cannot safely be run as-is. Runtime boundary: authenticated Workbench LiveView integration test. Rollback: revert unit commits in reverse order; only #366 migration/version-baseline and UI marker behavior are in scope.

## Tasks
- [ ] **T1 — Persist encrypted citation baseline at registration.** Route: delegated writer (schema + context + migration + integration tests). Migration generated via `mix ecto.gen.migration`; locked registration captures live citation IDs, encrypts via clinical DEK; authorized reads expose redacted virtual IDs and fail closed on corrupt payload; legacy rows nullable. Semantic RED 3 failures, GREEN 14/0; independent isolated focused rerun 14/0 before final UUID validation refinement, writer final rerun 14/0. Runtime harness: real ClinicalRecord/DB registration and legal deletion via integration tests. Rollback boundary: migration, version schema, context and focused version tests. Commit and risk assessment pending.
- [ ] **T2 — Mark new live citations in existing Workbench timeline.** Route: delegated writer (LiveView + LiveView integration tests). Load latest authorized baseline on mount and timeline refresh, mark only live citations absent from it; no-version/legacy nil baseline keeps all citations as unmarked context. Refresh on registration and deletion; no large UI. RED/GREEN, focused test result, parent spot check, final checks required. Commit one coherent unit, record SHA and assessed native risk/outcome.

## Current progress
- #363 prerequisite confirmed merged in `origin/main` as `7b2e800`.
- Read-only map identified `FunctionalAnalysisVersion`, `ClinicalRecord.register_functional_analysis_version/5`, `review_timeline/3`, and `TargetBehaviorLive.Review` as seams.
- Next: confirm final T1 spot check, commit T1 as first stacked slice, assess risk and native review route; then branch T2 from T1.
