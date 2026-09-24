# Issue 323 — One-click suggestion citation

## Objective

Let an authorized clinician cite an entire eligible evidence suggestion from the target behavior workbench with one click, persist it through the existing encrypted citation boundary, remove the suggestion immediately, and refresh the evidence timeline and counter reactively.

## Scope

- Add a primary `+ Citar todo` action to each citable suggestion card.
- Resolve the selected suggestion from server-held state rather than trusting client plaintext.
- Reuse `ClinicalRecord.cite_evidence_source/4` so source authorization, excerpt fidelity, patient-DEK encryption, audit, and outbox behavior remain authoritative.
- Remove a successfully cited suggestion from the current suggestion list.
- Reuse the existing timeline refresh path to update the timeline stream, evidence counter, and related evidence state.
- Add focused LiveView coverage for persistence, encrypted storage, suggestion removal, and reactive timeline updates.

## Constraints and non-goals

- Do not broaden `ConsultationEvidence.source_kind` or weaken source provenance rules.
- Do not persist client-supplied suggestion content.
- Do not add schemas or migrations.
- Do not modify the existing untracked `package.json` or `package-lock.json` files.
- If the #321 suggestion feed includes resource types unsupported by the citation boundary, stop and report the mismatch rather than silently broadening the domain model.

## Testing configuration

- TDD mode: strict, from `openspec/config.yaml` and repository convention.
- Focused runner: `mix test test/alethea_web/live/target_behavior_live/review_test.exs`.
- Final runner: `mix precommit`.

## Delivery and review

- Branch: `feat/323-one-click-suggestion-citation` from `origin/main` including #321.
- Delivery strategy: `ask-on-risk`; current authored change remains below the 400-line review threshold.
- Forecast: approximately 320 authored changed lines across the LiveView, its focused tests, and this task record.
- Native assessment: unavailable because the package-local Gentle AI binary is missing; the candidate was therefore treated as high risk and independently verified.

## Tasks

- [x] **CITE-SUGGESTION-1 — Add one-click citation behavior and focused tests**
  - Status: completed; commit authorized.
  - Route: delegated writer; preparation and multi-file write triggers.
  - RED: add LiveView tests for the card action, encrypted persistence, immediate card removal, timeline insertion, and counter increment.
  - GREEN: add the server-side event using the existing trusted citation and timeline refresh seams.
  - Allowed edit surfaces:
    - `lib/alethea_web/live/target_behavior_live/review.ex`
    - `test/alethea_web/live/target_behavior_live/review_test.exs`
  - TDD evidence: RED — focused suite reported 62/63 passing because the one-click action did not exist; GREEN — 64/64 passed; triangulation added patient-message provenance coverage and finished at 65/65 passing.
  - Verification: focused LiveView suite passed 65 tests; `git diff --check` passed.
  - Commit evidence: shared issue work-unit commit authorized; identity recorded after creation.

- [x] **CITE-SUGGESTION-2 — Verify the complete issue behavior**
  - Status: completed; shared work-unit commit authorized.
  - Route: delegated verifier according to native assessment.
  - Checks: `mix precommit` passed with 1,480 tests and 5 skipped; `git diff --check` passed; LSP diagnostics found no warnings or errors in either changed source file; independent verification found no remaining findings.
  - Commit evidence: shared issue work-unit commit authorized; identity recorded after creation.

## Acceptance criteria

- [x] Each eligible suggestion card has a primary `+ Citar todo` action.
- [x] Clicking the action persists a new `ConsultationEvidence` encrypted under the patient DEK through the existing domain seam.
- [x] The cited suggestion disappears immediately from the suggestion list.
- [x] The timeline updates immediately with the cited item and the evidence counter increments.

## Progress and evidence

- Issue #323 and blocker #321 inspected from GitHub.
- #321 is closed and present in `origin/main` at `fe3847d`; the feature branch starts from that commit.
- Existing exploration identified `ClinicalRecord.cite_evidence_source/4` and `load_timeline/1` as the trusted persistence and reactive refresh seams.
- The LiveView resolves candidates from server-held async state, maps `patient_message` to existing `message` provenance, and withholds the action from unsupported source kinds.
- Focused tests prove encrypted persistence, authoritative server plaintext despite forged client input, immediate card removal, timeline insertion, counter increment, and both supported provenance kinds.
- Independent verification initially found one low-severity patient-message coverage gap; the added regression test closed it without production changes.
- Final `mix precommit` passed with 1,480 tests and 5 skipped; `git diff --check` passed; changed-file LSP diagnostics were clean.
- Native risk assessment was unavailable because the package-local Gentle AI binary is missing, so the change followed the high-risk verification path.
- Engram mirror is unavailable because the local Engram provider reported an ownership mismatch; this repository task file is authoritative for the session.
