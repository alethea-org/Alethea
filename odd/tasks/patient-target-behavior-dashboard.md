# Patient target behavior dashboard access

## Objective

Expose each authorized patient's target behaviors directly from the patient dashboard and provide a stable path to the existing functional-analysis review workbench.

## Problem and why

The review workbench already exists, but its visible entry point is indirect and primarily appears through cited RAG consultation sources. Clinicians should be able to discover and open target behaviors from the patient's normal dashboard without relying on RAG or a known URL.

## Scope

- Add an authorized patient-scoped target-behavior listing API in `Alethea.ClinicalRecord`.
- Include decrypted descriptions and derived functional-analysis draft state without exposing draft contents.
- Render a "Conductas objetivo" section on the patient dashboard.
- Link each behavior to `/patients/:patient_id/target_behaviors/:id/review`.
- Explain the no-target-behavior state.
- Cover context scoping and LiveView listing/link/empty behavior.

## Constraints and non-goals

- Reuse the existing authenticated LiveView session and patient authorization boundary.
- Keep target-behavior queries in the clinical-record context; do not query `Repo` from the LiveView.
- Use a LiveView stream for the collection and a separate assign for emptiness.
- Do not add routes, migrations, schemas, new draft lifecycle fields, or expose draft body content.
- Technical artifacts remain in English; existing Spanish UI language is preserved.

## Testing configuration

- TDD mode: strict.
- Source: `openspec/config.yaml`.
- Runner: `mix test`.
- Required sequence per task: RED, GREEN, REFACTOR.
- Focused feature command: `mix test test/alethea/clinical_record_test.exs test/alethea_web/live/dashboard_live_test.exs`.

## Delivery and review

- Base feature branch / slice 1: `feature/292-target-behavior-dashboard`.
- Current branch / slice 2: `feature/292-target-behavior-dashboard-ui`.
- Initial review boundary: `a512f9650d038fc8a69d284a0c8df104a7517059`.
- Delivery strategy: `ask-on-risk`.
- Chain strategy: `stacked-to-main`, selected by the user after the forecast crossed 400 lines.
- Forecast: revised to 400–500 authored changed lines after TB-1 produced 282 committed lines including the feature document.
- Slice 1 boundary: `6d3cc29b6ecf3f56ee81508f3c67347d503de98c` (TB-1, targets `main`).
- Slice 2 boundary: `4ee20157280f91e3232506a3c70a0ad4eec8a0a8` (TB-2, initially targets slice 1, then retargets to `main` after slice 1 lands).
- Expected delivery: two stacked work-unit PR slices.
- Engram mirror: pending because the local Engram provider was unavailable during initialization.

## Tasks

- [x] **TB-1 — Add the authorized target-behavior listing API**
  - Status: completed and independently verified.
  - Route: delegated writer; multi-file write trigger (`lib` plus context tests).
  - RED: prove patient scoping, decrypted descriptions, deterministic ordering, derived draft state, empty results, and unauthorized access.
  - GREEN: add the smallest `ClinicalRecord.list_target_behaviors/2` implementation.
  - REFACTOR: reuse existing authorization/decryption helpers and avoid leaking draft bodies.
  - Checks: `mix test test/alethea/clinical_record_test.exs` — 61 passed in writer, parent spot check, and independent verifier runs; `git diff --check` passed.
  - Commit evidence: `6d3cc29b6ecf3f56ee81508f3c67347d503de98c` (`feat(clinical): list patient target behaviors`).
  - Native review assessment/outcome: assessment was unassessable due to a schema-incompatible native response; risk therefore failed closed to high verification. Independent verification passed, and native review lineage `review-03b45440ad3a0774` was approved and acknowledged.

- [x] **TB-2 — Render dashboard access and LiveView coverage**
  - Status: completed, committed, verified, and natively reviewed.
  - Route: delegated writer; multi-file write trigger (LiveView, template, and tests).
  - RED: prove visible listing, exact stable review link, saved-state summary, patient isolation through the authorized data path, and explanatory empty state.
  - GREEN: stream the target behaviors and render the identified dashboard section.
  - REFACTOR: keep stable DOM IDs and reuse existing dashboard presentation patterns.
  - TDD evidence: RED `mix test test/alethea_web/live/dashboard_live_test.exs` — 37 passed, 3 failed, 1 skipped; GREEN and refactor rerun — 40 passed, 1 skipped.
  - Checks: parent fallback run after two independent-verifier attempts were blocked by a false outside-turn mutation signal: dashboard tests 40 passed, 1 skipped; combined context/dashboard tests 101 passed, 1 skipped; `git diff --check` passed; Pi LSP diagnostics found no source/test findings and had no HEEx server.
  - Runtime harness: authenticated `Phoenix.LiveViewTest.live/2` exercised encrypted SQL-sandbox records, scoped rows, status labels, exact links, stream reset, and empty states; no external service.
  - Commit evidence: `4ee20157280f91e3232506a3c70a0ad4eec8a0a8` (`feat(dashboard): surface target behaviors`).
  - Native review assessment/outcome: assessment was unassessable due to a schema-incompatible native response and therefore failed closed to high verification. Native review lineage `review-9563b05a4453a77c` reviewed slice 2 against TB-1, was approved, and was acknowledged. Advisory `R3-silent-target-behavior-load-failure` is informational follow-up scope and did not open a correction.

## Acceptance criteria

- [x] A clinician can reach the functional-analysis workbench from the patient dashboard without using RAG.
- [x] The list contains only target behaviors belonging to the authorized patient.
- [x] Every behavior has a stable workbench link.
- [x] The empty state explains how target behaviors are created or appear.
- [x] LiveView tests cover listing, the correct link, and no behaviors.

## Progress and evidence

- Issue `#292` requirements inspected on 2026-09-16.
- Read-only repository mapping completed by `gentle-ai-explore`.
- No blocking product decision remained; draft state is derived from existing draft/tombstone data.
- Focused verification passed: 61 context tests, 40 dashboard tests with 1 skipped, and 101 combined tests with 1 skipped.
- Full-suite diagnosis passed serially with 1374 tests and 5 skipped after the first `mix precommit` attempt timed out intermittently.
- Final `mix precommit` passed with 1374 tests and 5 skipped; only pre-existing warnings and expected negative-path logs were emitted.
- Both work-unit commits received approved and acknowledged native reviews.
- Engram synchronization remains pending because the local provider was unavailable throughout the work.

## Next step

Commit this final evidence record. Delivery remains two stacked PR slices: TB-1 to `main`, then TB-2 to TB-1 and later retargeted to `main`. The informational silent-load-failure advisory remains separate follow-up scope.
