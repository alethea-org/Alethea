# Delta Spec — telegram-rag-ingestion-262

**Change:** telegram-rag-ingestion-262 | **Source:** proposal.md (DECIDED, Q1-Q6 locked)
**Convention:** no `openspec/specs/` source tree exists; this file is the full delta for both capabilities.

## New Capability: `patient-message-rag-ingestion`

### Requirement: Journaling outbox builder (Slice 1)
`Alethea.Clinical.Outbox.event/3` MUST build an Oban insert changeset from `(event_type, message, professional_id)`, allowlisting args to exactly `event, resource_type, resource_id, patient_id, professional_id` (same closed shape as `ClinicalRecord.Outbox.event/2`), and MUST enqueue on the existing `AletheaJobs.ClinicalRecordOutboxWorker`.

#### Scenario: Builds a well-formed event changeset
- GIVEN a persisted `Alethea.Clinical.Message` and a `professional_id`
- WHEN `Outbox.event("patient_message_received", message, professional_id)` is called
- THEN the changeset's args contain only the 5 allowlisted keys, with `resource_type: "patient_message"` and `resource_id: message.id`

### Requirement: Indexer ingestion of patient messages (Slice 1)
`Indexer.eligibility/1` MUST classify `"patient_message_received"` as `{:index, :patient_message}`. `Indexer.fetch_and_decrypt(:patient_message, ...)` MUST load the `Message`, decrypt `encrypted_content` via `resolve_dek/4` and `PatientVault`, and return the message text with `source_occurred_at` derived from `message.timestamp` (widened to usec) and `target_behavior_id: nil`.

#### Scenario: Indexes an eligible patient message
- GIVEN an outbox job with `event: "patient_message_received"` for an existing `Message`
- WHEN `Indexer.index_event/1` runs
- THEN a chunk is inserted with `source_resource_type: "patient_message"`, `source_resource_id` equal to the message id, and `source_occurred_at` equal to the message's timestamp

#### Scenario: Missing source message
- GIVEN an outbox job referencing a `Message` id that no longer exists
- WHEN `Indexer.index_event/1` runs
- THEN it returns `{:cancel, :not_found}` and produces no chunk

### Requirement: Patient-DEK encryption at rest (Slice 1)
Every chunk produced from a `patient_message` source MUST be encrypted under the owning patient's DEK, resolved via the same `resolve_dek/4` ladder used for other resource kinds.

#### Scenario: Chunk ciphertext is opaque
- GIVEN a patient message has been indexed
- WHEN the resulting `clinical_record_rag_chunks` row is read directly via SQL
- THEN `encrypted_content` is binary ciphertext, never plaintext, and decrypts only with the patient's DEK

### Requirement: Idempotent operator reindex coverage (Slice 1)
`mix alethea.rag.reindex --patient-id <uuid> --confirm` MUST include inbound patient messages in `@resource_kinds`, fetch only `direction == "inbound"` messages, and route enqueue through `Clinical.Outbox.event/3`. Repeated runs MUST converge to the same chunk set.

#### Scenario: Reindex includes and converges patient messages
- GIVEN a patient with inbound and outbound messages
- WHEN the reindex task runs twice with `--confirm`
- THEN only inbound messages are enqueued and indexed, and the second run produces the identical chunk set (no duplicates)

### Requirement: Patient-voice citation label (Slice 1)
`ConsultationLive.source_kind_label("patient_message")` MUST return `"Mensaje del paciente"`, rendered with the source's `occurred_at` via the existing `format_datetime/1`.

#### Scenario: Label renders with timestamp
- GIVEN a consultation answer citing a `patient_message` source
- WHEN the sources panel renders
- THEN it shows "Mensaje del paciente" alongside the formatted date/time of that source

### Requirement: Transactional, inbound-gated event emission (Slice 2)
`Clinical.save_message/7` MUST use `Ecto.Multi` so the `Message` insert and the `patient_message_received` outbox job commit atomically; the outbox step MUST run only when `direction == "inbound"`. The external contract `{:ok, Message.t()} | {:error, term()}` MUST be preserved.

#### Scenario: Inbound message commits both rows atomically
- GIVEN a Telegram inbound update
- WHEN `save_telegram_message/6` persists it with `direction: "inbound"`
- THEN the `Message` row and its `patient_message_received` outbox job exist together, or neither exists if either insert fails

#### Scenario: Outbound message never emits
- GIVEN an AI-authored outbound reply saved via `save_telegram_message/6` with `direction: "outbound"` (both call sites: safe-path reply, crisis-bypass reply)
- WHEN the save commits
- THEN no `patient_message_received` outbox job is created and no chunk is ever produced for that message

#### Scenario: Duplicate telegram_message_id preserved
- GIVEN a `Message` already persisted with a given `telegram_message_id`
- WHEN `save_message/7` is called again with the same `telegram_message_id`
- THEN it returns `{:error, changeset}` carrying the `telegram_message_id` unique-constraint error, in the same shape the worker relied on before the `Multi` conversion

### Requirement: End-to-end patient-voice citation
`Consultation.answer/4` MUST be able to retrieve and cite an indexed patient message when it is semantically relevant, with no change to `Retrieval` or `Consultation.Source` code (they are already generic over `source_resource_type`).

#### Scenario: Clinical query cites a patient message
- GIVEN an indexed inbound message whose content is semantically relevant to a professional's query
- WHEN `Consultation.answer/4` is invoked with that query
- THEN the returned `Answer.sources` includes an entry with `kind: "patient_message"` and an excerpt drawn from that message

## Modified Capability: `clinical-rag-projection`

### MODIFIED Requirements

### Requirement: Ingest-eligibility table
The eligibility table classifies each outbox `event` string into `{:index, kind}`, `{:tombstone, reason}`, `{:ignore, reason}`, or `{:unknown, event}`. It now also maps `"patient_message_received"` → `{:index, :patient_message}`, alongside the existing `clinical_note_created`, `consultation_evidence_created`, `clinician_observation_created`/`updated`, `ai_proposal_accepted`, and `functional_analysis_draft_saved` clauses.
(Previously: covered only the six `ClinicalRecord` event types; no patient-authored source existed.)

#### Scenario: Unknown event still falls through safely
- GIVEN an outbox job with an unrecognized `event` string
- WHEN `eligibility/1` is called
- THEN it returns `{:unknown, event}` and `index_event/1` acknowledges with `:ok`, producing no chunk

## Acceptance-criteria traceability

| AC | Covered by |
|---|---|
| Inbound → outbox → indexed as `patient_message` | Journaling outbox builder; Indexer ingestion |
| Chunks DEK-encrypted | Patient-DEK encryption at rest |
| `Consultation.answer/4` cites patient messages | End-to-end patient-voice citation |
| Label "Mensaje del paciente" + date/time | Patient-voice citation label |
| Reindex includes + converges idempotently | Idempotent operator reindex coverage |
| Negative: outbound never emits/indexes | Outbound message never emits |
| Message row + outbox job atomic | Transactional, inbound-gated event emission |
| Tests in IndexerTest/RetrievalTest/ConsultationLiveTest | All scenarios above are test-derivable per requirement |
| `mix precommit` passes | Non-functional gate, no dedicated scenario (verify phase) |
