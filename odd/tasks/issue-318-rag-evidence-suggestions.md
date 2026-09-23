# Issue 318 — Query RAG de sugerencias con scoring de afinidad y filtro de descartes

## Objective

Build a read-side semantic retrieval function that takes a target behavior's description, retrieves matching patient chunks via hybrid vector/lexical search, filters out previously dismissed chunks for that behavior at the SQL level, and computes normalized affinity score tiers (High, Medium, Low) and badges for UI display.

## Scope

- Core RAG retrieval extensions in `Alethea.ClinicalRecord.Rag.Retrieval`:
  - `normalize_match_percentage/1` converting raw dense/lexical merged score to `0..100` percentage.
  - `affinity_tier/1` classifying percentage into `:high` (>75%), `:medium` (50..75%), or `:low` (<50%).
  - `affinity_label/1` returning Spanish label ("Alta afinidad", "Media afinidad", "Baja afinidad").
  - `affinity_badge/1` returning badge map `%{tier: tier, label: label, percentage: pct}`.
  - Candidate scoring enrichment including `match_percentage`, `affinity_tier`, and `affinity_badge`.
  - `suggest/4` entry point with default limit of 5 and blank query handling.
  - SQL-level exclusion in `fetch_candidates/4` of dismissed chunks and resources for `target_behavior_id` or explicit `exclude_chunk_ids` / `exclude_resource_ids`, strictly BEFORE `order_by` and `LIMIT`.
  - Strict preservation of patient-scoped security boundary (WHERE `patient_id == ^patient_id` and decryption strictly after SQL LIMIT).
- Domain facade in `Alethea.ClinicalRecord`:
  - `suggest_evidence_candidates/4` accepting `(professional, patient_id, target_behavior_id, opts \\ [])`.
  - Authorization through `with_target_behavior/4` ensuring treating professional and patient ownership.
  - Automatic extraction and decryption of `target_behavior.description` (or override via `opts[:query]` / `opts[:description]`).
  - Graceful handling of empty or whitespace-only target behavior descriptions (`{:ok, []}`).
  - Returns `{:ok, [candidate]}` with full scoring and badges ready for asynchronous workbench consumption.
- Comprehensive test coverage:
  - Unit tests for lexical/dense score normalization and affinity tiers.
  - Integration tests for SQL-level dismissal filtering (by chunk_id and resource_id).
  - Integration tests for candidate window cutoff and decrypt-after-limit security boundary.
  - Integration tests for cross-patient isolation.
  - Domain tests in `ClinicalRecordTest` covering authorization, auditing, and end-to-end suggestions.

## Constraints and non-goals

- Outbox jobs, chunk embedding re-indexing, or background workers are not modified (existing indexer and workers remain authoritative).
- LiveView integration belongs to follow-up issue #321.
- Interactive search bar belongs to follow-up issue #322.

## Testing configuration

- TDD mode: strict.
- Focused context command: `mix test test/alethea/clinical_record/rag/retrieval_test.exs test/alethea/clinical_record_test.exs`.
- Final command: `mix precommit`.

## Tasks

- [x] **TASK-1 — Normalized scoring and affinity tier badges in `Rag.Retrieval`**
  - Status: completed.
  - Implemented `normalize_match_percentage/1`, `affinity_tier/1`, `affinity_label/1`, and `affinity_badge/1`.
  - Updated `score_candidate/5` to include `match_percentage`, `affinity_tier`, and `affinity_badge`.
  - Unit tests covering normalization, tier thresholds (>75, 50..75, <50), and badges.

- [x] **TASK-2 — SQL-level exclusion of dismissed suggestions and `suggest/4` in `Rag.Retrieval`**
  - Status: completed.
  - Extended candidate fetching to exclude dismissed chunks and resources at SQL query level using subqueries on `dismissed_evidence_suggestions` or explicit `exclude_chunk_ids` / `exclude_resource_ids`.
  - Ensured exclusion happens before `order_by` and `LIMIT :candidate_limit`.
  - Implemented `suggest/4` with default `limit: 5` and blank query handling.
  - Tests covering dismissal exclusion, empty query, candidate window cutoff, and cross-patient isolation.

- [x] **TASK-3 — Domain facade `suggest_evidence_candidates/4` in `Alethea.ClinicalRecord`**
  - Status: completed.
  - Implemented `ClinicalRecord.suggest_evidence_candidates/4` with `with_target_behavior/4` authz.
  - Decrypted target behavior description and passed to `Retrieval.suggest/4` with `target_behavior_id`.
  - Handled missing/blank description gracefully (`{:ok, []}`).
  - Integration tests in `ClinicalRecordTest` covering happy path, dismissed chunk exclusion, unauthorized access, and cross-patient denial.

- [x] **TASK-4 — Full validation and precommit**
  - Status: completed.
  - Executed `mix precommit` (`compile --warnings-as-errors`, `deps.unlock --unused`, `format`, `test`).
  - Result: 1473 passed (6 doctests, 1467 tests), 5 skipped, 0 failures.

## Acceptance criteria

- [x] Query accepts target behavior description and patient credentials.
- [x] Excludes chunk IDs listed in dismissed suggestions for that target behavior.
- [x] Returns top candidate chunks with normalized match percentages and affinity tier badges.
- [x] Scoped strictly to patient ID after SQL limit to preserve security and memory boundaries.

## TDD and delivery evidence

- RED: Focused test suite initially reported 17 expected failures for missing functions in `Retrieval` and `ClinicalRecord`.
- GREEN: Focused suite `mix test test/alethea/clinical_record/rag/retrieval_test.exs test/alethea/clinical_record_test.exs` passed all 126 tests cleanly.
- TRIANGULATE: Covered chunk/resource dismissals, explicit exclusions, candidate-window filtering, decrypt-after-limit, blank queries, authorization, and cross-patient isolation.
