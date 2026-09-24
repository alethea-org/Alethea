# Issue 324 — Descarte interactivo de sugerencias de evidencia

## Objective

Provide a dismissal action on suggestion cards that permanently registers the chunk as dismissed for that target behavior, immediately removes the card from view, displays confirmation feedback, and prevents it from appearing on future page loads or reloads.

## Scope

- Add a `[Descartar ✕]` action to each suggestion card in `lib/alethea_web/live/target_behavior_live/review.ex`.
- Handle `dismiss_suggested_candidate` in `Review` LiveView:
  - Validate the chunk identifier against server-held `suggested_candidates`.
  - Persist the dismissal via `ClinicalRecord.dismiss_evidence_suggestion/4` with chunk identifier and resource type for audit fidelity.
  - Remove the dismissed card immediately from the UI state via `remove_suggested_candidate/2`.
  - Display confirmation feedback via info flash (`"Sugerencia descartada."`).
  - Render the empty state if all suggestions are removed/dismissed.
- Add button styling in `priv/static/assets/css/editorial.css` for `.suggested-candidate-card__actions`.
- Comprehensive LiveView tests in `test/alethea_web/live/target_behavior_live/review_test.exs`:
  - Presence of `[Descartar ✕]` button on every suggestion card (including non-citable items).
  - Dismissal execution persists to `dismissed_evidence_suggestions` and logs audit entry.
  - Immediate removal from the DOM and confirmation flash.
  - Clean empty state transition when the last suggestion is dismissed.
  - Verification that reloading the page excludes the dismissed chunk from future suggestions.
  - Safe error handling for untrusted/unmatched chunk IDs.

## Constraints and non-goals

- Outbox jobs or RAG re-indexing are not needed for dismissals.
- Text trimming belongs to follow-up issue #325.
- Do not modify untracked `package.json` or `package-lock.json`.
- Server-side state must remain authoritative; client cannot forge arbitrary chunk dismissals.

## Testing configuration

- TDD mode: strict.
- Focused context command: `mix test test/alethea_web/live/target_behavior_live/review_test.exs`.
- Final validation: `mix precommit`.

## Tasks

- [x] **DISMISS-UI-1 — TDD RED: Failing tests for dismissal action and persistence**
  - Status: completed.
  - Added LiveView tests asserting on button presence, dismissal persistence, reactive card removal, flash feedback, and reload exclusion.
  - Verified tests failed prior to implementation.

- [x] **DISMISS-UI-2 — TDD GREEN: LiveView event and persistence integration**
  - Status: completed.
  - Added `[Descartar ✕]` button to template on every suggestion card.
  - Implemented `handle_event("dismiss_suggested_candidate", ...)` in `AletheaWeb.TargetBehaviorLive.Review`.
  - Integrated with `ClinicalRecord.dismiss_evidence_suggestion/4` with chunk ID and resource type.
  - Added visual feedback flash (`"Sugerencia descartada."`) and reactive candidate removal via `remove_suggested_candidate/2`.

- [x] **DISMISS-UI-3 — Editorial styling for suggestion card actions**
  - Status: completed.
  - Styled `.suggested-candidate-card__actions` in `priv/static/assets/css/editorial.css`.

- [x] **DISMISS-UI-4 — Triangulation and edge case tests**
  - Status: completed.
  - Tested dismissal on non-citable suggestions.
  - Tested transition to empty state when all candidates dismissed.
  - Tested untrusted/forged chunk IDs fail gracefully without altering state.
  - Verified reload exclusion across multiple chunks.

- [x] **DISMISS-UI-5 — Full validation and precommit**
  - Status: completed.
  - `mix precommit` passed with 1497 tests (6 doctests, 1491 tests), 5 skipped, 0 failures.
  - `git diff --check` clean.
  - LSP diagnostics clean on changed files.

## Acceptance criteria

- [x] Each suggestion card features a `[Descartar ✕]` action.
- [x] Clicking dismiss records the dismissal in the database and removes the card from the UI.
- [x] Reloading the page or revisiting the target behavior does not display the dismissed chunk again.
- [x] Confirmation flash or subtle visual feedback confirms dismissal.

## TDD and delivery evidence

- RED: Focused suite initially failed because `#dismiss-suggested-candidate-<id>` was missing from the rendered LiveView view.
- GREEN: After implementing the event handler and template button, the initial suite passed.
- TRIANGULATE: Added coverage for non-citable suggestions, untrusted/forged chunk IDs, reload exclusion, and empty state transition.
- VALIDATION: `mix precommit` passed: 1497 tests (6 doctests, 1491 tests), 5 skipped, 0 failures.
