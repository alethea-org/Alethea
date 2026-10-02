# Issue #367 — Preview an AI revision in the existing E-O-R-C editor

## Objective and constraints
Allow a clinician to generate a complete editable revision proposal for a target behavior's E-O-R-C functional analysis based on the current active working draft and all currently authorized, cited, sanitized evidence, explicitly identifying which citations are new since the last registered version.
Show the proposal directly in the existing eleven E-O-R-C fields with a compact pending-proposal banner, without mutating the persisted working draft.
Pause autosave while proposed text is shown/edited.
Provide explicit Apply (persists proposal into working draft) and Discard (restores original working draft and save status).
Ensure pending generation or preview never overwrites intervening clinician edits.
Invalidate the proposal on stale or legally deleted citations.
Preserve all clinical-safety guarantees: local model only, zero diagnosis/prescription, no plaintext leaks, no unreviewed AI text entering the clinical record.

## Setup and strategy
- Branch: `feat/367-ai-revision-preview` from `main` (which contains #362 autosave, #363 versions, #364 browse, #365 continue, and #366 baseline + markers).
- TDD: ON, observe RED before GREEN on each task.
- Test runner: `MIX_TEST_PARTITION=_367_preview mix test <path>` on isolated database `alethea_test_367_preview`.
- Seams:
  1. `lib/alethea/ai/chains/functional_analysis_draft_chain.ex` + test.
  2. `lib/alethea_web/live/target_behavior_live/review.ex` + test.
  3. `priv/static/assets/css/editorial.css`.

## Tasks
- [x] **T1 — AI revision prompt & chain support for draft + new citations.** Extended `FunctionalAnalysisDraftChain` to accept `working_draft` and differentiate new citations (`new_evidence`) since latest registered version, maintaining backward compatibility for `%{sanitized_evidence: texts}`. Added unit tests for prompt building, safety rules, and schema parsing (28 tests, 0 failures).
- [x] **T2 — Pending proposal preview state & banner in Workbench.** In `Review` LiveView, call chain with current working draft and annotated citations. On response, enter `ai_proposal_pending` preview mode showing proposed text in the eleven fields with a compact `#ai-proposal-banner` having Apply and Discard buttons. Proposed text is not persisted upon arrival.
- [x] **T3 — Autosave suspension and Apply / Discard actions.** While in proposal preview, clinician edits do not trigger autosave. Discard restores the exact active working draft and prior draft status without saving. Apply validates citations, sets the proposal as the working draft, and triggers persistence.
- [x] **T4 — Intervening clinician edits, stale citation invalidation & error resilience.** In-flight clinician edits are not overwritten by incoming proposals. Stale or legally deleted citations invalidate the proposal. Generation errors leave the working draft and unsaved text untouched. Version registration is blocked while proposal is pending.
- [x] **T5 — Full verification and precommit gate.** Run all domain, chain, and Workbench LiveView tests, followed by `MIX_TEST_PARTITION=_367_preview mix precommit`. Verified: 6 doctests, 1775 tests, 0 failures, 5 skipped.

## Verification Evidence
- `FunctionalAnalysisDraftChainTest`: 28 tests, 0 failures.
- `TargetBehaviorLive.ReviewTest`: 145 tests, 0 failures.
- Full `mix precommit`: 6 doctests, 1775 tests, 0 failures, 5 skipped; compilation with `--warnings-as-errors` clean; format clean.
