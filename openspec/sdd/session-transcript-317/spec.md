# Spec: SessionTranscript schema and persistence with speaker attribution (#317)

## Domain: `session-transcript-persistence` (New Capability)

## Purpose

What must be true once speaker-attributed, timestamped session transcripts are persisted: the `session_transcripts` table shape (L1, L6, D1, D3), encrypted span round-trip under the clinical-record DEK (L2, L4), in-serializer speaker validation (L3), context-layer authorization, the no-plaintext-leak invariant, the single identifier-only outbox event #320 consumes (L5), and `Retention.@tables` registration (D2).

## Requirements

### Requirement: `session_transcripts` table shape

The migration MUST create `session_transcripts` with a `binary_id` primary key, `encrypted_spans :binary` (non-null), `encryption_version :integer` (non-null), `audio_duration_seconds` as a plaintext integer column (D1), `recorded_at` non-null (D3), a `patient_id` FK `on_delete: :delete_all`, a `professional_id` FK `on_delete: :restrict` (L6), and `timestamps(type: :utc_datetime)`. It MUST index `[:patient_id]` and `[:patient_id, :recorded_at]`.

#### Scenario: Row is scoped to both patient and professional
- GIVEN the migration is applied
- WHEN a transcript row is inserted
- THEN both `patient_id` and `professional_id` are required and non-null

#### Scenario: `recorded_at` is required
- GIVEN a create attempt without `recorded_at`
- WHEN the changeset is validated
- THEN it is invalid and no row is inserted

#### Scenario: FK cascade rules follow L6
- GIVEN a patient with transcripts and its authoring professional
- WHEN the patient row is deleted THEN its transcript rows are deleted
- AND WHEN the professional row is deleted THEN deletion is restricted

### Requirement: Encrypted speech spans round-trip in order

`SessionTranscriptContent` MUST serialize spans to a sentinel-prefixed, versioned, positional JSON array of `[start, end, speaker, text]` (L4), encrypted once into `encrypted_spans` (L2). Create → fetch MUST return every span with `start`, `end`, `speaker`, and `text` intact and in the original order.

#### Scenario: N mixed-speaker spans survive create → fetch
- GIVEN a transcript created with N spans mixing `patient` and `therapist`
- WHEN it is fetched by its id by the owning professional
- THEN exactly N spans return in the original order with identical `start`, `end`, `speaker`, `text`

#### Scenario: Blob is unreadable without the clinical-record DEK
- GIVEN a persisted transcript row
- WHEN `encrypted_spans` is read without the clinical-record DEK
- THEN no span text or speaker value is recoverable from it

### Requirement: Speaker values are validated at write time

Speaker MUST be validated in `SessionTranscriptContent` against `~w(patient therapist)` (L3); a DB CHECK cannot reach inside ciphertext. Both values MUST be accepted; any other value MUST be rejected before encryption.

#### Scenario: Both valid speakers are accepted
- GIVEN spans whose speakers are `patient` and `therapist`
- WHEN the transcript is created
- THEN creation succeeds

#### Scenario: An invalid speaker is rejected at write
- GIVEN a span with any speaker outside `~w(patient therapist)`
- WHEN creation is attempted
- THEN it returns an error, no row is inserted, and no outbox event is enqueued

### Requirement: Authorization is enforced in the context

`create_session_transcript/3` and `get_session_transcript/3` MUST route through `with_patient/3` (auth → KEK → patient DEK → clinical-record DEK). On failure they MUST call `deny_access/2`, returning `{:error, :unauthorized}` and writing a content-free audit row (D4 — create and get only; no list function).

#### Scenario: Cross-professional fetch is denied
- GIVEN a transcript owned by professional A's patient
- WHEN professional B fetches it by id
- THEN `{:error, :unauthorized}` is returned, one denial audit row exists, and no span data is returned

#### Scenario: Cross-professional create is denied
- GIVEN professional B and a patient belonging to professional A
- WHEN B attempts creation
- THEN `{:error, :unauthorized}`, a content-free audit row, and no inserted row

#### Scenario: A malformed patient id is never echoed
- GIVEN a non-UUID patient id
- WHEN create or get is attempted
- THEN `{:error, :unauthorized}` and the audit row contains no caller-supplied content

### Requirement: No plaintext leak of span text or speaker

Span `text` and `speaker` MUST NOT appear in any plaintext column and MUST NOT appear in `oban_jobs.args`. The virtual plaintext field MUST NOT be castable and MUST be redacted from inspection.

#### Scenario: Plaintext columns carry no span content
- GIVEN a persisted transcript
- WHEN every non-`encrypted_spans` column is read
- THEN none contains any span text or speaker value

#### Scenario: Oban args are identifier-only
- GIVEN the outbox event enqueued on creation
- WHEN `oban_jobs.args` is read
- THEN it contains only identifiers, never span text or speaker

### Requirement: Creation emits exactly one outbox event

Creation MUST enqueue exactly one outbox event carrying only an identifier (L5) — the seam #320 consumes — inside the same transaction as the record insert and the audit row. `Outbox.resource_type/1` and the `Audit` `@actions`/`@resource_types` vocabularies MUST recognize the new resource type.

#### Scenario: One identifier-only event per creation
- GIVEN a successful transcript creation
- WHEN enqueued outbox events are inspected
- THEN exactly one event exists for this transcript and its payload resolves the row by identifier alone

#### Scenario: A failed creation emits no event
- GIVEN a creation that fails validation or authorization
- WHEN the outbox is inspected
- THEN no event was enqueued and no audit `created` row exists

### Requirement: `session_transcripts` is registered for retention (D2)

`session_transcripts` MUST appear in `Retention.@tables`, and its resource-type literal MUST be present in the `Audit`/`Tombstone` vocabularies. The terminal clinical-record-DEK crypto-erasure MUST NOT fire while transcript rows remain for that patient.

#### Scenario: A surviving transcript blocks terminal crypto-erasure
- GIVEN a patient whose only remaining clinical-record row is a transcript
- WHEN every other registered record is legally deleted
- THEN the `patient_clinical_record` key still exists and no `clinical_record_key_destroyed` audit row was written

#### Scenario: Deleting the last transcript completes erasure
- GIVEN that transcript is then legally deleted
- WHEN the sweep completes
- THEN the `patient_clinical_record` key is destroyed exactly once and the shared patient DEK is untouched

### Requirement: Encryption version 2 and DEK resolution

New rows MUST stamp `encryption_version` = 2, and `dek_for/2` MUST resolve the clinical-record DEK from the row's own `encryption_version`.

#### Scenario: New rows stamp version 2
- GIVEN a newly created transcript
- WHEN its `encryption_version` is read
- THEN it equals 2

#### Scenario: Decryption uses the row's own version
- GIVEN a version-2 transcript row
- WHEN it is fetched
- THEN `dek_for/2` selects the clinical-record DEK, not the shared patient DEK

## Out of Scope (Boundary Requirements)

### Requirement: No producer, no RAG indexing, no web change

This change MUST NOT add audio capture/upload/storage, a Groq adapter, diarization, RAG chunking (#320), the draft button (#319), citation UI (#328), any `lib/alethea_web/` file, or a `list_session_transcripts/2` function (D4).

#### Scenario: Diff excludes all out-of-scope paths
- GIVEN the full diff for this change
- WHEN changed/added files and new public functions are listed
- THEN no `lib/alethea_web/` file, no Whisper adapter, no RAG indexer clause, and no list function appear
