# Issue 326 — Cita directa desde resultados de búsqueda semántica

## Objective

Allow clinicians to cite any eligible search result directly from the semantic search panel of the review workbench (`AletheaWeb.TargetBehaviorLive.Review`), creating an official encrypted `ConsultationEvidence` row with exact source reference, streaming it immediately into the behavior timeline and updating the evidence counter, while displaying clear visual confirmation of being cited on the search result card.

## Parent and References

- Parent issue: #314 (`Spec: Semantic evidence discovery, E-O-R-C auto-drafting, and session audio transcriptions`)
- Blocked by: #322 (`Barra de búsqueda semántica interactiva en panel de evidencia` — closed)
- Related: #323 (`One-click suggestion citation` — closed), #325 (`Filtros por tipo de fuente en el buscador semántico` — closed)

## Scope

- Web seam (`AletheaWeb.TargetBehaviorLive.Review`):
  - In `mount/3`, initialize `@cited_chunk_ids` with `MapSet.new()`.
  - In search results template (`#evidence-search-results-list`):
    - Add `.suggested-candidate-card__actions` to each search result card `#evidence-search-result-#{result.chunk_id}`.
    - Render `+ Citar` button (`#cite-search-result-#{result.chunk_id}`) when `citable_candidate?(result)` and `result.chunk_id not in @cited_chunk_ids`.
    - When `result.chunk_id in @cited_chunk_ids`:
      - Add `.suggested-candidate-card--cited` class to the card.
      - Display visual confirmation badge `#cited-confirmation-#{result.chunk_id}` ("✓ Citado") in the card actions.
  - Implement `cite_search_result` event handler:
    - Resolve the candidate strictly from server-held `@search_results` via `find_citable_candidate/2`.
    - Reject non-citable or forged client requests.
    - Call `ClinicalRecord.cite_evidence_source/4` with authoritative server content and provenance.
    - On success:
      - Add `chunk_id` to `@cited_chunk_ids`.
      - Remove candidate from `@suggested_candidates` if present.
      - Reload timeline via `load_timeline/1` to stream the new evidence into the timeline and increment the counter.
      - Put flash message "Evidencia citada correctamente.".
  - Also ensure `cite_suggested_candidate` records `chunk_id` in `@cited_chunk_ids` for cross-panel consistency.
- Editorial styling (`priv/static/assets/css/editorial.css`):
  - Add `.badge--cited` styling (green border, soft green background, text color).
  - Add `.suggested-candidate-card--cited` styling.
- Test coverage (`test/alethea_web/live/target_behavior_live/review_test.exs`):
  - Verify `+ Citar` action displays on search result items.
  - Verify clicking `+ Citar` persists `ConsultationEvidence` encrypted under patient DEK with exact source reference.
  - Verify timeline streams the new evidence and increments counter.
  - Verify search result card displays visual confirmation (`.suggested-candidate-card--cited`, `#cited-confirmation-#{chunk.id}`) and replaces the button.
  - Verify forged client plaintext is ignored.
  - Verify patient message provenance handling.
  - Full suite validation via `mix precommit`.

## Constraints and non-goals

- Do not broaden `ConsultationEvidence.source_kind` or weaken source provenance rules.
- Do not trust client-supplied plaintext or source identifiers.
- Do not add schemas or migrations.
- Do not modify untracked `package.json` or `package-lock.json`.

## Testing configuration

- TDD mode: strict.
- Focused context command: `mix test test/alethea_web/live/target_behavior_live/review_test.exs`.
- Full validation command: `mix precommit`.

## Tasks

- [x] **TASK-1 — TDD RED: LiveView tests for direct citation from search results**
  - Add tests in `test/alethea_web/live/target_behavior_live/review_test.exs` covering `[+ Citar]` action presence, encrypted persistence, timeline stream and counter update, and visual confirmation of cited card.

- [x] **TASK-2 — TDD GREEN: Review LiveView direct search citation implementation**
  - Implement assigns, event handlers, and template elements in `TargetBehaviorLive.Review`.

- [x] **TASK-3 — Styling: Editorial CSS for cited search cards and badges**
  - Add `.badge--cited` and `.suggested-candidate-card--cited` rules in `priv/static/assets/css/editorial.css`.

- [x] **TASK-4 — Full validation and work-unit commit**
  - Run focused suite and `mix precommit`.
  - Create work-unit commit following Conventional Commits (`7f84554`).

## Acceptance criteria

- [x] Each item in the semantic search results displays a `[+ Citar]` action.
- [x] Clicking the action creates a `ConsultationEvidence` row with exact source reference.
- [x] The cited evidence immediately streams into the behavior timeline.
- [x] The search result card displays visual confirmation of being cited.

## TDD and delivery evidence

- RED: Focused tests in `test/alethea_web/live/target_behavior_live/review_test.exs` failed as expected (82 excluded, 5 failing) due to missing `+ Citar` action, missing `cite_search_result` event, and missing visual confirmation.
- GREEN: Implemented `@cited_chunk_ids` set in `mount/3`, `cite_search_result` event handler in `TargetBehaviorLive.Review`, server-side candidate resolution with `find_citable_candidate/2`, encrypted persistence with `ClinicalRecord.cite_evidence_source/4`, reactive timeline reload via `load_timeline/1`, and conditional card classes and badges (`.badge--cited`, `#cited-confirmation-#{result.chunk_id}` with "✓ Citado"). All 83 review tests passed.
- STYLING: Added `.badge--cited`, `.suggested-candidate-card--cited`, and `.evidence-search-result__cited-confirmation` in `priv/static/assets/css/editorial.css`.
- VALIDATION: `mix precommit` passed cleanly with 1,563 passed (6 doctests, 1557 tests), 5 skipped, 0 failures. `mix format --check-formatted` passed with no diff.
- REVIEW: Native RDD compact review completed and acknowledged under lineage `review-474957456d437b7d` (`approved`).
- COMMIT: `7f84554` (`feat(clinical): cite evidence directly from semantic search results (#326)`).
- PULL REQUEST: #347 (`feat(clinical): cite evidence directly from semantic search results (#326)`).
