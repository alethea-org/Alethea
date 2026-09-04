# Verification Report

## Completeness table

| Phase | Tasks | Status | Code evidence |
|---|---|---|---|
| 0 Fake embeddings fix | 0.1-0.2 | done | lib/alethea/ai/embeddings/fake.ex deterministic 1024-dim non-zero vectors; fake_test.exs |
| 1 Migration | 1.1-1.3 | done | priv/repo/migrations/20260904000131_create_clinical_record_rag_chunks.exs; confirmed up in test DB via mix ecto.migrations |

## Build evidence

- MIX_ENV=test mix compile --warnings-as-errors --force -> exit 0
- mix test -> exit 0, 908 tests, 0 failures, 5 skipped

## Spec compliance matrix

| # | Requirement | Result |
|---|---|---|
| 1 | Ingest Eligibility by Event Type | PASS |
| 2 | Chunking Behavior | PASS |
| 3 | Idempotent Retry and Replace Semantics | PASS |
| 4 | Patient Isolation | PASS |
| 5 | Citation and Non-Authoritative Labeling | PASS |
| 6 | Freshness Disclosure | PASS |
| 7 | Empty States | PASS |
| 8 | Contradictory Evidence Retention | PASS |
| 9 | Access Control | PASS |
| 10 | Failure Isolation | PASS |
| 11 | On-Demand Rebuild | PASS |
| 12 | Explicit Non-Requirements | PASS |
| 13 | Access Control restated | PASS |

## Design decision verification

- Local BGE-M3/Ollama-shaped embeddings interface (no external API call): PASS
- Patient-level encryption on Chunk (PatientVault.encrypt/2 under patient DEK): PASS
- Decrypt-strictly-after-candidate-limit ordering in Retrieval.search/4: PASS, confirmed by a dedicated adversarial test with corrupt-ciphertext rows outside the candidate window
- RAG non-authoritative, badge non-dismissible: PASS
- On-demand-only reindex, no cron/scheduler: PASS
- SPONTANEOUS/ELICITED tagging: not applicable to this change, correctly out of scope
- message_id-style source anchoring / citation resolving to real source row: PASS
- HNSW over IVFFlat, migration independence from the stale vector(384) comment: PASS
- Rebuild-via-Mix-task reuses the exact same outbox path (no inline embedding): PASS

## Issues

CRITICAL: None found.

WARNING-1: Stale BLOCKED notes in openspec/sdd/clinical-rag-projection/tasks.md Phase 1 and Phase 2 (documentation only, no code defect). Tasks 1.3 and 2.1 still carry inline prose saying the migration and test were blocked by a missing pgvector extension binary, predating the later Docker pgvector swap (commit f17cce9, same WU1 batch) that resolved the environment gap. Confirmed this session: mix ecto.migrations shows the RAG chunks migration as up, and the full test suite passes clean with 0 failures. The checkboxes are correctly marked complete; only the descriptive text is stale. Recommend a one-line tasks.md edit before archive, not blocking.

SUGGESTION-1: Requirement 8 (Contradictory Evidence Retention) and Requirement 10 (Failure Isolation) are verified by code-absence and architecture reading rather than a dedicated named test. The property holds today because no merge or dedup code exists anywhere in the diff, but a future change adding a similarity-based post-filter to Retrieval.search/4 would silently violate this requirement without a regression test catching it. Consider one small dedicated test for each in a future hardening pass, not blocking archive.

SUGGESTION-2: The reindex mix task dry-run and confirm output format is undocumented in any machine-readable schema, fine for an operator runbook but worth noting if it ever needs to be scripted or parsed later.

## Scope leakage check (#197 boundary)

Confirmed no retention-window or time-based policy and no deletion/tombstone logic exists anywhere in the diff. The tombstone seam (eligibility/1 trailing unknown-event catch-all) is present and correctly inert: it acknowledges unknown future events without crashing but implements zero delete or purge behavior itself, matching ADR-003 deferral of retention windows to #197 and the spec explicit non-requirement scenario for deletion/tombstone handling.

## Environment facts re-confirmed (not re-flagged as new)

1. pgvector Docker db service healthy, migration up, confirmed directly this session.
2. Repo-wide CRLF/core.autocrlf-driven format-check failure, pre-existing, out of scope, not touched.
3. pacer_test.exs flaky ETS test did not fail this run; unrelated file, untouched by the diff.
4. Alethea.ObanTelemetry.handle_stop/4 badkey/success error confirmed still present in this run log (oban-job-stop-handler detached), pre-existing, harmless, out of scope.

## Final verdict

PASS WITH WARNINGS (1 non-blocking documentation WARNING, 2 non-blocking SUGGESTIONs, 0 CRITICAL)
