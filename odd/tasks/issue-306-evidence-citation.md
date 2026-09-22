# Issue 306 — Evidence citation from target behavior workbench

## Objective

Let an authorized clinician select a patient-scoped clinical note or message, confirm an exact source-backed excerpt, and cite it from the target behavior workbench.

## Scope

- Add a domain interface that lists eligible evidence sources for an authorized patient and creates a citation from a trusted source selection.
- Prioritize inbound messages while preserving message direction and provenance.
- Validate source existence, patient ownership, authorization, and exact excerpt fidelity on the server.
- Reuse the existing encrypted immutable evidence, audit, and outbox transaction.
- Add a workbench selector and confirmation step with visible actions in the header and actionable empty state.
- Refresh the timeline and AI guard immediately after citation.
- Consolidate the evidence/proposal empty guidance without hiding the draft editor.
- Cover context and LiveView behavior, including cancellation and clinician/patient isolation.

## Constraints and non-goals

- The LiveView may submit only a source kind, source id, and excerpt candidate; the domain re-fetches and validates the source as authoritative.
- Do not treat free-text clinician observations or RAG results as cited evidence.
- Do not add schemas or migrations.
- Keep writes through `ClinicalRecord`; cross-context message reads remain isolated behind an explicit read-only adapter.
- Preserve the existing authenticated professional LiveView boundary and Spanish UI convention.
- Do not touch the pre-existing untracked `package.json` or `package-lock.json` files.

## Testing configuration

- TDD mode: strict.
- Focused context command: `mix test test/alethea/clinical_record_test.exs`.
- Focused LiveView command: `mix test test/alethea_web/live/target_behavior_live/review_test.exs`.
- Final command: `mix precommit`.

## Delivery and review

- Current branch: `feat/306-evidence-citation`.
- Delivery strategy: one feature PR closing approved issue #306.
- Review workload: approximately 1,147 changed lines across a cohesive domain + LiveView flow and its focused tests. The maintainer explicitly accepted `size:exception` on 2026-09-22 because a single PR preserves the end-to-end security boundary and both natural domain/UI slices remain above 400 lines when their tests stay with behavior.

## Tasks

- [x] **EVIDENCE-CITE-1 — Build the trusted source citation interface**
  - Status: completed; uncommitted pending explicit user authorization.
  - Route: delegated writer; multi-file write trigger.
  - RED: context tests for authorized source listing, inbound priority, source ownership, missing sources, exact excerpt fidelity, encryption, audit, and outbox.
  - GREEN: add a read-only source adapter and ClinicalRecord APIs that re-fetch and validate selected sources before persistence.
  - Allowed edit surfaces:
    - `lib/alethea/clinical_record.ex`
    - `lib/alethea/clinical_record/evidence_source.ex`
    - `test/alethea/clinical_record_test.exs`
  - TDD evidence: RED — 5 expected undefined-API failures; GREEN — 79 focused context tests passed after triangulating exact errors, zero-side-effect rejections, unauthorized access, and clinical-note citation.
  - Independent verification: no blocking defect; confirmed patient scoping, exact substring validation, source-derived timestamps, key selection, atomic encryption/audit/outbox persistence, and inbound-first provenance. Compatibility API is now deprecated.
  - Commit evidence: pending work-unit commit.

- [x] **EVIDENCE-CITE-2 — Add the workbench selector and confirmation flow**
  - Status: completed; uncommitted pending explicit user authorization.
  - Route: delegated writer; multi-file write trigger.
  - RED: LiveView tests for opening, source selection, exact excerpt entry, confirmation, cancellation, success, immediate timeline/AI guard updates, empty guidance, and isolation.
  - GREEN: implement the selector and confirmation state using stable DOM IDs and ClinicalRecord APIs only.
  - Allowed edit surfaces:
    - `lib/alethea_web/live/target_behavior_live/review.ex`
    - `test/alethea_web/live/target_behavior_live/review_test.exs`
    - `priv/static/assets/css/app.css`
  - TDD evidence: RED — 6 expected citation-flow failures; GREEN/refactor — 46 focused LiveView tests passed, including forged selection, mismatch, cancellation, and source removal before confirmation.
  - Commit evidence: pending work-unit commit.

- [x] **EVIDENCE-CITE-3 — Verify the complete issue behavior**
  - Status: completed.
  - Route: delegated verifier; verification trigger.
  - Checks: focused context suite — 79 passed; focused LiveView suite — 47 passed; `mix precommit` — 1412 passed, 5 skipped; `git diff --check` passed; changed-file LSP diagnostics reported no findings for 4 files and timed out for 1 file.
  - Independent verification: no high- or medium-severity findings. One low-severity intermediate guidance defect was fixed and covered by a new test.
  - Commit evidence: not applicable; no commit was authorized.

## Acceptance criteria

- [x] The workbench exposes `Citar evidencia` in the header and empty guidance.
- [x] Only authorized patient notes and messages are listed.
- [x] Messages show direction and prioritize inbound entries.
- [x] The clinician reviews the complete source and confirms an exact excerpt before persistence.
- [x] Invalid, foreign, unauthorized, or non-matching source selections are rejected server-side.
- [x] Evidence remains encrypted and immutable with existing audit/outbox behavior.
- [x] The new timeline item appears immediately and enables the AI guard when applicable.
- [x] Cancellation creates no evidence or outbox event.
- [x] Evidence/proposal empty guidance is consolidated and the draft editor remains visible.
- [x] Context and LiveView tests cover authorization and isolation.

## Progress and evidence

- Issue #306 requirements inspected from GitHub.
- Existing workbench, ClinicalRecord evidence transaction, source reference adapter, message schema, and focused test suites mapped.
- Read-only exploration delegation was attempted but timed out; the parent completed bounded symbol-level mapping.
- Engram mirror unavailable because the local Engram provider could not initialize; the repository task file remains authoritative for this session.
- Trusted source interface implemented and independently verified; 79 focused context tests pass.
- Workbench selector, exact-excerpt confirmation, cancellation, immediate timeline refresh, AI guard update, and consolidated guidance implemented; 47 focused LiveView tests pass.
- Final `mix precommit` passes with 1412 tests, 5 skipped; `git diff --check` passes.
- The maintainer authorized commit, push, PR creation, issue approval, and a single-PR `size:exception` delivery.
- Review workload warning accepted: the feature diff is approximately 1,147 changed lines plus two new files, exceeding the usual 400-line review budget; most growth is focused test coverage, and the security-sensitive domain/UI behavior is intentionally kept together for end-to-end review.
