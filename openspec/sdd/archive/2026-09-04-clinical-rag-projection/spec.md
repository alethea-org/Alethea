# Clinical RAG Projection Specification

**Change:** clinical-rag-projection (GitHub #196) — capability status: New.
**Fixed by proposal (not re-decided here):** D1–D9, in/out-of-scope, and the 4 confirmed product decisions in the proposal's closed question round.

## Purpose

Define testable behavior for the non-authoritative, patient-scoped semantic projection of `Alethea.ClinicalRecord`: which outbox events become chunks, how chunks are produced/replaced, and the retrieval contract clinicians see. This spec constrains WHAT the system does; chunking parameters, index types, and route names are `sdd-design` concerns.

## Requirements

### Requirement: Ingest Eligibility by Event Type
The indexer MUST classify every dispatched outbox event as exactly one of: index, ignore-with-reason (recognized, not chunked), or never-index (no code path admits it).

| Event | Resource | Outcome |
|---|---|---|
| `clinical_note_created` | ClinicalNote | Index |
| `consultation_evidence_created` | ConsultationEvidence | Index |
| `clinician_observation_created` | ClinicianObservation | Index |
| `clinician_observation_updated` | ClinicianObservation | Index (replace prior chunks for the same resource) |
| `ai_proposal_accepted` | AIProposal | Index |
| `ai_proposal_edited` | AIProposal | Never index (not yet accepted) |
| `ai_proposal_discarded` | AIProposal | Never index |
| `functional_analysis_draft_saved` | FunctionalAnalysisDraft | Index (replace prior chunks for the same resource) |
| `target_behavior_created` | TargetBehavior | Ignore-with-reason: structural metadata, filter facet only |

#### Scenario: Eligible event produces retrievable chunks
- GIVEN a `clinical_note_created` outbox job for patient P
- WHEN `RAG.Indexer.perform/1` runs
- THEN one or more chunks exist for that resource AND `RAG.Retrieval.search(P, ...)` can return them

#### Scenario: Recognized-but-ignored event produces no chunk
- GIVEN a `target_behavior_created` outbox job
- WHEN the indexer processes it
- THEN the job returns `:ok`, no chunk row is created, AND no `FunctionClauseError`/unmatched-case error occurs

#### Scenario: Pending AIProposal is never indexed
- GIVEN an `AIProposal` with `status: "pending"` (no `ai_proposal_created` outbox event exists)
- WHEN the outbox is inspected
- THEN no job for that resource was ever enqueued AND no chunk for it exists

#### Scenario: Discarded AIProposal is never indexed
- GIVEN an `ai_proposal_discarded` outbox job
- WHEN the indexer processes it
- THEN no chunk is created, AND if prior chunks existed for that resource (there should be none per D5) they are not created retroactively

#### Scenario: Edited-but-unaccepted AIProposal is never indexed
- GIVEN an `ai_proposal_edited` outbox job for a proposal still `status: "edited"` (not accepted)
- WHEN the indexer processes it
- THEN no chunk is created for that resource

### Requirement: Chunking Behavior
The chunker MUST treat one eligible event as one complete semanticable unit, sub-splitting only when its free text exceeds ~500 tokens, on sentence/paragraph boundaries, with ~15% overlap between adjacent sub-chunks. Every chunk MUST persist: source resource type, source resource id, chunk index, full-event-vs-subchunk flag, token count, embedding model identifier.

#### Scenario: Short event yields a single chunk
- GIVEN an eligible event whose free text is under ~500 tokens
- WHEN chunked
- THEN exactly one chunk row is produced with `chunk_index: 0` and the full-event flag set

#### Scenario: Long event sub-splits with overlap
- GIVEN an eligible event whose free text exceeds ~500 tokens
- WHEN chunked
- THEN 2+ chunks are produced, split at sentence/paragraph boundaries, each carrying the same source resource id with distinct `chunk_index`, and adjacent chunks share ~15% overlapping text

### Requirement: Idempotent Retry and Replace Semantics
Re-processing the same source resource (job retry, or a re-save of a mutable resource) MUST converge to exactly one chunk set for that resource: no duplicates, no orphaned stale chunks.

#### Scenario: Job retry does not duplicate chunks
- GIVEN a chunk set already exists for resource R
- WHEN the same outbox job for R is retried (e.g. after a transient embedding failure)
- THEN exactly the same chunk set exists afterward, with no duplicate rows

#### Scenario: Re-saving a mutable resource replaces its chunks
- GIVEN a `ClinicianObservation` or `FunctionalAnalysisDraft` with existing chunks
- WHEN a `clinician_observation_updated` or `functional_analysis_draft_saved` event is processed for the same resource id with changed text
- THEN old chunks for that resource are deleted and new chunks reflecting the new text exist, in one transaction, with no window where both or neither exist

### Requirement: Patient Isolation
Retrieval MUST NOT return chunks belonging to a different patient, including under adversarial query construction.

#### Scenario: Cross-patient query never leaks
- GIVEN chunks exist for patient A and patient B
- WHEN `RAG.Retrieval.search(patient_id: A, query: q)` runs, where `q` is crafted from known content of patient B's chunks
- THEN the result set contains only chunks whose source resource belongs to patient A

### Requirement: Citation and Non-Authoritative Labeling
Every retrieval result MUST carry an exact citation to its authoritative source row and a persistent non-authoritative indicator, not a one-time banner.

#### Scenario: Result carries citation and persistent badge
- GIVEN a retrieval result rendered in the retrieval view
- WHEN the clinician views it
- THEN the result displays the non-authoritative badge attached to that specific result AND a citation resolving to the exact source resource type/id/row, AND the badge remains visible on subsequent scroll/interaction (not dismissed after first render)

### Requirement: Freshness Disclosure
When eligible material exists that has not yet completed indexing (job pending or in-flight), retrieval MUST disclose this rather than presenting the result set as complete.

#### Scenario: Pending indexing job is disclosed
- GIVEN a clinician write just occurred and its outbox job has not yet completed
- WHEN the clinician queries the retrieval view for that patient
- THEN the view indicates that indexing is still catching up, distinct from a normal result set or an empty state

### Requirement: Empty States
The retrieval view MUST distinguish "nothing indexed yet for this patient" from "indexed, but no match for this query."

#### Scenario: No chunks exist yet
- GIVEN patient P has zero chunks (no eligible event has completed indexing)
- WHEN any query is submitted
- THEN the view shows the "nothing indexed yet" state, not a generic no-results state

#### Scenario: Chunks exist but none match
- GIVEN patient P has 1+ chunks
- WHEN a query matches none of them
- THEN the view shows the "no match for this query" state, distinct from the "nothing indexed yet" state

### Requirement: Contradictory Evidence Retention
`ClinicalRecord` has no conflict-detection or conflict-resolution mechanism today (no merge, supersede, or dedup logic across resources); `AIProposal` itself is explicitly barred from resolving conflicts. The projection MUST NOT invent behavior ClinicalRecord doesn't perform: it MUST NOT merge, deduplicate, or suppress chunks on the basis of semantic similarity or contradiction between distinct source resources.

#### Scenario: Contradictory accepted evidence both surface
- GIVEN two `ConsultationEvidence` rows for the same patient with mutually contradictory content, both indexed
- WHEN a query matches both
- THEN both appear in the result set, each with its own citation and badge, with no automatic preference, merge, or resolution applied

### Requirement: Access Control
Only the treating professional authorized on the existing `ClinicalRecord` surfaces MAY query a given patient's projection.

#### Scenario: Non-treating professional is denied
- GIVEN professional X is not the treating professional for patient P
- WHEN X attempts to open the retrieval view or call `RAG.Retrieval.search/3` for P
- THEN access is denied using the same authorization check as existing patient-scoped `ClinicalRecord` surfaces

### Requirement: Failure Isolation
Indexing/projection failures and in-progress rebuilds MUST NOT make `ClinicalRecord` writes or reads unavailable.

#### Scenario: Indexing failure does not block the write path
- GIVEN the embedding adapter raises or times out for a given event
- WHEN a clinician performs the originating `ClinicalRecord` write
- THEN the write commits successfully and is fully queryable through `ClinicalRecord`, independent of indexing outcome

#### Scenario: Rebuild in progress does not block writes
- GIVEN an on-demand rebuild is currently running
- WHEN a clinician performs a new `ClinicalRecord` write
- THEN the write succeeds without waiting for or being blocked by the rebuild

### Requirement: On-Demand Rebuild
A manually triggered full rebuild MUST reprocess all currently eligible material and converge to the same idempotent chunk state as incremental ingest; it MUST NOT run on any schedule.

#### Scenario: Rebuild converges to idempotent state
- GIVEN a patient's existing chunk set produced by incremental ingest
- WHEN an on-demand rebuild is triggered for that patient
- THEN the resulting chunk set is equivalent (same resources, no duplicates, no orphans) to the pre-rebuild set, modulo any resource changed since

#### Scenario: No scheduled execution exists
- GIVEN the application is running under normal operation
- WHEN no operator manually triggers a rebuild
- THEN no rebuild job is ever scheduled or fired automatically (no cron/periodic trigger exists in the codebase)

### Requirement: Explicit Non-Requirements
The following are OUT of scope for this change and MUST NOT be implemented here; scenarios confirm the boundary is a no-op, not a partial attempt.

#### Scenario: No deletion or tombstone handling
- GIVEN no delete/tombstone outbox event exists in `ClinicalRecord` (owned by future #197)
- WHEN the indexer's event dispatch encounters an unrecognized future event type
- THEN it does not raise from an exhaustive match and does not implement any tombstone/delete logic

#### Scenario: No patient-voice or system-voice ingestion
- GIVEN `Alethea.Clinical` messages/summaries have no outbox producer
- WHEN this change ships
- THEN the indexer consumes only `ClinicalRecord` outbox events; no code path reads `Alethea.Clinical` content

#### Scenario: Embedding tested only against the behaviour, not the real adapter
- GIVEN the indexer depends on `Alethea.AI.Embeddings` (behaviour: `embed/2`, `model/0`, `dimensions/0`)
- WHEN this change's test suite runs
- THEN all indexer/retrieval tests inject `Alethea.AI.Embeddings.Fake`; no test exercises `Alethea.AI.Embeddings.Ollama` HTTP behavior
