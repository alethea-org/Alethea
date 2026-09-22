# Target behavior workbench redesign and AI reliability

## Objective

Turn the target behavior review into a responsive two-column clinical workbench with a readable source feed and structured E-O-R-C drafting, while fixing the asynchronous AI failures discovered during real use.

## Confirmed product decisions

- Source selection uses a fixed-height internal scroll with all currently authorized sources; no server pagination.
- Source cards expose complete message/note content before selection, with message direction and provenance.
- Clinician observations remain distinct from cited evidence and do not satisfy the AI evidence guard.
- AI proposals enter a pending inbox; they are never auto-classified into E, O, R, or C.
- Existing free-text drafts remain intact as “Previous notes” and are not automatically classified.
- Structured E-O-R-C persists without a migration by using a canonical encrypted text representation and a safe legacy fallback.
- Delivery uses two independent PRs: reliability bugfix first, visual/structured workbench second.

## Constraints and non-goals

- Never send clinician observations, previous AI proposals, or tombstones to the pattern proposal chain as cited evidence.
- Keep exact citation validation, patient authorization, encryption, audit, outbox, and immutability unchanged.
- Do not add pagination or JavaScript for the source feed.
- Do not infer E-O-R-C fields from legacy text or accepted AI proposals.
- Do not add plaintext clinical data to logs, telemetry metadata, or Oban args.
- Preserve the pre-existing untracked `package.json` and `package-lock.json` files.

## Testing configuration

- TDD mode: strict.
- Bugfix focused commands:
  - `mix test test/alethea_jobs/ai_proposal_worker_test.exs`
  - `mix test test/alethea/oban_telemetry_test.exs`
- Workbench focused commands:
  - `mix test test/alethea/clinical_record_test.exs`
  - `mix test test/alethea_web/live/target_behavior_live/review_test.exs`
- Final command per PR: `mix precommit`.

## Delivery strategy

### PR 1 — AI proposal and telemetry reliability

- Branch: `fix/ai-proposal-timeline`.
- Boundary: worker evidence filtering, tombstone safety, Oban 2.22 stop metadata/duration compatibility, and focused regression tests.
- Independent rollback: revert worker/telemetry files and their focused tests.
- Runtime harness: focused worker and telemetry tests; full `mix precommit` before delivery.

### PR 2 — Two-column E-O-R-C workbench

- Planned branch: `feat/target-behavior-workbench-redesign`, based on updated `main` after PR 1.
- Boundary: responsive workbench shell, compact status strip, tabbed/card inputs, full-content source feed with internal scroll, centered evidence cards, collapsible observation entry, pending proposal inbox, canonical E-O-R-C serialization, and legacy previous-notes fallback.
- Independent rollback: revert workbench UI/CSS, draft serialization module/context integration, and focused tests.
- Runtime harness: focused context/LiveView tests plus browser-width visual verification if available.

## Tasks

- [x] **WORKBENCH-RELIABILITY-1 — Reproduce and fix AI proposal timeline handling**
  - Status: completed; pending work-unit commit.
  - Route: delegated writer; strict TDD.
  - RED: worker job with cited evidence, clinician observation, previous proposal, and tombstone proves only cited evidence reaches the chain and no missing-text crash occurs.
  - GREEN: filter timeline inputs by `:consultation_evidence` before extracting text.
  - Allowed edit surfaces:
    - `lib/alethea_jobs/ai_proposal_worker.ex`
    - `test/alethea_jobs/ai_proposal_worker_test.exs`
  - TDD evidence: RED reproduced `KeyError: key :text not found` on a target-scoped tombstone; GREEN focused suite passed 9 tests.
  - Independent verification: confirmed the chain receives only the cited excerpt while observations, prior proposals, and tombstones remain excluded; persistence, readiness broadcast, and authorization regressions pass.

- [x] **WORKBENCH-RELIABILITY-2 — Fix Oban stop telemetry compatibility**
  - Status: completed; pending work-unit commit.
  - Route: delegated writer; strict TDD.
  - RED: direct handler test with Oban 2.22 `state`/`result` metadata and duration measurement reproduces the `:success` KeyError and duration loss.
  - GREEN: derive success from stop state/result and duration from measurements without exposing job args.
  - Allowed edit surfaces:
    - `lib/alethea/oban_telemetry.ex`
    - `test/alethea/oban_telemetry_test.exs`
  - TDD evidence: RED reproduced two `KeyError: key :success not found` failures and then a metric double-conversion failure; GREEN focused suite passed 7 tests.
  - Independent verification: confirmed identity-millisecond metrics, exact PII-safe metadata, correct success mapping, consistent exception duration, and an attached handler that remains active for the real event fixture.

- [ ] **WORKBENCH-RELIABILITY-3 — Verify PR 1 candidate**
  - Status: pending.
  - Route: delegated verifier.
  - Checks: both focused suites, `mix precommit`, `git diff --check`, and changed-file diagnostics.

- [ ] **WORKBENCH-UI-1 — Define canonical E-O-R-C draft representation**
  - Status: pending until PR 1 completes.
  - Route: delegated writer; strict TDD.
  - Outcome: deterministic serialize/parse behavior for E, O, R, C plus previous notes, with safe legacy fallback and no migration.

- [ ] **WORKBENCH-UI-2 — Build responsive two-column workbench**
  - Status: pending.
  - Route: delegated writer; strict TDD.
  - Outcome: compact context/status header; left tabbed inputs and centered cards; right structured editor; responsive single-column fallback.

- [ ] **WORKBENCH-UI-3 — Replace source buttons with full-content feed cards**
  - Status: pending.
  - Route: delegated writer; strict TDD.
  - Outcome: all authorized sources are visible as complete-content cards in domain order within an internal scroll area; exact-excerpt confirmation remains intact.

- [ ] **WORKBENCH-UI-4 — Add pending AI proposal inbox and legacy notes surface**
  - Status: pending.
  - Route: delegated writer; strict TDD.
  - Outcome: accepted proposals require explicit human placement; legacy drafts remain visible without inferred classification.

- [ ] **WORKBENCH-UI-5 — Verify PR 2 candidate**
  - Status: pending.
  - Route: delegated verifier.
  - Checks: focused context/LiveView suites, responsive visual evidence when available, `mix precommit`, diff check, and diagnostics.

## Acceptance criteria

### Reliability

- [ ] Pattern generation does not crash when the timeline contains tombstones.
- [ ] Only cited consultation evidence is sent to the pattern proposal chain.
- [ ] Oban successful stop events do not detach the telemetry handler.
- [ ] Emitted job duration uses Oban measurements and success derives from supported metadata.
- [ ] Telemetry emits no clinical content or job args.

### Workbench UI

- [ ] Desktop layout presents inputs/evidence and the draft side by side.
- [ ] Narrow screens collapse to one usable column.
- [ ] Source selection shows full note/message content before selection in a fixed-height scrolling feed.
- [ ] Evidence, observations, and AI proposals are readable cards with distinct provenance.
- [ ] KPI tiles become a compact metadata/status strip.
- [ ] Observation entry is compact/collapsible and does not dominate the viewport.
- [ ] The right column provides explicit E, O, R, and C fields.
- [ ] Legacy free-text drafts remain available as previous notes without automatic classification.
- [ ] AI proposals remain in a pending inbox until manually classified.
- [ ] Existing authorization, citation, encryption, audit, outbox, and timeline behavior remains covered.

## Progress and evidence

- User screenshots and interaction feedback reviewed.
- Read-only mapping confirmed missing workbench/timeline CSS, metadata-only source buttons, eager source loading, and vertical layout.
- Confirmed Oban 2.22 telemetry incompatibility: stop metadata provides `state`/`result`, not `success`.
- Confirmed worker safety defect: heterogeneous timeline items are blindly mapped through `.text`; tombstones omit that key.
- Confirmed worker policy defect: observations and prior proposals currently enter the AI evidence payload.
- User selected fixed-height internal source scrolling, a pending AI proposal inbox, and structured E-O-R-C editing.
- Maintainer selected two independent PRs rather than a single size exception.
