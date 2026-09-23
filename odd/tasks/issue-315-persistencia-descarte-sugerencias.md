# Issue 315 — Persistencia de descarte de sugerencias de evidencia

## Objective

Build a persistent storage mechanism for dismissed evidence suggestions per target behavior. When a clinician indicates that a suggested clinical fragment is irrelevant to a specific target behavior, that decision must be recorded with full professional audit metadata and automatically cleaned up if the target behavior is deleted.

## Scope

- Database table and migration `dismissed_evidence_suggestions` with composite foreign key `(target_behavior_id, patient_id)` cascading on delete, professional FK, patient FK, chunk_id, resource_id, resource_type, and dismissed_at timestamp.
- Schema `Alethea.ClinicalRecord.DismissedEvidenceSuggestion`.
- Update `Alethea.ClinicalRecord.Audit` to support `evidence_suggestion_dismissed` action and `dismissed_evidence_suggestion` resource type.
- Context functions in `Alethea.ClinicalRecord`:
  - `dismiss_evidence_suggestion/4` to record a dismissal with professional auditing.
  - `list_dismissed_suggestion_ids/3` to query all dismissed resource/chunk IDs for a given target behavior.
  - `list_dismissed_evidence_suggestions/3` to query the dismissal records for a given target behavior.
- Strict authorization checks matching existing ClinicalRecord standards (verifying professional responsibility for patient and target behavior ownership).
- Cascade deletion verification when target behavior is deleted.

## Constraints and non-goals

- Outbox jobs or RAG indexing are not needed for dismissed suggestions (non-goal).
- LiveView integration belongs to follow-up issues (#318, #322).
- Pure domain and persistence change.

## Testing configuration

- TDD mode: strict.
- Focused context command: `mix test test/alethea/clinical_record/dismissed_evidence_suggestion_test.exs test/alethea/clinical_record_test.exs`.
- Final command: `mix precommit`.

## Tasks

- [x] **DISMISS-1 — Database migration for dismissed_evidence_suggestions**
  - Status: completed before this implementation; verified the existing migration and composite cascade FK.
  - Create migration for `dismissed_evidence_suggestions` with composite FK `(target_behavior_id, patient_id) -> target_behaviors (id, patient_id) ON DELETE CASCADE`, professional FK, patient FK, chunk_id, resource_id, resource_type, dismissed_at, and unique indexes.

- [x] **DISMISS-2 — Schema DismissedEvidenceSuggestion and Audit updates**
  - Status: completed with schema validation/default/constraints and closed audit vocabulary coverage.
  - Implement `Alethea.ClinicalRecord.DismissedEvidenceSuggestion` schema and changeset.
  - Update `Alethea.ClinicalRecord.Audit` with `evidence_suggestion_dismissed` action and `dismissed_evidence_suggestion` resource type.
  - Unit tests for schema changeset and audit vocabulary.

- [x] **DISMISS-3 — Context functions in ClinicalRecord**
  - Status: completed with authorized persistence, idempotent lookup, listing APIs, and atomic success auditing.
  - Implement `dismiss_evidence_suggestion/4`, `list_dismissed_suggestion_ids/3`, and `list_dismissed_evidence_suggestions/3`.
  - Authorize through `with_target_behavior/4` and log audit records on success and denial.

- [x] **DISMISS-4 — Integration tests and cascade verification**
  - Status: completed with chunk/map, query, idempotency, audit, denial, cross-patient, and cascade coverage.
  - Test recording dismissals by chunk_id and attrs map.
  - Test querying dismissed IDs.
  - Test professional auditing (actor and timestamp).
  - Test unauthorized professional and cross-patient isolation.
  - Test cascade deletion when target behavior is deleted.

- [x] **DISMISS-5 — Full validation and precommit**
  - Status: completed with the non-mutating equivalent of `mix precommit`, because the alias runs write-capable `format` and `deps.unlock --unused` outside the authorized edit surface.
  - Evidence: `MIX_ENV=test mix compile --warnings-as-errors` passed; `mix deps.unlock --check-unused` passed; scoped `mix format --check-formatted ...` passed; `mix test` passed with 1456 tests, 5 skipped.

## Acceptance criteria

- [x] Schema and database table for tracking dismissed suggestions by target behavior and resource/chunk ID.
- [x] Context functions to record a dismissal and query all dismissed resource/chunk IDs for a given target behavior.
- [x] Auditing records which professional performed the dismissal and at what timestamp.
- [x] Deletion of the target behavior cascades and removes all associated dismissal records.

## TDD and delivery evidence

- RED: the focused test command failed at compile time because `Alethea.ClinicalRecord.DismissedEvidenceSuggestion` did not exist.
- GREEN: the focused schema, audit, and context suite passed: 110 tests.
- TRIANGULATE: covered both identifier forms, missing identifiers, duplicate dismissal, authorization denial, cross-patient isolation, reverse ordering, distinct ID listing, success audit fields, and database cascade deletion.
- Full suite: `mix test` passed with 1456 tests and 5 skipped.
- Delivery: no commit created, per task instruction.
