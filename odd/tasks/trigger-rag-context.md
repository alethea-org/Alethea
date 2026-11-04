# Feature: Index triggers into the clinical record RAG as never-evidence (#452)

Parent PRD #435 (user stories 26–27). Blocked-by issues #440/#448 are closed.
Same never-evidence rule as functional analysis drafts (commit 1a8f83c).

## Specs

S1. "Index trigger configuration and firings into the clinical-record RAG as
    therapist context, explicitly marked as never-evidence, using the same rule
    as functional analysis drafts."
S2. "Consultations can retrieve trigger configuration and firings as context."
S3. "They never appear as evidence or evidence suggestions."
S4. (US26) "I want trigger configuration and firings to be available to the
    clinical-record assistant as therapist context, so that consultations know
    what I asked the bot to do."
S5. (US27) "I want trigger configuration and firings never to be treated as
    patient evidence, so that clinical hypotheses are not built on my own
    instructions."

## Design decisions

- Trigger configuration indexes as `resource_type = "trigger"`: kind, status,
  schedule/cooldown shape, decrypted condition, instruction and approved text.
- Firings index as `resource_type = "trigger_firing"`: status, fired/scheduled
  timestamps, and the trigger's instruction as anchor text (firings carry no
  encrypted content of their own).
- Both types join `Retrieval.@never_evidence` (drafts rule) so evidence search
  and suggestions can never return them, at SQL level.
- Consultations gain a separate context retrieval: `Retrieval.context/3`
  queries ONLY never-evidence types and returns flagged results;
  `Consultation.Live` passes them to the chain as `context` excerpts, and they
  never become `Source`s, never pass the evidence threshold, and never feed
  hypotheses.
- Outbox path: new events `trigger_saved` / `trigger_firing_created` flow
  through the existing `ClinicalRecord.Outbox` → `ClinicalRecordOutboxWorker`
  → `Rag.Indexer` pipeline (idempotent `replace_chunks/2`).

## Tasks

- [ ] T1 (S1): Outbox clauses + `Indexer.eligibility/1` + `fetch_and_decrypt`
      for `:trigger` / `:trigger_firing`. RED tests first.
      `lib/alethea/clinical_record/outbox.ex`,
      `lib/alethea/clinical_record/rag/indexer.ex`,
      `test/alethea/clinical_record/rag/indexer_test.exs` — commit: 1845968
- [x] T2 (S1): Enqueue outbox events on trigger create/edit/approve/pause/
      resume and on firing creation. `lib/alethea/triggers.ex`,
      `lib/alethea_jobs/active_trigger_worker.ex`,
      `test/alethea/triggers/rag_outbox_test.exs` — commit: e1a92db (slice 1 closed at T2)
- [x] T3 (S2,S3): `@never_evidence` gains both types; new
      `Retrieval.context/3` restricted to never-evidence types.
      `lib/alethea/clinical_record/rag/retrieval.ex`,
      `test/alethea/clinical_record/rag/retrieval_test.exs` — commit: PENDING
- [x] T4 (S2,S3,S5): `Consultation.Live` fetches context, feeds chain as
      `context`, excludes from Sources/hypothesis/threshold.
      `lib/alethea/clinical_record/rag/consultation/live.ex`,
      `lib/alethea/ai/chains/clinical_consultation_chain.ex` — commit: PENDING
- [ ] T5 (S1): Reindex task re-enqueues triggers/firings.
      `lib/mix/tasks/alethea.rag.reindex.ex` — commit:
- [ ] T6: `mix precommit`, docs, close feature — commit:

## Log

- L1 (verbatim request): "hagamos la issue [Feature]: Index triggers into the
  clinical record RAG as never-evidence #452"
- L2: Blockers #440/#448 verified closed. Branch
  `feat/452-trigger-rag-context`.
- L3: Delivery status transitions (fired -> delivered/not_delivered via
  `update_all`) do NOT re-enqueue; the indexed firing keeps the creation-time
  status. Accepted scope cut, noted for review.
