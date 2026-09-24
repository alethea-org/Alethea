# Issue 327 — Recorte y selección de texto exacto de sugerencias

## Objective

Allow clinicians to open an inline trimming editor on any citable suggestion card, select or edit an exact excerpt subset from the suggested chunk text, and confirm citation directly into `ConsultationEvidence` encrypted under the patient DEK, or cancel without side effects.

## Scope

- Add a secondary `[Recortar]` button to each citable suggestion card.
- Track inline trimming state per suggestion card (`trimming_candidate_id`, `trim_form`, `trim_error`).
- Pre-populate the inline excerpt editor with the suggested chunk content.
- Validate the trimmed excerpt (non-empty and exact match against the candidate/source text) on submission.
- Cite the trimmed excerpt using `ClinicalRecord.cite_evidence_source/4`.
- Remove the cited suggestion, refresh the timeline and evidence counter reactively.
- Support cancellation returning the card to its standard view without side effects.
- Add focused LiveView tests for opening trimming mode, editing/submitting trimmed excerpts, encrypted storage, and cancellation.

## Constraints and non-goals

- Do not alter `ConsultationEvidence` schemas or migrations.
- Do not bypass `ClinicalRecord.cite_evidence_source/4` source authorization or exact excerpt validation.
- Do not modify untracked `package.json` or `package-lock.json`.

## Testing configuration

- TDD mode: strict.
- Focused runner: `mix test test/alethea_web/live/target_behavior_live/review_test.exs`.
- Final runner: `mix precommit`.

## Delivery and review

- Branch: `feat/327-trim-suggestion-excerpt` from `origin/main`.
- Conventional Commits format.

## Tasks

- [x] **TRIM-SUGGESTION-1 — RED: Write focused tests for inline trimming and citation**
  - Status: completed.
  - Route: delegated writer.
  - Allowed edit surfaces:
    - `test/alethea_web/live/target_behavior_live/review_test.exs`
  - TDD evidence: RED — focused suite reported 84/90 passing with 6 expected failures due to missing `[Recortar]` and inline editor.
- [x] **TRIM-SUGGESTION-2 — GREEN: Implement inline trimming UI and citation events**
  - Status: completed.
  - Route: delegated writer.
  - Allowed edit surfaces:
    - `lib/alethea_web/live/target_behavior_live/review.ex`
    - `priv/static/assets/css/editorial.css`
  - TDD evidence: GREEN — focused suite reported 93/93 passing, including triangulation tests for patient message provenance, candidate dismissal during trim, and switching between trimming cards.
- [x] **TRIM-SUGGESTION-3 — Verify and run precommit**
  - Status: completed.
  - Checks: `mix precommit` passed with 1,573 tests passed (0 failures, 5 skipped); `git diff --check` clean.

## Acceptance criteria

- [x] Each suggestion card features a secondary `[Recortar]` action.
- [x] Clicking it opens an inline excerpt editor populated with the chunk text.
- [x] Clinician can highlight/trim the exact subset of words to cite.
- [x] Confirming the trimmed excerpt creates a `ConsultationEvidence` with the selected excerpt only.
- [x] Canceling returns to the standard suggestion card view without side effects.
