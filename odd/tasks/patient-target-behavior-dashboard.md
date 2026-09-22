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

- Branch: `feature/292-target-behavior-dashboard`.
- Initial review boundary: `a512f9650d038fc8a69d284a0c8df104a7517059`.
- Delivery strategy: `ask-on-risk`.
- Forecast: 170–220 authored changed lines, excluding generated files.
- Expected delivery: one PR slice, two work-unit commits.
- Engram mirror: pending because the local Engram provider was unavailable during initialization.

## Tasks

- [ ] **TB-1 — Add the authorized target-behavior listing API**
  - Status: in progress.
  - Route: delegated writer; multi-file write trigger (`lib` plus context tests).
  - RED: prove patient scoping, decrypted descriptions, deterministic ordering, derived draft state, empty results, and unauthorized access.
  - GREEN: add the smallest `ClinicalRecord.list_target_behaviors/2` implementation.
  - REFACTOR: reuse existing authorization/decryption helpers and avoid leaking draft bodies.
  - Checks: focused clinical-record tests.
  - Commit evidence: pending.
  - Native review assessment/outcome: pending.

- [ ] **TB-2 — Render dashboard access and LiveView coverage**
  - Route: delegated writer; multi-file write trigger (LiveView, template, and tests).
  - RED: prove visible listing, exact stable review link, saved-state summary, patient isolation through the authorized data path, and explanatory empty state.
  - GREEN: stream the target behaviors and render the identified dashboard section.
  - REFACTOR: keep stable DOM IDs and reuse existing dashboard presentation patterns.
  - Checks: focused dashboard LiveView tests, then the combined feature command.
  - Runtime harness: authenticated `Phoenix.LiveViewTest.live/2` against encrypted SQL-sandbox records; no external service.
  - Commit evidence: pending.
  - Native review assessment/outcome: pending.

## Acceptance criteria

- [ ] A clinician can reach the functional-analysis workbench from the patient dashboard without using RAG.
- [ ] The list contains only target behaviors belonging to the authorized patient.
- [ ] Every behavior has a stable workbench link.
- [ ] The empty state explains how target behaviors are created or appear.
- [ ] LiveView tests cover listing, the correct link, and no behaviors.

## Progress and evidence

- Issue `#292` requirements inspected on 2026-09-16.
- Read-only repository mapping completed by `gentle-ai-explore`.
- No blocking product decision remains; draft state is derived from existing draft/tombstone data.

## Next step

TB-1 is in progress with a bounded writer using strict TDD.
