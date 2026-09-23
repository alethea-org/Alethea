# Issue 322 — Barra de búsqueda semántica interactiva en panel de evidencia

## Objective

Implement an interactive semantic search input with debouncing positioned in the left column (evidence panel) of the review workbench (`AletheaWeb.TargetBehaviorLive.Review`), allowing clinicians to query patient history in natural language, view matching result chunks with date, source kind, and excerpt, and restore the default top 5 suggested candidates view upon clearing the search.

## Parent and References

- Parent issue: #314 (`Spec: Semantic evidence discovery, E-O-R-C auto-drafting, and session audio transcriptions`)
- Blocked by: #318 (`Query RAG de sugerencias con scoring de afinidad y filtro de descartes` — closed)
- Prior art: #321 (`Visualización asíncrona de sugerencias Top 5 en el Workbench` — closed)

## Scope

- Domain seam (`Alethea.ClinicalRecord`):
  - Expose `search_evidence_candidates/5` accepting `(professional, patient_id, target_behavior_id, query, opts \\ [])`.
  - Delegate to `suggest_evidence_candidates/4` passing `query: query` so target behavior context and dismissed chunk exclusions are preserved.
- Web seam (`AletheaWeb.TargetBehaviorLive.Review`):
  - Add search bar `#evidence-search-bar` positioned above the evidence column/list in `#suggested-evidence-panel`.
  - Form `#evidence-search-form` with `phx-change="search_evidence"` and `phx-submit="search_evidence"`.
  - Text input `#evidence-search-input` with clean placeholder and `phx-debounce="400"`.
  - Clear button `#clear-evidence-search` with `phx-click="clear_evidence_search"`.
  - Debounced event handler querying semantic retrieval asynchronously via `assign_async(:search_results, ...)`.
  - Render matching chunks in `#evidence-search-results-list` (or `#evidence-search-empty` if no matches) displaying affinity badge, source kind badge, occurred date/time, and chunk excerpt.
  - Clearing the search immediately restores the default top 5 suggested candidates view (`@suggested_candidates`).
- Styling (`priv/static/assets/css/editorial.css`):
  - Styles for `#evidence-search-bar`, input wrapper, search icon, clear button, and empty states.
- Test coverage (`test/alethea_web/live/target_behavior_live/review_test.exs` and `test/alethea/clinical_record_test.exs`):
  - Verify search input positioning, placeholder, and debounce attribute.
  - Verify debounced search queries return matching chunks with dates, source kinds, and excerpts.
  - Verify empty state when query returns no matches.
  - Verify clearing search (via clear button or empty query) restores the default suggested candidates view.
  - Validation pass with `mix precommit`.

## Constraints and non-goals

- Interactive 1-click citation of suggested/search candidates belongs to follow-up issue #323.
- Interactive text trimming of candidate excerpts belongs to follow-up issue #324.
- Source filter chips (Telegram, Notes, Audio Sessions) belong to follow-up issue #326.
- Persistent dismissal of candidates belongs to follow-up issue #328.

## Testing configuration

- TDD mode: strict.
- Focused context command: `mix test test/alethea_web/live/target_behavior_live/review_test.exs`.
- Full validation command: `mix precommit`.

## Tasks

- [x] **TASK-1 — Domain seam: `ClinicalRecord.search_evidence_candidates/5`**
  - Add `search_evidence_candidates/5` to `Alethea.ClinicalRecord`.
  - Add unit test in `test/alethea/clinical_record_test.exs`.

- [x] **TASK-2 — TDD RED: Tests for interactive semantic search in `ReviewTest`**
  - Write test asserting presence of `#evidence-search-input` with placeholder and `phx-debounce`.
  - Write test asserting query execution and rendering matching chunks with date, source kind, and excerpt.
  - Write test asserting clean empty state when query has no matches.
  - Write test asserting clearing search restores the default suggested candidates.

- [x] **TASK-3 — TDD GREEN: Implementation in `TargetBehaviorLive.Review`**
  - Add search form and input in `#suggested-evidence-panel`.
  - Implement `handle_event("search_evidence", ...)` and `handle_event("clear_evidence_search", ...)`.
  - Render search results with loading, empty, and card list states.
  - Restore `@suggested_candidates` when search is cleared.

- [x] **TASK-4 — Styling in `editorial.css`**
  - Style `#evidence-search-bar`, input wrapper, search icon, clear button, and states.

- [x] **TASK-5 — Validation and Work-Unit Commit**
  - Focused validation passed: `mix test test/alethea/clinical_record_test.exs test/alethea_web/live/target_behavior_live/review_test.exs` (163 tests, 0 failures).
  - Precommit validation passed: `mix precommit` (1484 passed, 5 skipped, 0 failures).
  - Commit changes adhering to Conventional Commits.

## Acceptance criteria

- [x] Search input positioned above the evidence column with clean placeholder.
- [x] LiveView debounces input typing (300-500ms) before querying semantic retrieval (`phx-debounce="400"`).
- [x] Results stream/render matching chunks with date, source kind, and excerpt.
- [x] Clearing the search restores the default suggested candidates view.

## TDD and delivery evidence

- RED: Focused suite initially failed with 5 new LiveView tests in `test/alethea_web/live/target_behavior_live/review_test.exs` covering missing search bar, input attributes, debounced async query, loading state, results list, and reset behavior.
- GREEN: Focused suite `mix test test/alethea/clinical_record_test.exs test/alethea_web/live/target_behavior_live/review_test.exs` passed all 163 tests cleanly.
- TRIANGULATE / REFACTOR: Covered matching chunks with full provenance metadata (date, source kind badge, affinity badge, excerpt), clean empty state on no matches, restoring default suggestions upon clicking clear button, and restoring default suggestions upon submitting empty query.
- VALIDATION: `mix precommit` executed successfully with 1484 tests passed, 5 skipped, 0 failures.
- COMMIT: `edf9d31` (`feat(clinical): interactive semantic search in evidence panel (#322)`).
- PULL REQUEST: #335 (`feat(clinical): interactive semantic search in evidence panel (#322)`).



