# Proposal: Session transcript RAG ingestion and chunking (#320)

**Status:** decided — D-A, D-B, D1-D5 locked by user · **Parent:** #314 (R5) · **Depends on:** #317 (merged, fa6e836) · **Unblocks:** #328

## Intent

`create_session_transcript/3` already enqueues `session_transcript_created` (`lib/alethea/clinical_record.ex:459`), but `Rag.Indexer.eligibility/1` has no clause for it, so the catch-all at `indexer.ex:84` quietly acknowledges it. As a result, recorded sessions can't be found through semantic search or the Workbench, even though Retrieval (`retrieval.ex:320-321`) and the Workbench label (`review.ex:1207-1208`) already handle `"session_transcript"`. This change connects the ingest side: speaker-attributed, time-bounded, encrypted, embedded chunks.

## Scope

### In Scope
- `eligibility("session_transcript_created")` -> `{:index, :session_transcript}`.
- `fetch_and_decrypt(:session_transcript, ...)`: decrypt `encrypted_spans` under `resolve_dek(2, ...)`, `SessionTranscriptContent.parse/1` -> spans.
- Pure `chunk_spans/1`: one span = one chunk (`full_event: true`). A span over the ~500-token budget is sub-split with the existing splitter + 15% overlap. Each sub-piece keeps the span's speaker and its start/end.
- Migration + `Chunk` schema/changeset: nullable `speaker`, `audio_start_seconds`, `audio_end_seconds`.
- `rag_fixtures.ex` `insert_chunk!` opts for the new columns.
- Tests: indexer unit + worker integration, plus an AC4 proof that legal deletion of a transcript purges its chunks.

### Out of Scope
- Retrieval, `Citation`, and `Consultation.Source` exposure of speaker/time, mm:ss formatting, and any `lib/alethea_web/` change (#328, D-B).
- Merging consecutive same-speaker turns (open question, revisit with real data).
- Audio capture/diarization producers; transcript update/re-diarization events.
- Retrieval voice balancing (the same deferral as #262 Q5).

## Capabilities

### New Capabilities
- `session-transcript-rag-ingestion`: indexes transcripts into speaker- and time-attributed encrypted chunks, and purges those chunks on deletion.

### Modified Capabilities
- None (`openspec/specs/` absent; repo uses `openspec/sdd/{slug}-{issue}/`).

## Locked facts

| # | Fact | Basis |
|---|---|---|
| L1 | No new producer. The existing outbox event is reused | `clinical_record.ex:459`, `outbox.ex:58` |
| L2 | AC4 needs no new plumbing: `legally_delete_record` enqueues `Outbox.tombstone_event` -> `clinical_record_legally_deleted` -> `replace_chunks({type,id}, [])` | `retention.ex:62,276`, `outbox.ex:70-81`, `indexer.ex:73,291-295` |
| L3 | `source_occurred_at = recorded_at` (already `utc_datetime_usec`, no `to_usec` widening needed) | `session_transcript.ex:36` |
| L4 | `target_behavior_id = nil` | Schema has no such field (#317 F1) |
| L5 | Chunk `encryption_version = 2`, re-encrypted under the CR DEK | `session_transcript.ex:31` |
| L6 | Column names `speaker`, `audio_start_seconds`, `audio_end_seconds` store raw seconds. Formatting is #328's job | D-B |

## User-locked decisions

| # | Decision |
|---|---|
| D-A | Per-speaker-turn chunking. Oversized spans are sub-split and inherit the speaker and start/end |
| D-B | #320 stops at persisting the columns. Exposure goes to #328 |
| D1 | Audio seconds are `:float` (double precision). Whisper emits fractional seconds, and sub-second precision matters for citation jump-to. Rejected: integer (loses precision on short turns), decimal (heavier, spans are `number()`) |
| D2 | Skip blank/whitespace-only spans. If none remain, write zero chunks and ack `:ok`. Prevents the infinite retry from `PatientVault.encrypt("")` returning `{:error, :empty_plaintext}` (`patient_vault.ex:19`). Rejected: `{:cancel, :empty_transcript}` |
| D3 | `speaker` is stored as a plaintext string (`"patient"` / `"therapist"`) on chunk rows. **Accepted deviation** from the CLAUDE.md encryption mandate, following the #317 `audio_duration_seconds` precedent: it is a 2-value role, not an identity, and #328 needs SQL filtering without decryption. Known exposure: turn-taking pattern (who spoke, when, how long) is visible to anyone with DB access. Rejected: encrypting speaker inside `encrypted_content` |
| D4 | Sentiment regression test waived: ingestion is embed-only and RoBERTa / the emotion pipeline are untouched (#262 precedent). Rejected: guard test |
| D5 | Therapist turns ARE indexed. The AC requires speaker attribution; the `speaker` column lets #328 filter or label therapist wording so it is not presented as patient evidence |

All decisions locked by the user on 2026-09-25.

## Approach

- `index_resource` branches for `:session_transcript`: it calls `chunk_spans(spans)` instead of `chunk(plaintext)`.
- Pieces carry optional `speaker`/`audio_start_seconds`/`audio_end_seconds`. `encrypt_chunk_attrs` copies them through. Other kinds stay `nil`.
- `insert_all` bypasses the changeset, so integer seconds must be normalized to the column type (design).
- Open design point: whether embedded text gets a speaker prefix (`"Paciente: ..."`). Recommended: no. Speaker lives in the column, and chunk text stays verbatim for citation.

## Affected Areas

| Area | Impact | Description |
|------|--------|-------------|
| `lib/alethea/clinical_record/rag/indexer.ex` | Modified | eligibility, fetch clause, `chunk_spans/1`, attr threading |
| `lib/alethea/clinical_record/rag/chunk.ex` | Modified | 3 fields + cast |
| `priv/repo/migrations/<ts>_add_transcript_metadata_to_rag_chunks.exs` | New | 3 nullable columns |
| `test/support/fixtures/rag_fixtures.ex` | Modified | opts |
| `test/alethea/clinical_record/rag/`, `test/alethea_jobs/` | New/Modified | chunking, ingest, deletion purge |

## Risks

| Risk | Likelihood | Mitigation |
|------|------------|------------|
| High chunk/embedding volume from short turns | Med | Accepted (D-A). Revisit merging with real data |
| Blank span causes an infinite Oban retry | High without D2 | D2 filter + test |
| Plaintext speaker flagged as PII | Med | D3 explicit, recorded deviation |
| Speaker/time columns unused until #328 | Low | Names and types fixed for #328 (L6) |

## Rollback Plan

Single additive PR. Revert the commit and `mix ecto.rollback` one step (drops the 3 nullable columns; existing chunks unaffected). Without the eligibility clause, events fall back to the `{:unknown, _}` ack, so no jobs fail. Stale transcript chunks can be purged via `replace_chunks/2`.

## Forecast

~330-380 changed lines (lib ~110, migration ~20, tests ~200-250). 400-line budget risk: Medium.

## Success Criteria

- [ ] A `session_transcript_created` event produces one chunk per non-blank span with the correct speaker, start/end, `recorded_at`, v2 ciphertext, and `bge-m3` embedding.
- [ ] An oversized span yields N sub-chunks that all share its speaker and start/end.
- [ ] No span text appears in plaintext columns or in `oban_jobs.args`.
- [ ] Legal deletion of a transcript leaves zero chunks for it.
- [ ] A blank-only transcript acks without retry loops (per D2).
- [ ] Existing resource kinds are unchanged (new columns stay `nil`).
