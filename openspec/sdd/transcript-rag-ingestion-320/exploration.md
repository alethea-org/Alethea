# Exploration: transcript-rag-ingestion-320

Issue: #320 — Session transcript RAG ingestion and chunking. Parent spec: #314. Blocked by: #317 (`SessionTranscript` entity, not yet built).

## Current State

RAG projection pipeline (introduced by clinical-rag-projection #196, extended by telegram-rag-ingestion-262 #262):

```
outbox event (5-key args: event / resource_type / resource_id / patient_id / professional_id)
  -> AletheaJobs.ClinicalRecordOutboxWorker (queue :clinical_record_outbox)
  -> Alethea.ClinicalRecord.Rag.Indexer.index_event/1
       eligibility/1 dispatch
       -> fetch_and_decrypt (auth -> KEK -> patient/CR DEK via Accounts.load_professional_kek/1
          + load_patient_dek/2; resolve_dek/4 per source encryption_version)
       -> chunk/1   (ADR-003: whole event is the chunk unit; sub-split only above ~500 tokens
                     on paragraph/sentence boundaries with 15% overlap; @tokens_per_word 1.35)
       -> embed_chunks/1 (AI.embeddings() = local Ollama bge-m3, 1024-dim; ADR-002: no external API)
       -> re-encrypt each piece under source DEK (PatientVault.encrypt/2)
       -> replace_chunks/2 (delete-by-resource + insert_all in one transaction; idempotent)
```

Outbox producers:

- `Alethea.ClinicalRecord.Outbox.event/2` — ClinicalRecord structs.
- `Alethea.Clinical.Outbox.event/3` — mirrored module for cross-context structs (e.g. `Message`). Exists only to respect the hexagonal cross-context import ban (AD1 of #262's design).

Chunk schema `clinical_record_rag_chunks` (`lib/alethea/clinical_record/rag/chunk.ex`): fixed columns only — `source_resource_type`, `source_resource_id`, `chunk_index`, `encrypted_content`, `encryption_version`, `embedding`, `embedding_model`, `token_count`, `full_event`, `source_occurred_at`, `patient_id`, `professional_id`, `target_behavior_id` (nullable). **No generic metadata map.**

FKs: `patient_id` ON DELETE CASCADE, `professional_id` ON DELETE RESTRICT, `target_behavior_id` ON DELETE SET NULL. Source has no FK (polymorphic by design).

Already pre-wired for transcripts (verified):

- `Rag.Retrieval.filter_by_source/2` (`lib/alethea/clinical_record/rag/retrieval.ex:320-321`) matches `"session_transcript"` / `"session_transcripts"` under `:sessions`.
- `source_kind_label/1` in `lib/alethea_web/live/target_behavior_live/review.ex:1020-1021` labels both as "Transcripción de sesión".

Deletion: `Indexer.eligibility("clinical_record_legally_deleted")` returns `{:tombstone, :legal_deletion}` (`indexer.ex:73`), which empties the chunk set of **any** `resource_type` via `replace_chunks({type, id}, [])`. No Indexer change needed for AC4 — only a correct emission call site. `RetentionSweepWorker` / `Alethea.ClinicalRecord.Retention` only scan ClinicalRecord tables today (open #271 is the same gap for `patient_message`).

## Affected Areas

- `lib/alethea/clinical_record/rag/indexer.ex` — new pure `chunk_spans/1` (buildable now); new `eligibility/1` + `fetch_and_decrypt` clause (blocked on #317).
- `lib/alethea/clinical_record/rag/chunk.ex` + new migration — nullable `speaker`, `audio_start_seconds`, `audio_end_seconds` (buildable now).
- New or extended outbox producer — location depends on #317's bounded context (blocked).
- `lib/alethea/clinical_record/rag/citation.ex`, `lib/alethea/clinical_record/rag/consultation/source.ex` — carry no speaker/timestamp fields; decide whether #320 threads them through or defers to #328.
- `lib/alethea_jobs/retention_sweep_worker.ex` / `Alethea.ClinicalRecord.Retention` — transcript retention coverage unconfirmed.
- `test/support/fixtures/rag_fixtures.ex` — `insert_chunk!/5` needs optional speaker/timestamp opts.

## Buildable Now vs Blocked by #317

| Buildable now | Blocked by #317 |
|---|---|
| Pure `chunk_spans/1` over plain `%{start_seconds, end_seconds, text, speaker}` maps | Real `SessionTranscript` module/fields and `encryption_version` |
| Migration + `Chunk` changeset for `speaker`, `audio_start_seconds`, `audio_end_seconds` | Owning bounded context -> outbox producer shape |
| Test fixture opts for the new columns | Transcript deletion emitting `clinical_record_legally_deleted` |
| Draft `eligibility/1` event-name contract (against a documented assumption) | `fetch_and_decrypt(:session_transcript, ...)` clause; retention sweep coverage |

## Approaches — Chunking Strategy for Speech Spans

1. **Per-speaker-turn (recommended)** — each span is one chunk (`full_event: true`); only a single span above ~500 tokens is sub-split with the existing sentence/paragraph splitter + 15% overlap.
   - Pros: aligns with ADR-003 citation-precision doctrine; one speaker per chunk; exact audio boundaries.
   - Cons: many short utterances ("Sí.", "¿Y luego?") -> high-volume, low-signal chunks and embedding calls.
   - Effort: Low (reuses `pack_sentences` / `expand_oversized` / overlap helpers).
2. **Token-budget merge of consecutive same-speaker spans** — greedily pack up to ~500 tokens; start/end = min/max of merged spans.
   - Pros: fewer, denser chunks; better embedding signal; still single-speaker.
   - Cons: blurs per-utterance citation; contradicts ADR-003 rationale.
   - Effort: Low-Medium.
3. **Fixed time window ignoring speakers** — rejected: violates the "preserve speaker identity" acceptance criterion.

## Recommendation

Option 1. Keep Option 2 as an explicit open question for `design.md`, to revisit with real span-length data once #317 transcripts exist.

## Risks

1. #317 does not exist — all `SessionTranscript` names/fields are assumptions; nothing may hardcode against them.
2. Bounded-context ownership of `SessionTranscript` decides the outbox producer design (extend `ClinicalRecord.Outbox` vs new parallel module).
3. `Citation` / `Consultation.Source` lack speaker/timestamp fields — decide scope now vs #328 to avoid duplicate migrations.
4. AC4 has a ready consumer-side mechanism but an unconfirmed producer-side trigger; retention sweep does not cover transcripts (parallels #271).
5. Per-turn chunking may produce high row/embedding volume for long sessions — validate against real data.

## Ready for Proposal

Partially. Scope the proposal to the buildable-now slice (chunker + schema columns + fixtures); document outbox producer and deletion wiring as a follow-up pending #317.
