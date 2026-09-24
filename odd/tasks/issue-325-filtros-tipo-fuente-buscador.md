# Issue 325 — Filtros por tipo de fuente en el buscador semántico

## Objective

Implement source-kind scope filter pills (All, Telegram, Notes, Sessions) within the interactive semantic search bar of the review workbench (`AletheaWeb.TargetBehaviorLive.Review`), constraining retrieval queries to specific resource channels at the domain/retrieval layer, updating results immediately upon pill selection, and preserving filter state across keystrokes within the active search session.

## Parent and References

- Parent issue: #314 (`Spec: Semantic evidence discovery, E-O-R-C auto-drafting, and session audio transcriptions`)
- Blocked by: #322 (`Barra de búsqueda semántica interactiva en panel de evidencia` — closed)
- Followed by: #326 (`Cita directa desde resultados de búsqueda semántica`)

## Scope

- Domain seam (`Alethea.ClinicalRecord.Rag.Retrieval` & `Alethea.ClinicalRecord`):
  - Support `:source_kind` and `:source_types` options in `Retrieval.fetch_candidates/4` (consumed by `Retrieval.search/4`, `Retrieval.suggest/4`, and `ClinicalRecord.search_evidence_candidates/5`).
  - Map filter kinds to corresponding indexed resource types:
    - `"all"` / `:all` / `nil` -> unconstrained (no `WHERE` clause on `source_resource_type`).
    - `"telegram"` / `:telegram` -> `["patient_message", "message", "telegram"]`.
    - `"notes"` / `:notes` -> `["clinical_note", "note", "notes"]`.
    - `"sessions"` / `:sessions` -> `["session_transcript", "session_transcripts", "session", "clinical_session"]`.
  - Add unit tests verifying constrained candidate retrieval in `test/alethea/clinical_record/rag/retrieval_test.exs` and `test/alethea/clinical_record_test.exs`.
- Web seam (`AletheaWeb.TargetBehaviorLive.Review`):
  - Add filter pills container `#evidence-search-filters` positioned above the search input in `#evidence-search-bar`.
  - Render pills for "Todos" (`#evidence-search-filter-all`), "Telegram" (`#evidence-search-filter-telegram`), "Notas" (`#evidence-search-filter-notes`), and "Sesiones" (`#evidence-search-filter-sessions`).
  - Track active filter in `@search_source_filter` (default `"all"`).
  - Handle `filter_search_source` event on pill click:
    - Update `@search_source_filter`.
    - If `@search_query != ""`, immediately trigger retrieval search constrained to the selected source kind.
  - In `search_evidence` event, maintain the active `@search_source_filter` so filter state persists across typing/keystrokes.
  - Resetting or clearing search query via `#clear-evidence-search` restores the default suggested view, while preserving or resetting default filter as appropriate.
- Styling (`priv/static/assets/css/editorial.css`):
  - Add styles for `.evidence-search-filters` and `.evidence-search-filter-pill` with normal, hover, and active states adhering to design tokens.
- Test coverage (`test/alethea_web/live/target_behavior_live/review_test.exs`):
  - Verify 4 filter pills are rendered with "Todos" active by default.
  - Verify selecting a pill ("Telegram" / "Notas") immediately filters active search results to that source kind.
  - Verify typing new keystrokes preserves the active source filter.
  - Verify selecting "Todos" restores unconstrained results.
  - Full suite validation via `mix precommit`.

## Constraints and non-goals

- Direct 1-click citation from search results belongs to follow-up issue #326.
- Ingestion of real session audio recordings/transcripts is handled by separate transcript pipeline issues (#317/320).
- Do not modify untracked `package.json` or `package-lock.json`.

## Testing configuration

- TDD mode: strict.
- Focused context command: `mix test test/alethea/clinical_record_test.exs test/alethea/clinical_record/rag/retrieval_test.exs test/alethea_web/live/target_behavior_live/review_test.exs`.
- Full validation command: `mix precommit`.

## Tasks

- [x] **TASK-1 — Domain seam: source filtering in Retrieval and ClinicalRecord**
  - Support `:source_kind` and `:source_types` options in `Retrieval.fetch_candidates/4`.
  - Unit tests in `test/alethea/clinical_record/rag/retrieval_test.exs` and `test/alethea/clinical_record_test.exs`.

- [x] **TASK-2 — TDD RED: LiveView tests for source filter pills**
  - Add failing tests in `test/alethea_web/live/target_behavior_live/review_test.exs` covering pill rendering, immediate filtering on click, persistence across keystrokes, and default "Todos" state.

- [x] **TASK-3 — TDD GREEN: Review LiveView filter pills implementation**
  - Implement assigns, template pills, and `filter_search_source` event handler in `TargetBehaviorLive.Review`.
  - Ensure `search_evidence` preserves active filter across keystrokes.

- [x] **TASK-4 — Editorial styling for search filter pills**
  - Add `.evidence-search-filters` and `.evidence-search-filter-pill` rules in `editorial.css`.

- [x] **TASK-5 — Full validation and work-unit commit**
  - Run focused tests and full `mix precommit`.
  - Create work-unit commit following Conventional Commits.

## Acceptance criteria

- [x] Filter pills rendered above/beside search input: "Todos", "Telegram", "Notas", "Sesiones".
- [x] Selecting a pill immediately filters search results to matching `source_kind`.
- [x] State persists across keystrokes within the active search session.
- [x] Default state is "Todos" (unconstrained hybrid search).

## TDD and delivery evidence

- RED: Focused unit test initially failed in `retrieval_test.exs` and `clinical_record_test.exs` asserting candidate filtering by `source_kind`. Focused LiveView test in `review_test.exs` failed asserting presence of `#evidence-search-bar #evidence-search-filters`.
- GREEN: Implemented channel filtering in `Retrieval.fetch_candidates/4` and filter pills with `filter_search_source` event in `Review` LiveView. All focused tests passed (208 passed).
- VALIDATION: `mix precommit` passed: 1523 passed (6 doctests, 1517 tests), 5 skipped, 0 failures. `mix format --check-formatted` passed cleanly.
- COMMIT: `a828152` (`feat(clinical): filter semantic search by source type (#325)`).
- REVIEW: Native RDD compact review completed and acknowledged under lineage `review-917da96742b6ad84` (`approved`).


