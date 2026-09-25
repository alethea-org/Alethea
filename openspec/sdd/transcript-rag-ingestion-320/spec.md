# Spec: Session transcript RAG ingestion and chunking (#320)

## Domain: `session-transcript-rag-ingestion` (New Capability)

## Purpose

What must be true once `session_transcript_created` outbox events are indexed: eligibility routing, decryption under the clinical-record DEK, per-speaker-turn chunking with unmodified time inheritance on sub-split, the three new nullable `Chunk` columns, blank-span handling with an observable warning, encryption/embedding, no-plaintext-leak, idempotent replace/purge (AC1–AC4), and the boundary this change does not cross (D-B), including the obligation it hands to #328.

## Requirements

### Requirement: Eligibility routes transcript creation to indexing (AC1)

`eligibility/1` MUST classify `"session_transcript_created"` as `{:index, :session_transcript}` instead of falling through to `{:unknown, _}`.

#### Scenario: Transcript creation event is recognized
- GIVEN a dispatched `session_transcript_created` event
- WHEN `eligibility/1` classifies it
- THEN it returns `{:index, :session_transcript}`

### Requirement: Transcript content is fetched and decrypted under the CR DEK

`fetch_and_decrypt(:session_transcript, ...)` MUST resolve the DEK via `resolve_dek(2, ...)`, decrypt `encrypted_spans`, and return spans via `SessionTranscriptContent.parse/1`, plus `occurred_at = recorded_at` and `target_behavior_id = nil` (L3, L4).

#### Scenario: Spans decrypt with the clinical-record DEK
- GIVEN a persisted transcript with `encryption_version = 2`
- WHEN `fetch_and_decrypt/5` runs for it
- THEN it returns the transcript's spans in order, `occurred_at` equal to `recorded_at`, and `target_behavior_id = nil`

### Requirement: Chunking is per speaker turn (D-A, AC2)

`chunk_spans/1` MUST produce one chunk per non-blank span (`full_event: true`) and carry that span's `speaker`, start, and end unchanged into the chunk piece.

#### Scenario: One turn yields one chunk with its speaker and bounds
- GIVEN a transcript with 3 non-blank spans of alternating speakers
- WHEN `chunk_spans/1` runs
- THEN it returns 3 pieces, each `full_event: true` with the source span's `speaker`, `start`, and `end`

### Requirement: Oversized turns sub-split; every piece inherits the parent's time bounds unchanged (D-A, R-X2)

A span whose token count exceeds `@max_tokens` MUST be sub-split by the existing splitter with 15% overlap. Every resulting piece MUST carry the parent span's original `speaker`, `start`, and `end` verbatim — no interpolation by character or word offset. This is a documented guarantee: consumers (#328) MUST NOT assume sentence-level time precision from a sub-piece's citation.

#### Scenario: All sub-pieces of one oversized turn share its full time range
- GIVEN one span over the token budget with `speaker: "patient"`, `start: 10.0`, `end: 340.0`
- WHEN `chunk_spans/1` sub-splits it into N pieces
- THEN every piece has `speaker: "patient"`, `audio_start_seconds: 10.0`, and `audio_end_seconds: 340.0`

### Requirement: Blank turns are skipped; an all-blank transcript is a logged zero-chunk success (D2)

Spans whose text is empty or whitespace-only MUST be excluded before chunking. When no span remains, indexing MUST write zero chunks and the job MUST ack `:ok` (never retry, never `{:cancel, ...}`).

#### Scenario: Blank spans are dropped, remaining turns index normally
- GIVEN a transcript with one blank-only span and two non-blank spans
- WHEN it is indexed
- THEN exactly 2 chunks are written and the blank span produces none

#### Scenario: An all-blank transcript acks without retrying
- GIVEN a transcript whose every span is blank or whitespace-only
- WHEN it is indexed
- THEN zero chunks are written and `index_event/1` returns `:ok`

### Requirement: Zero-chunk indexing emits an observable warning (R-X1)

When indexing a `:session_transcript` resource yields zero chunks, the indexer MUST emit one `Logger.warning` containing the transcript's `resource_id`. The message MUST NOT contain span text, speaker values, or any other clinical content.

#### Scenario: A warning is logged with the transcript id
- GIVEN a transcript whose spans are all blank
- WHEN it is indexed
- THEN one `Logger.warning` is captured containing that transcript's id and no span text or speaker value

### Requirement: Chunk rows carry speaker and audio time metadata (D1, D3, AC2)

The `clinical_record_rag_chunks` table and `Chunk` schema MUST add nullable `speaker :string`, `audio_start_seconds :float`, and `audio_end_seconds :float`. Non-transcript resource kinds MUST leave all three `nil`.

#### Scenario: A transcript chunk stores speaker and float seconds
- GIVEN a transcript chunk for a `"therapist"` turn from 12.5s to 48.75s
- WHEN the row is read back
- THEN `speaker = "therapist"`, `audio_start_seconds = 12.5`, `audio_end_seconds = 48.75`

#### Scenario: Other resource kinds leave the new columns nil
- GIVEN a chunk indexed from a `clinical_note` event
- WHEN the row is read back
- THEN `speaker`, `audio_start_seconds`, and `audio_end_seconds` are all `nil`

### Requirement: Chunks are encrypted under the clinical-record DEK and embedded (AC3, L5)

Each chunk's span text MUST be encrypted via `PatientVault.encrypt/2` under the resolved clinical-record DEK, stamped `encryption_version = 2`, and embedded via the configured embedding adapter, mirroring existing resource kinds.

#### Scenario: A transcript chunk is v2-encrypted and embedded
- GIVEN a non-blank span piece
- WHEN it is written as a chunk
- THEN `encryption_version = 2`, `encrypted_content` decrypts to the piece's text under the clinical-record DEK, and `embedding`/`embedding_model` are populated

### Requirement: No span text or speaker leaks in plaintext

No span text or speaker value MUST appear in any plaintext `Chunk` column other than the plaintext `speaker` column itself (D3's accepted deviation), and none MUST appear in `oban_jobs.args`.

#### Scenario: Only the speaker column carries plaintext speaker; no column carries span text
- GIVEN a persisted transcript chunk
- WHEN every plaintext column is inspected
- THEN `speaker` may hold `"patient"`/`"therapist"` but no column and no `oban_jobs.args` payload contains span text

### Requirement: Full chunk-set replacement is idempotent and drives deletion purge (L2, AC4)

`replace_chunks/2` MUST converge a transcript to the same chunk set on repeated indexing, and MUST leave zero chunks after `clinical_record_legally_deleted` tombstones the transcript.

#### Scenario: Re-indexing the same transcript converges
- GIVEN a transcript already indexed into N chunks
- WHEN the same `session_transcript_created` event is processed again with unchanged spans
- THEN the transcript still has exactly N chunks with the same content

#### Scenario: Legal deletion purges all chunks for the transcript
- GIVEN an indexed transcript with chunks
- WHEN the transcript is legally deleted
- THEN zero `clinical_record_rag_chunks` rows remain for it

### Requirement: Therapist turns are indexed (D5)

Chunking MUST NOT filter out `speaker: "therapist"` spans; both speakers are indexed identically.

#### Scenario: A therapist-only transcript still produces chunks
- GIVEN a transcript whose only non-blank spans are `"therapist"`
- WHEN it is indexed
- THEN chunks are written for those spans with `speaker = "therapist"`

## Out of Scope (Boundary Requirements)

### Requirement: No retrieval, citation, or web exposure in this change (D-B)

This change MUST NOT modify `Retrieval`, `Citation`, `Consultation.Source`, or any `lib/alethea_web/` file. Speaker/time formatting and mm:ss display are #328's responsibility.

#### Scenario: Diff excludes retrieval/citation/web paths
- GIVEN the full diff for this change
- WHEN changed files are listed
- THEN no `lib/alethea_web/` file, no `Retrieval`, `Citation`, or `Consultation.Source` change appears

### Requirement: Sentiment regression test is waived (D4)

This change MUST NOT require a sentiment-pipeline regression test: ingestion is embed-only and RoBERTa/the emotion pipeline are untouched.

#### Scenario: No RoBERTa/emotion-pipeline file changes
- GIVEN the full diff for this change
- WHEN changed files are listed
- THEN no RoBERTa or emotion-analysis module is modified

### Requirement: Inherited obligation — #328 MUST label speaker on every transcript citation (R-X3)

Not implemented in #320; binding on #328's spec. Any surface in #328 that displays a citation or excerpt sourced from a `session_transcript` chunk MUST show that chunk's speaker role alongside the excerpt, so therapist wording is never presented as patient evidence.

#### Scenario: (for #328) A transcript-sourced citation always shows its speaker
- GIVEN a citation whose source chunk has `speaker = "therapist"`
- WHEN it renders in #328's UI
- THEN the therapist role label is visible next to that citation
