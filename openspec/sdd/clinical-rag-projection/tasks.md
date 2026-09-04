# Tasks: Clinical RAG Projection (GitHub #196)

## Review Workload Forecast

| Field | Value |
|-------|-------|
| Estimated changed lines | ~1510 (sum of groups below) |
| 400-line budget risk | High |
| Chained PRs recommended | Yes |
| Suggested split | 5 work units (WU1–WU5), see below |
| Delivery strategy | single-pr (cached) |
| Chain strategy | pending — recommend stacked-to-main |

Decision needed before apply: Yes
Chained PRs recommended: Yes
Chain strategy: pending
400-line budget risk: High

**Conflict**: cached delivery_strategy is `single-pr`, which requires an explicit `size:exception` before apply. The estimate below is ~3.8x the 400-line budget and does not fit even after a 2-way split (each half still exceeds 400). This is a real conflict, not a soft warning — the orchestrator must get an explicit user decision (accept `size:exception` for a ~1510-line single PR, or override the cached strategy to `stacked-to-main`/`feature-branch-chain` across 5 PRs) before `sdd-apply` starts any work.

### Estimated lines per group

| Group | Files | Est. lines |
|---|---|---|
| Fake embeddings fix | `ai/embeddings/fake.ex` + test | 60 |
| Migration | new migration + comment annotation on old one | 70 |
| Chunk schema | `rag/chunk.ex` + test | 140 |
| Indexer | `rag/indexer.ex` (eligibility/chunk/embed/replace) + unit+DB+integration tests | 420 |
| Worker rework | `clinical_record_outbox_worker.ex` + **rewritten** test file | 190 |
| Retrieval | `rag/retrieval.ex` + tests (isolation, ranking, freshness, authz) | 280 |
| Rebuild + LiveView | `mix alethea.rag.reindex.ex`, `patient_live/clinical_search.ex`, router, tests | 350 |
| Docs | operator guide note | 10 |
| **Total** | | **~1510** |

### Suggested Work Units

Confirming and refining the design's PR1(ingest)/PR2(retrieval) split: neither half fits under 400 lines alone (ingest ≈880, retrieval+view ≈630), so 5 work units are proposed instead. **The Fake-embeddings fix belongs in WU1** — the indexer's unit/DB/integration tests (WU2) inject `Embeddings.Fake` and cannot pass against the current 1-dim all-zero stub (`vector(1024)` insert fails; cosine `<=>` on a zero vector is NaN).

| Unit | Goal | Likely PR | Focused test command | Runtime harness | Rollback boundary |
|------|------|-----------|----------------------|-----------------|-------------------|
| 1 | Fake fix + migration + `Chunk` schema (foundation, inert — no caller yet) | PR 1 | `mix test test/alethea/ai/embeddings/fake_test.exs test/alethea/clinical_record/rag/chunk_test.exs` | `mix ecto.migrate` against dev DB, verify table/index exist | `mix ecto.rollback` drops table; extension stays inert; Fake revert is a single-file diff |
| 2 | `Indexer` (eligibility, chunking, embed, replace_chunks) — unit-tested, not yet wired to worker | PR 2 | `mix test test/alethea/clinical_record/rag/indexer_test.exs` | N/A — dead code path until WU3 wires the worker; no live scenario to run | Delete `rag/indexer.ex` + its test; no other module references it yet |
| 3 | Worker rework (dispatch to Indexer, `max_attempts` 1→5) + **rewritten** worker test | PR 3 | `mix test test/alethea_jobs/clinical_record_outbox_worker_test.exs` | Trigger a real `ClinicalNote` create in dev, inspect Oban dashboard job outcome | Revert worker to prior no-op `perform/1`; queued jobs drain harmlessly (documented current behavior) |
| 4 | `Retrieval.search/4` (dense ANN + lexical rescore + freshness + authz) | PR 4 | `mix test test/alethea/clinical_record/rag/retrieval_test.exs` | IEx: `Retrieval.search(professional, patient_id, "query")` against seeded chunks | Delete `rag/retrieval.ex` + test; nothing else calls it yet |
| 5 | Rebuild Mix task + `PatientLive.ClinicalSearch` + router + operator-guide note | PR 5 | `mix test test/alethea_web/live/patient_live/clinical_search_test.exs` | `mix alethea.rag.reindex --patient-id <uuid> --confirm` in dev; open `/patients/:id/clinical-search` | Remove route + LiveView file + Mix task; no other surface depends on them |

## Phase 0: Prerequisite — Fix Fake Embeddings ✅ (WU1, apply batch 1)

- [x] 0.1 [RED] `test/alethea/ai/embeddings/fake_test.exs`: assert `embed/2` returns deterministic non-zero 1024-dim vectors per input, `dimensions/0 == 1024`
- [x] 0.2 [GREEN] `lib/alethea/ai/embeddings/fake.ex`: derive vectors from input hash, non-zero, 1024-dim, deterministic

## Phase 1: Migration ✅ (WU1, apply batch 1)

- [x] 1.1 `priv/repo/migrations/20260904000131_create_clinical_record_rag_chunks.exs`: `CREATE EXTENSION IF NOT EXISTS vector` (no-op down); create `clinical_record_rag_chunks` per design field list; `unique_index([:source_resource_type, :source_resource_id, :chunk_index])`; `index([:patient_id])`; HNSW `USING hnsw (embedding vector_cosine_ops)`
- [x] 1.2 Annotate stale `vector(384)` comment in `20260526141108_add_sessions_and_embeddings.exs` (D7 correction, comment-only, no executed column)
- [x] 1.3 `mix ecto.migrate` attempted; migration is transactionally safe (confirmed clean rollback state via `mix ecto.migrations`) — **BLOCKED**: local/CI Postgres lacks the `vector` extension binary (pre-existing, project-documented gap, see README "Estado del RAG y grafo"; no MSVC toolchain available in this environment to build pgvector from source). Not a code defect — see apply-progress risk note.

## Phase 2: Chunk Schema ✅ (WU1, apply batch 1)

- [x] 2.1 [RED] `test/alethea/clinical_record/rag/chunk_test.exs`: changeset validations (16/17 passing); unique_constraint violation on `(source_resource_type, source_resource_id, chunk_index)` — **1 test BLOCKED** (same pgvector/table-does-not-exist gap as 1.3, not a code defect)
- [x] 2.2 [GREEN] `lib/alethea/clinical_record/rag/chunk.ex`: schema mirroring `ConsultationEvidence` (PatientVault-encrypted content, virtual redacted field, `embedding: Pgvector.Ecto.Vector`, `@derive {Inspect, except: [:content]}`, unique_constraint)

## Phase 3: Indexer

- [ ] 3.1 [RED] `eligibility/1` tests — one case per spec table row (6 index/ignore events + unknown catch-all → `{:unknown, event}`, no crash)
- [ ] 3.2 [GREEN] `eligibility/1` implementation with tombstone-seam catch-all
- [ ] 3.3 [RED] `chunk/1` tests — short event → single chunk (`chunk_index: 0`, `full_event: true`); long event (>500 tokens) → sub-split on paragraph/sentence boundary with ~15% overlap
- [ ] 3.4 [GREEN] `chunk/1` implementation (word-count heuristic, `~r/\n{2,}/` paragraphs, `~r/(?<=[.!?…])\s+/u` sentences, greedy pack + overlap)
- [ ] 3.5 [RED] embed-dimension-mismatch test (Mox-injected `Embeddings` mock) → `{:cancel, {:embedding_dimension_mismatch, got, expected}}`
- [ ] 3.6 [GREEN] batch `AI.embeddings().embed/2` call + mismatch guard
- [ ] 3.7 [RED] `replace_chunks/2` DB tests: idempotent retry converges to one chunk set; concurrent double-run hits unique index → `{:error, _}`
- [ ] 3.8 [GREEN] `replace_chunks/2`: one `Repo.transaction` (delete-by-resource then `insert_all`)
- [ ] 3.9 [RED] integration test: `index_event/1` end-to-end per eligible event type → retrievable chunk (Ecto sandbox + Oban `testing: :manual`)
- [ ] 3.10 [GREEN] wire `index_event/1` composing 3.2/3.4/3.6/3.8

## Phase 4: Worker Rework

- [ ] 4.1 [RED] **REWRITE** `test/alethea_jobs/clinical_record_outbox_worker_test.exs` (do not extend — it locks 3 contracts this change breaks): `max_attempts == 5`; `perform/1` dispatches to `Indexer`; malformed args → `{:cancel, _}` (not `FunctionClauseError`); transient failure → `{:error, _}`; ignore/unknown → `:ok`
- [ ] 4.2 [GREEN] `lib/alethea_jobs/clinical_record_outbox_worker.ex`: `max_attempts` 1→5, `perform/1` clauses + classification per design

## Phase 5: Retrieval

- [ ] 5.1 [RED] unit tests: lexical normalization (NFD, accent-fold, Spanish stopwords), `score = 0.7*(1-dense) + 0.3*lexical` merge
- [ ] 5.2 [GREEN] normalization + merge functions
- [ ] 5.3 [RED] integration tests: cross-patient isolation (adversarial query), ranking order, `candidate_limit: 50` bound, decrypt strictly after LIMIT
- [ ] 5.4 [GREEN] `lib/alethea/clinical_record/rag/retrieval.ex`: `search(%Professional{}, patient_id, query, opts)`
- [ ] 5.5 [RED] freshness test: pending/in-flight `oban_jobs` for patient → `%{stale?: true, pending: n}`
- [ ] 5.6 [GREEN] freshness query in search result envelope
- [ ] 5.7 [RED] authz test: non-treating professional denied
- [ ] 5.8 [GREEN] authz via `get_patient_for_professional/2`

## Phase 6: Rebuild Entry Point

- [ ] 6.1 [RED] integration test: `mix alethea.rag.reindex` re-enqueues outbox jobs for all eligible resources of a patient; result converges idempotently (no duplicate chunks)
- [ ] 6.2 [GREEN] `lib/mix/tasks/alethea.rag.reindex.ex`: `--patient-id <uuid> [--confirm]`, re-enqueues (does not embed inline)

## Phase 7: LiveView + Router

- [ ] 7.1 [RED] `test/alethea_web/live/patient_live/clinical_search_test.exs`: `badge badge--non-authoritative` on every result (non-dismissible); citation resolves to source row; unauthorized professional blocked; `:never_indexed` vs `:no_match` empty states; results re-`stream/3` with `reset: true` per query
- [ ] 7.2 [GREEN] `lib/alethea_web/live/patient_live/clinical_search.ex` + `router.ex` route `/patients/:patient_id/clinical-search` inside `live_session :require_authenticated_professional`

## Phase 8: Docs / Verification

- [ ] 8.1 `docs/main-demo-operator-guide.md`: document `mix alethea.rag.reindex` usage
- [ ] 8.2 `mix precommit` — full compile/format/test pass
