# Issue 321 — Visualización asíncrona de sugerencias Top 5 en el Workbench

## Objective

Implement asynchronous background loading and visual presentation of the top 5 suggested evidence candidates in the target behavior review workbench (`AletheaWeb.TargetBehaviorLive.Review`), positioned in the left column above the cited evidence timeline without delaying initial page mount.

## Scope

- Asynchronous pipeline in `AletheaWeb.TargetBehaviorLive.Review`:
  - Execute background retrieval via `assign_async/3` in `mount/3` calling `ClinicalRecord.suggest_evidence_candidates/4` with `limit: 5`.
  - Non-blocking initial mount rendering immediate UI while retrieval runs in the background.
  - Safe error and empty-state handling.
- Visual presentation in `#workbench-inputs-panel` (left column above `#review-timeline`):
  - Async state handling: loading skeleton/spinner, failure message, empty state, and candidate card list.
  - Clean empty state (`#suggested-candidates-empty`) when no eligible candidates exist.
  - Candidate cards (`#suggested-candidate-<chunk_id>`):
    - Affinity tier badge with humanized label ("Alta afinidad", "Media afinidad", "Baja afinidad") and percentage.
    - Source kind badge with humanized label ("Nota clínica", "Mensaje del paciente", etc.).
    - Occurred date/time formatted (`dd/mm/yyyy hh:mm`).
    - Chunk text content.
- Styling in `priv/static/assets/css/editorial.css`:
  - Container and card styling honoring editorial design tokens.
  - Badges for affinity tiers (`badge--affinity-high`, `badge--affinity-medium`, `badge--affinity-low`).
  - Source kind badge and card responsiveness.
- Comprehensive test coverage in `test/alethea_web/live/target_behavior_live/review_test.exs`:
  - Instant mount verification without blocking on embedding calculation (loading state).
  - Background arrival and rendering of top 5 candidate cards via `render_async`.
  - Badges, date/time, and chunk text assertions.
  - Clean empty state verification when no eligible candidates are available.
  - Regression suite pass (`mix precommit`).

## Constraints and non-goals

- Interactive 1-click citation of suggested candidates belongs to follow-up issue #323.
- Interactive text trimming of suggested candidates belongs to follow-up issue #324.
- Persistent dismissal of suggested candidates belongs to follow-up issue #328.
- Natural-language search bar belongs to follow-up issue #322.

## Testing configuration

- TDD mode: strict.
- Focused context command: `mix test test/alethea_web/live/target_behavior_live/review_test.exs`.
- Final command: `mix precommit`.

## Tasks

- [x] **TASK-1 — Async suggestions pipeline in `TargetBehaviorLive.Review`**
  - Status: completed.
  - Added `assign_async(:suggested_candidates, ...)` in `mount/3` calling `ClinicalRecord.suggest_evidence_candidates/4` with `limit: 5`.
  - Guaranteed non-blocking initial mount with loading async state.

- [x] **TASK-2 — UI component for Top 5 suggested candidates and clean empty state**
  - Status: completed.
  - Positioned `#suggested-evidence-panel` in the left column above `#review-timeline`.
  - Rendered `<.async_result>` with `<:loading>`, `<:failed>`, empty state, and candidate cards.
  - Bound affinity badge, source kind badge, formatted date, and chunk content.

- [x] **TASK-3 — Comprehensive tests in `ReviewTest`**
  - Status: completed.
  - Tested immediate mount without waiting for embedding calculation.
  - Tested background retrieval and rendering of top 5 candidate cards upon arrival.
  - Tested affinity badge, source kind badge, occurred date/time, and content rendering.
  - Tested clean empty state when no candidates match or exist.

- [x] **TASK-4 — Styling in `editorial.css` and validation with `mix precommit`**
  - Status: completed.
  - Added CSS classes for suggestion cards, affinity badges, and loading/empty states in `priv/static/assets/css/editorial.css`.
  - Ran `mix precommit` (`compile --warnings-as-errors`, `format`, `test`).
  - Result: 1477 passed (6 doctests, 1471 tests), 5 skipped, 0 failures.

## Acceptance criteria

- [x] Target behavior review LiveView mounts immediately without waiting for embedding calculation.
- [x] LiveView executes background query via `assign_async` and renders top 5 candidate cards upon arrival.
- [x] Each card displays affinity badge (High, Medium, Low), source kind badge, occurred date/time, and chunk text.
- [x] Clean empty state displayed if no eligible candidates are available.

## TDD and delivery evidence

- RED: Focused test suite initially failed with 4 expected test failures in `test/alethea_web/live/target_behavior_live/review_test.exs` for missing suggested candidates panel, loading state, empty state, and candidate cards.
- GREEN: Focused suite `mix test test/alethea_web/live/target_behavior_live/review_test.exs` passed all 62 tests cleanly.
- TRIANGULATE: Verified instant mount, top 5 cutoff limit (6th excluded), card affinity badges, source kinds, occurred dates, chunk texts, clean empty state when no chunks exist, and clean empty state on blank descriptions.
- VALIDATION: `mix precommit` executed successfully with 1477 tests passed, 0 failures, 5 skipped.
