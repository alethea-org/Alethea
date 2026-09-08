# Spec — clinical-record-retention

**Change:** clinical-record-retention (GitHub #197)
**Fixed by proposal (not re-decided here):** BR1–BR12, D1–D5, in/out-of-scope.
**Test runner:** `mix test` (strict TDD).

## New Capability: `clinical-record-retention`

### Purpose

Per-record retention aging, per-patient legal hold, per-record legal deletion with tombstones, terminal cryptographic erasure, post-deletion access behavior, RAG projection purge, and minimal non-clinical audit proof for `Alethea.ClinicalRecord`.

### Requirements

#### Requirement: Per-Record Retention Eligibility
Each row across the six `ClinicalRecord` tables MUST carry its own retention clock computed from its own last-clinical-action timestamp, independent of every other row for that patient. Eligibility is `own_last_action + max(global_baseline, patient.stricter_minimum) <= now`. No patient-wide `MAX` aggregate MAY be used.

##### Scenario: Independent clocks, no cross-restart
- GIVEN a `TargetBehavior` row 9 years old and a `ClinicianObservation` on it created today
- WHEN eligibility is evaluated for the `TargetBehavior`
- THEN it remains ineligible per its own clock; the new observation does not restart it and is evaluated only on its own clock

##### Scenario: Per-patient stricter minimum wins
- GIVEN a patient with a stricter-minimum override of 5 years and a record whose own last action was 6 years ago
- WHEN eligibility is evaluated
- THEN the record is eligible under the stricter override, ahead of the 10-year global baseline

#### Requirement: Per-Patient Legal Hold
A legal hold is a single per-patient flag. While active it MUST pause deletion (manual and automatic) for every one of that patient's records regardless of individual clock state. Lifting it MUST re-expose each record's own eligibility without altering any record's clock.

##### Scenario: Hold pauses all records
- GIVEN patient P has an active legal hold and two records past their own eligibility threshold
- WHEN a deletion trigger (manual or sweep) evaluates P's records
- THEN neither record is deleted and no state changes; the pause is audited

##### Scenario: Lifting hold re-exposes eligibility
- GIVEN patient P's hold is lifted
- WHEN the sweep or a manual deletion next evaluates P's records
- THEN each record's own already-computed eligibility applies immediately, with no clock reset

#### Requirement: Manual Legal Deletion
The treating professional (no admin role) MUST be able to legally delete a single targeted record or the patient's entire clinical record set at once, through the existing `ClinicalRecord` authorization ladder. Execution is immediate on explicit confirmation, with no cool-off window. Whole-patient deletion is a bounded iteration over the same per-record primitive, gated once by the patient's legal hold.

##### Scenario: Single-record deletion executes immediately
- GIVEN the treating professional confirms deletion of one record, patient not held
- WHEN the deletion is submitted
- THEN the record is legally deleted immediately with no grace window

##### Scenario: Whole-patient deletion iterates the per-record primitive
- GIVEN the treating professional confirms deletion of a patient's entire clinical record
- WHEN the deletion is submitted, patient not held
- THEN every one of that patient's records across the six tables is legally deleted through the same per-record mechanism, gated once by the hold check

##### Scenario: Held patient blocks manual deletion
- GIVEN patient P has an active legal hold
- WHEN the treating professional attempts single- or whole-patient deletion
- THEN no record is deleted and the attempt is audited as paused

#### Requirement: Automatic Retention Sweep
A periodic sweep MUST evaluate every record independently (never patient-wide) using the same eligibility, hold gate, and deletion mechanism as manual deletion.

##### Scenario: Eligible unheld record is swept
- GIVEN a record past its own eligibility threshold, patient not held
- WHEN the sweep runs
- THEN the record is legally deleted through the same mechanism as manual deletion

##### Scenario: Held patient's eligible record is skipped
- GIVEN a record past its own eligibility threshold but its patient is held
- WHEN the sweep runs
- THEN the record is left untouched

#### Requirement: Mixed State and Sibling Readability
Deletion MUST be evaluated and executed strictly per record. A patient MAY simultaneously have legally deleted and active records; deletion of one record MUST NOT affect any other record's readability.

##### Scenario: Sibling remains fully readable
- GIVEN patient P has one legally deleted record and one active record
- WHEN the treating professional reads the active record
- THEN it renders normally with full content, unaffected by the sibling's deletion

#### Requirement: Post-Deletion Read Behavior (Tombstone)
Reading a legally deleted record MUST return a content-free "legally deleted on {date}" tombstone rather than an error or silent disappearance.

##### Scenario: Deleted record renders a tombstone
- GIVEN a record was legally deleted on a known date
- WHEN the treating professional reads it
- THEN the response is the content-free tombstone bearing that date, with no original content present

#### Requirement: Post-Deletion Write Denial
Writing to a legally deleted record MUST be denied immediately and deterministically, distinct from a not-found error, and MUST be audited.

##### Scenario: Write to deleted record is denied and audited
- GIVEN a record was legally deleted
- WHEN the treating professional attempts to write to it
- THEN the write is denied immediately via the existing access-denial path, and a content-free audit row records the denial

#### Requirement: Terminal Cryptographic Erasure
A clinical-record-scoped encryption key MUST be destroyed if and only if the patient's remaining content across all six `ClinicalRecord` tables reaches zero. The key MUST NOT be destroyed while any record remains active, and MUST be recreated lazily on the next clinical write. The shared patient DEK used by `Alethea.Clinical` journaling MUST NOT be affected by this or any deletion.

##### Scenario: Zero remaining records triggers key destruction
- GIVEN a patient's last remaining clinical-record row is legally deleted
- WHEN that deletion transaction commits
- THEN the clinical-record-scoped encryption key is destroyed in the same transaction

##### Scenario: Active sibling prevents key destruction
- GIVEN a patient has one legally deleted record and one active record
- WHEN the deleted record's transaction commits
- THEN the clinical-record-scoped key is not destroyed

##### Scenario: Journaling DEK is never touched
- GIVEN a patient's clinical-record key is destroyed at zero-remaining
- WHEN `Alethea.Clinical` messages/summaries for that patient are subsequently read
- THEN they decrypt normally under the unaffected shared patient DEK

#### Requirement: RAG Projection Purge on Legal Deletion
Legal deletion of a record MUST purge all RAG chunks projected from it, without decrypting the deleted content. A citation resolving to erased material MUST degrade to an explicit unavailable state rather than raising.

##### Scenario: Chunks are purged on deletion
- GIVEN a record has existing RAG chunks
- WHEN the record is legally deleted
- THEN no chunk for that resource remains retrievable afterward

##### Scenario: Citation to erased material degrades gracefully
- GIVEN a `ConsultationEvidence` citation pointing at a now-legally-deleted source, or a surviving child record whose parent was legally deleted
- WHEN the citation is resolved
- THEN it reports an explicit unavailable status instead of raising, and the parent's own read renders its tombstone

#### Requirement: Minimal Audit-Proof Preservation
Every legal deletion MUST produce exactly one content-free `Audit` row attributable via the existing `resource_type`/`resource_id` fields (no schema change), and that row MUST survive the record's own erasure. Legal-hold apply and lift MUST each produce an audit row using new closed-vocabulary actions.

##### Scenario: Audit row survives its own record's erasure
- GIVEN a record is legally deleted and later its patient reaches zero-remaining key destruction
- WHEN the audit trail is queried afterward
- THEN the content-free audit row for that deletion still exists and resolves via `resource_type`/`resource_id`

##### Scenario: Hold apply and lift are audited
- GIVEN a legal hold is applied to a patient and later lifted
- WHEN the audit trail is queried
- THEN one audit row exists for the apply action and one for the lift action, each using the new closed-vocabulary action names

### Out of Scope (explicit non-goals — no requirements written for these)
Per-record legal-hold granularity; `Patient`/account row deletion or anonymization; `Alethea.Clinical` journaling content retention; ADR-003's RAG purge mechanism itself; a statutory citation for the ten-year figure; general encryption-key rotation/versioning beyond erasure; restore/undelete/export-before-delete.

## Modified Capability: `clinical-rag-projection`

Delta against `openspec/sdd/archive/2026-09-04-clinical-rag-projection/spec.md`.

### MODIFIED Requirements

#### Requirement: Explicit Non-Requirements
The following are OUT of scope for this change and MUST NOT be implemented here; scenarios confirm the boundary is a no-op, not a partial attempt.
(Previously: the "no deletion or tombstone handling" scenario deferred all delete/tombstone behavior to future #197; #197 now ships that behavior as a separate ADDED requirement below, so this scenario is narrowed to the dispatch-safety guarantee only.)

##### Scenario: Unrecognized future event types do not crash dispatch
- GIVEN the indexer's event dispatch encounters an event type it does not recognize
- WHEN that event is processed
- THEN it does not raise from an exhaustive match, regardless of whether the event is eventually handled by a future change

##### Scenario: No patient-voice or system-voice ingestion
- GIVEN `Alethea.Clinical` messages/summaries have no outbox producer
- WHEN this change ships
- THEN the indexer consumes only `ClinicalRecord` outbox events; no code path reads `Alethea.Clinical` content

##### Scenario: Embedding tested only against the behaviour, not the real adapter
- GIVEN the indexer depends on `Alethea.AI.Embeddings` (behaviour: `embed/2`, `model/0`, `dimensions/0`)
- WHEN this change's test suite runs
- THEN all indexer/retrieval tests inject `Alethea.AI.Embeddings.Fake`; no test exercises `Alethea.AI.Embeddings.Ollama` HTTP behavior

### ADDED Requirements

#### Requirement: Tombstone Event Classification and Purge
The indexer MUST classify a legal-deletion event for a resource as a distinct outcome — tombstone-purge — separate from index/ignore/never-index. Processing it MUST remove that resource's existing chunks without ever decrypting the deleted content, converging to zero chunks for that resource.

##### Scenario: Tombstone event purges existing chunks
- GIVEN a resource has existing chunks and is legally deleted
- WHEN the indexer processes the resulting tombstone event
- THEN all chunks for that resource are removed and none remain retrievable, with no decryption of the deleted content attempted

##### Scenario: Tombstone event on a resource with no chunks is a no-op
- GIVEN a resource was never indexed (e.g. `TargetBehavior`, ignore-with-reason)
- WHEN a tombstone event is processed for it
- THEN the job returns success with no error, and no chunk exists before or after

## Key Learnings

1. BR5/BR6's per-record clock and per-record execution model required an explicit "Mixed State and Sibling Readability" requirement to make the two independent axes (hold=per-patient, deletion=per-record) testable rather than implied.
2. D1's zero-remaining key destruction needed its own scenario proving the shared `Alethea.Clinical` patient DEK is untouched, since that boundary is the entire reason a second key type exists.
3. The clinical-rag-projection MODIFIED block had to narrow rather than delete the original "no deletion/tombstone handling" scenario, since dispatch-safety for unrecognized events remains valid even after #197 adds real tombstone handling.
4. Citation degradation (`:unavailable`) covers two distinct triggers — a directly-erased cited source and a surviving child whose parent was erased — both needed explicit scenario coverage per the proposal's risk table.
