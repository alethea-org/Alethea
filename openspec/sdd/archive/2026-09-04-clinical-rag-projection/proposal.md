# Proposal — clinical-rag-projection

**Source issue:** alethea-org/Alethea#196 — "Deliver the non-authoritative RAG projection and retrieval view"
**Artifact store:** hybrid (mirrored to Engram `sdd/clinical-rag-projection/proposal`)
**Strict TDD:** active — test runner `mix test`.
**Depends on exploration:** `openspec/sdd/clinical-rag-projection/explore.md` (Engram `sdd/clinical-rag-projection/explore`).
**Fixed inputs (not re-decided here):** ADR-002 (BGE-M3 local via Ollama), ADR-003 (RAG = navigable clinical history; chunk = complete semanticable event; on-demand rebuild; single immediate-purge mechanism; pgvector + Postgres FTS hybrid, no reranker).

## Intent

**Problem.** `ClinicalRecord` already emits a transactional outbox event for every clinician write, but `AletheaJobs.ClinicalRecordOutboxWorker.perform/1` returns `:ok` unconditionally. Nothing is chunked, embedded, stored, or retrievable. The psychologist cannot ask a natural-language question over their own clinical record; they can only navigate structurally, one target behavior at a time, through `TargetBehaviorLive.Review`.

**Why now.** The producing half (outbox + immutable clinical writes) is done and verified. The consuming half is a documented no-op seam that grows staler with every event type added. Every additional week of clinician-authored notes, evidence, and observations accumulates as unindexed history that a later backfill must re-embed.

**Success.** A clinician-authored write becomes retrievable through the projection within one job cycle; a patient-scoped search returns passages labeled as **non-authoritative** with exact citations back to the authoritative `ClinicalRecord` row; retries never duplicate a chunk.

## Scope

### In scope

- **New projection store.** Migration enabling `vector` and creating `clinical_record_rag_chunks` (patient-scoped, `vector(1024)`, per-chunk metadata: source resource type/id, chunk index, full-event-vs-subchunk flag, token count, embedding model).
- **Ingest path.** Rework `ClinicalRecordOutboxWorker` from no-op to a dispatcher over a new `Alethea.ClinicalRecord.RAG.Indexer` (eligibility → chunking → embedding → upsert), with real retries and DB-level idempotency.
- **Chunking** per ADR-003: chunk = one complete semanticable event; sub-split only when event free text exceeds ~500 tokens, on sentence/paragraph boundaries, ~15% overlap.
- **Embedding** through the existing `Alethea.AI.Embeddings` behaviour only (adapter-agnostic; `Fake` in test).
- **Hybrid retrieval query module** `Alethea.ClinicalRecord.RAG.Retrieval` — patient-scoped, dense + lexical, no reranker.
- **Patient-scoped retrieval LiveView** with non-authoritative labeling and exact source citations.
- **On-demand rebuild entry point** (manual/ops-triggered; no cron).

### Out of scope

- **Patient-voice and system-voice content.** This change indexes the **psychologist voice only** — `Alethea.ClinicalRecord` outbox content. Patient Telegram messages and system-inferred RoBERTa labels live in `Alethea.Clinical`, which has **no outbox**; building one is explicitly not part of this change. ADR-003's three-voice model stays a future extension.
- **Deletion / tombstone handling.** No producer exists (no delete function, no tombstone field, no delete outbox event anywhere in `ClinicalRecord`) — that is issue #197. Known limitation, documented, shipped without it. The consumer's event dispatch must remain open for a future tombstone event type (no exhaustive-list structure that would force a rework), but **no speculative tombstone code is written** — there is nothing to test it against.
- **`Alethea.AI.Embeddings.Ollama` (the real adapter)** — see decision D1.
- Attachment/PDF/OCR ingestion (ADR-003 already excludes it), reranking, GraphRAG, retention windows (#197), and any change to the outbox producer.

## Capabilities

> No `openspec/specs/` source-of-truth tree exists in this repo; the delta lands at `openspec/sdd/clinical-rag-projection/spec.md` per repo convention.

### New capabilities

- `clinical-rag-projection`: non-authoritative, patient-scoped semantic projection of the clinical record — ingest eligibility, chunking, embedding, idempotent upsert, hybrid retrieval, and the retrieval view contract.

### Modified capabilities

- None (no existing spec file governs the outbox consumer today; its behavior change is captured inside the new capability).

## Approach

```
ClinicalRecord write (Ecto.Multi)
  └─ Outbox.event/2 → Oban job {event, resource_type, resource_id, patient_id, professional_id}
       └─ ClinicalRecordOutboxWorker  (retries + backoff)
            └─ RAG.Indexer
                 ├─ eligibility(event)     → :index | :ignore
                 ├─ load authoritative row (decrypt via patient vault key)
                 ├─ chunk/1                → [%Chunk{}] (full event, or sub-chunks)
                 ├─ AI.embeddings().embed  → 1024-d vectors (local Ollama, no external call)
                 └─ replace_chunks/2       → delete-by-source + insert (single transaction)

Retrieval:  RAG.Retrieval.search(patient_id, query, opts)
              └─ dense candidate set (pgvector cosine, patient-scoped)
                 → decrypt candidates → lexical rescoring → merged ranking
                    └─ PatientLive retrieval view (non-authoritative badge + exact citations)
```

### Key decisions

| # | Decision | Rationale |
|---|---|---|
| **D1** | **`Alethea.AI.Embeddings.Ollama` ships as a separate prerequisite change**, not in this PR. This change codes against the `Alethea.AI.Embeddings` behaviour and tests with `Fake`. | Three reasons. (a) Budget: this slice already carries a migration, a reworked worker, a chunker, a query module, and a LiveView — adding an HTTP adapter pushes the 400-line single-PR budget past recoverable. (b) Operational readiness is its own work: BGE-M3 is in **no ops runbook** (`docs/main-demo-operator-guide.md` documents only `phi4-mini`), `:ai_embeddings` is configured **only in `config/test.exs`**, and both `Embeddings` and `Embeddings.Fake` moduledocs still point at the reverted `Embeddings.HF` decision. That is a self-contained adapter+config+docs change with its own verification. (c) The behaviour seam already exists, so the dependency is a merge-order constraint, not a code coupling. |
| **D2** | **`TargetBehavior` definition text is structural metadata, not an indexed chunk.** `target_behavior_created` is a recognized-but-not-indexed event (explicit `:ignore` with reason, not a silent drop). | It is a short operationalized label, not clinical narrative. Embedding one-line labels injects high-similarity noise that competes with real evidence in dense retrieval, and the same text is already reachable as the parent scope of the notes/evidence/observations that cite it. It stays valuable as a **filter facet** on chunks. Structured browsing of target behaviors is already served by `TargetBehaviorLive.Review`. |
| **D3** | **Idempotent retry.** Raise `max_attempts` from `1` to `5` with Oban exponential backoff. Idempotency is DB-level: unique index on `(source_resource_type, source_resource_id, chunk_index)`, and per-event ingest is a single transaction that **deletes all chunks for that resource, then inserts** the freshly computed set. | Natural key is the **resource** identity, not the outbox event id — an event id is unique per emission, which would make a re-emit append instead of replace. Delete-then-insert makes a retry converge to the same row set, and gives correct replace-on-re-embed semantics for free to the two mutable sources (D4, D5). Transient failures (embedding/HTTP) return `{:error, _}` → retry; malformed args return `{:cancel, _}`; policy-ignored events return `:ok`. |
| **D4** | **`FunctionalAnalysisDraft` is eligible** on `functional_analysis_draft_saved`; every save re-embeds and **replaces** (no versioning). | Clinician-authored/curated, not an AI proposal. Replace-on-save matches its "no version history, single row" design (D4 of its own change). Falls out of D3 for free. |
| **D5** | **`AIProposal` is eligible only on `ai_proposal_accepted`.** Never on pending, never on `ai_proposal_edited` without acceptance, never on `ai_proposal_discarded`. | Acceptance is the clinical confirmation action that converts a provisional suggestion into clinician-endorsed content. There is no `ai_proposal_created` outbox event today, which is correct and must stay that way — pending proposals must never enter the index. |
| **D6** | **Retrieval view is a new patient-scoped LiveView** (e.g. `AletheaWeb.PatientLive.ClinicalSearch` at a patient-scoped route), reusing `TargetBehaviorLive.Review`'s card/citation presentation components — not extending that LiveView. | `Review` is scoped to a single `target_behavior_id`; the retrieval surface is patient-scoped, query-driven, and has a different authorization scope and lifecycle. Reuse the presentation, not the container. Exact route/placement is a design-phase detail. |
| **D7** | **Embedding dimensionality is 1024** (BGE-M3 dense). The stale `vector(384)` hint in the deferred `priv/repo/migrations/20260526141108_add_sessions_and_embeddings.exs` comment MUST NOT be copied, and MUST be corrected/annotated when the real migration lands. | 384 predates ADR-002's 2026-09-02 revision. Copying it produces a silently wrong column that only fails at first insert. |
| **D8** | **No PII sanitizer on the embedding path.** | `Alethea.AI.Sanitizer` guards **external** LLM calls. BGE-M3 runs locally via Ollama; nothing leaves the host. Redacting before embedding would degrade retrieval quality for no privacy gain. Raw embeddings remain PII and MUST never be sent to an external API (security mandate 2). |
| **D9** | **Chunk text is encrypted via `Alethea.Encryption.PatientVault` (AES-256-GCM, the same mechanism `ClinicalNote`/`ConsultationEvidence` already use — not Cloak.Ecto directly, which in this codebase only wraps professional KEKs); the vector column is not.** Consequence: retrieval is **dense-first**, with lexical scoring applied in-application over the decrypted candidate window — there is **no plaintext `tsvector` column**. | Security mandate 1 requires patient-level encryption of sensitive content, and a Postgres FTS lexeme index over clinical text is a reversible plaintext derivative. The vector column cannot be encrypted (pgvector must compute distance) and is accepted as local-only PII. **This narrows ADR-003's "hybrid = pgvector + Postgres FTS" wording** and is the single largest item for `sdd-design` to confirm — it may warrant an ADR-003 amendment. |

## Affected areas

| Area | File | Impact |
|---|---|---|
| Migration | `priv/repo/migrations/*_add_clinical_record_rag_chunks.exs` | New — `CREATE EXTENSION IF NOT EXISTS vector`, chunks table, `vector(1024)`, unique + vector indexes |
| Projection schema | `lib/alethea/clinical_record/rag/chunk.ex` | New — Cloak-encrypted content, per-chunk metadata |
| Ingest | `lib/alethea/clinical_record/rag/indexer.ex` | New — eligibility, chunking, embedding, transactional replace |
| Retrieval | `lib/alethea/clinical_record/rag/retrieval.ex` | New — patient-scoped dense + lexical query |
| Rebuild | `lib/alethea/clinical_record/rag.ex` (or Mix task) | New — on-demand full rebuild entry point |
| Outbox consumer | `lib/alethea_jobs/clinical_record_outbox_worker.ex` | Modified — no-op → dispatcher; `max_attempts: 1` → `5` + backoff |
| Consumer test | `test/alethea_jobs/clinical_record_outbox_worker_test.exs` | Modified — currently locks the no-op contract in place |
| Retrieval view | `lib/alethea_web/live/patient_live/clinical_search.ex` + router | New — patient-scoped LiveView |
| Doc drift (note only) | deferred migration comment, `Embeddings`/`Embeddings.Fake` moduledocs | Flagged; the moduledoc fix belongs to the D1 prerequisite change |

## Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| **400-line single-PR budget overrun.** Migration + schema + indexer + retrieval + reworked worker + LiveView + strict-TDD tests. | **High** | D1 already removes the adapter. `sdd-tasks` MUST emit the guard forecast and recommend a chained slice (PR1 = migration + ingest, PR2 = retrieval + view) or an explicit `size:exception`. Cached strategy is `single-pr` — this needs an orchestrator decision before apply. |
| **Encryption vs. lexical retrieval (D9).** ADR-003 assumes a Postgres FTS half that the encryption mandate forbids. | High | Dense-first + in-application lexical rescoring. Confirm in `sdd-design`; may require an ADR-003 amendment. Cost: keyword-only matches outside the dense candidate set are missed. |
| **No tombstone producer (#197).** Retracted or superseded material stays indexed. | Certain | Documented known limitation; consumer dispatch stays open for a future event type; #196's "tombstoned material excluded" AC is untestable until #197 lands. |
| **BGE-M3 not in any ops runbook.** `:ai_embeddings` unset outside `:test`; ingest would raise in dev/prod. | High | Owned by the D1 prerequisite change (adapter + dev/runtime config + runbook entry), which must merge first. |
| **Chunk-count growth / vector index tuning** on a table that grows with every clinician write. | Medium | Patient-scoped queries with a vector index; index type and parameters deferred to `sdd-design`. |
| **Decrypt-per-candidate latency** in the retrieval path. | Medium | Bounded candidate window before decryption; measure in verify. |

## Rollback plan

The projection is **non-authoritative by definition** — it derives entirely from `ClinicalRecord`, which is untouched. Rollback = revert the PR + run the migration `down` (drops `clinical_record_rag_chunks`; leaves the `vector` extension in place, which is inert). The worker returns to its no-op contract; queued outbox jobs drain harmlessly because that is exactly today's behavior. No clinical data is lost, and the index is fully reconstructible via the on-demand rebuild.

## Dependencies

- **Blocking:** `Alethea.AI.Embeddings.Ollama` prerequisite change (D1) — adapter + `:ai_embeddings` dev/runtime config + BGE-M3 in `docs/main-demo-operator-guide.md`. This change is developable and testable against `Fake` in parallel, but not operationally verifiable until that merges.
- **Non-blocking / follow-up:** issue #197 (deletion, tombstoning, retention window).

## Success criteria

- [ ] A `clinical_note_created` / `consultation_evidence_created` / `clinician_observation_created|updated` / `ai_proposal_accepted` / `functional_analysis_draft_saved` event produces chunks retrievable for that patient.
- [ ] `target_behavior_created` is explicitly recognized and produces no chunk.
- [ ] A pending or discarded `AIProposal` is never indexed.
- [ ] Re-running the same job (or re-saving an observation/draft) leaves exactly one chunk set per source resource — no duplicates.
- [ ] Retrieval is patient-scoped: no chunk from another patient is ever returned.
- [ ] Every result carries an exact citation to its authoritative source row and is visibly labeled non-authoritative.
- [ ] Chunk metadata is sufficient to reindex without re-deriving provenance (source, model, chunking).
- [ ] `mix precommit` passes.

## Proposal question round — CLOSED (confirmed 2026-09-03)

Product decisions for #196 were confirmed directly by the user before this phase (scope narrowing, `FunctionalAnalysisDraft` eligibility, `AIProposal`-on-accept, ship-without-tombstones) and are encoded above. The four residual product assumptions below were put back to the user and all four confirmed as originally assumed:

1. **Empty/no-result state — CONFIRMED: distinguish.** The view must distinguish "nothing indexed yet for this patient" from "indexed, but no match for this query." Rationale: during rollout, "nothing indexed yet" is the common case and a generic "no results" reads as a bug.
2. **Non-authoritative labeling strength — CONFIRMED: persistent badge + citation per result.** Not a one-time banner. A clinician must never be able to quote a retrieved passage as if it were the record itself.
3. **Retrieval-view access scope — CONFIRMED: same as existing patient-scoped surfaces.** Only the treating professional. No new sharing or export affordance in this slice.
4. **Lexical-recall tradeoff (D9) — CONFIRMED: acceptable for this first version.** A keyword outside the dense candidate window (e.g. an exact medication name or date) may not surface. This is an explicit, accepted limitation of the non-authoritative consultation aid, not a defect. Future iteration (wider candidate window, or a separate exact-match structure compatible with the encryption mandate) is possible but out of scope here.
