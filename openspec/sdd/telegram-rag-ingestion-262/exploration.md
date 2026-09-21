# Exploration — telegram-rag-ingestion-262 (#262)

**Status:** exploration complete
**Date:** 2026-09-17
**Issue:** #262 — Ingestar mensajes de Telegram en el RAG (Voz del Paciente - ADR-003)
**Standalone:** no parent, no blockers
**Authority:** ADR-003 (RAG historia clínica navegable — tres voces), `openspec/UBIQUITOUS_LANGUAGE.md`

## Executive summary

The Indexer's extension seam (`eligibility/1` + `fetch_and_decrypt/1`) can absorb `patient_message` with zero restructuring exactly as ADR-003 promises, but `Alethea.ClinicalRecord.Outbox` cannot be reused unmodified for `Alethea.Clinical.Message` (no `professional_id` field, closed struct dispatch) — recommend a new, small `Alethea.Clinical.Outbox` module owned by the `Alethea.Clinical` bounded context that reuses the same Oban worker, and converting `save_message/7`'s bare `Repo.insert` into the project's established `Ecto.Multi` outbox pattern for the inbound-only branch.

## Current state (file:line)

RAG projection (#196) indexes only `Alethea.ClinicalRecord` events. `Alethea.Clinical.Message` (Telegram) never emits an outbox event.

Files read in full, with **corrected facts vs. the issue text**:

- `lib/alethea/clinical_record/rag/indexer.ex` — `eligibility/1` L71-82, `fetch_and_decrypt/5` L415-484 (one private clause per resource kind: `Repo.get` → `resolve_dek/4` → `PatientVault.decrypt` → `{:ok, text, occurred_at, target_behavior_id, encryption_version, dek}`), `replace_chunks/2` L245-267, `embed_chunks/1` L214-226 (dispatches via `AI.embeddings()` — already adapter-agnostic).
- `lib/alethea/clinical_record/outbox.ex` — `event/2` L37-47 is closed over 6 `ClinicalRecord` structs via `resource_type/1` L49-54, all built straight from struct fields. `Message` matches no clause and has no `professional_id`.
- `lib/alethea_jobs/clinical_record_outbox_worker.ex` — content-agnostic consumer; only cares about the 5-key args shape, not which context built it. Good reuse seam.
- `lib/alethea/clinical/message.ex` — no `professional_id` field.
- `lib/alethea/jobs/telegram_message_worker.ex` — confirmed module name. `save_telegram_message/6` called at L142 (inbound, the ONLY inbound call site), L285 and L695 (both outbound, both already inside `Repo.transaction`).
- `lib/alethea/clinical.ex` — actual functions are **`save_message/7`** and **`save_telegram_message/6`** (the issue said `/8`, wrong). Both do a bare `Repo.insert()` — no transaction.
- `lib/alethea/ai/embeddings.ex` + `embeddings/{fake,ollama}.ex` — `Alethea.AI.Embeddings.Ollama` **already exists and is already wired** in `config/dev.exs`; `config/test.exs` uses `Fake`. No new adapter work needed (the issue implies otherwise).
- `lib/alethea/clinical_record/rag/retrieval.ex`, `.../rag/consultation/source.ex` — `source_resource_type` flows through generically; no closed list to extend.
- `lib/alethea_web/live/consultation_live.ex:139-144` — `source_kind_label/1` unmoved since #234a, confirmed current location.
- `lib/mix/tasks/alethea.rag.reindex.ex` — `@resource_kinds` L127 + `enqueue/1` L202-206 tightly coupled to `ClinicalRecord.Outbox.event/2`.
- `openspec/adr/003-rag-historia-clinica-navegable.md` — three voices; "eventos semanticables" design explicitly anticipates new event types without RAG refactor.
- Test fixtures: `test/support/fixtures/rag_fixtures.ex`, `test/alethea/clinical_record/rag/indexer_test.exs` — one `test` per eligibility clause, Mox-based embedding stubs, `insert_chunk!/5` opts convention.

## Affected areas

- `lib/alethea/clinical/outbox.ex` — NEW module, `Alethea.Clinical.Outbox.event/3`.
- `lib/alethea/clinical.ex` — `save_message/7` needs `Ecto.Multi` conversion (inbound branch only) to atomically commit the Message row + outbox job.
- `lib/alethea/clinical_record/rag/indexer.ex` — new `eligibility` clause + new `fetch_and_decrypt(:patient_message, ...)` clause.
- `lib/alethea_web/live/consultation_live.ex` — one label clause.
- `lib/mix/tasks/alethea.rag.reindex.ex` — extend `@resource_kinds`, add patient-message fetch, branch `enqueue/1` by outbox-builder module.
- Tests: `indexer_test.exs`, new `clinical/outbox_test.exs`, `telegram_message_worker_test.exs`, `rag_fixtures.ex`, reindex task test, consultation_live test.

## Approaches compared (cross-context outbox emission)

### 1. Extend `Alethea.ClinicalRecord.Outbox` to accept `Message`

- **Pros:** single outbox-builder module.
- **Cons:** `Alethea.ClinicalRecord` (domain core) would import `Alethea.Clinical.Message`, violating the hexagonal boundary and `Alethea.Clinical`'s own documented "sin writer compartido" rule; breaks the module's uniform struct→map pattern since `Message` lacks `professional_id`.
- **Effort:** Low nominal, high architectural cost.

### 2. New minimal `Alethea.Clinical.Outbox` module, reusing the same Oban worker (RECOMMENDED)

- Owned by `Alethea.Clinical`, takes `(event_type, message, professional_id)` explicitly since `Message` has no `professional_id`; `professional_id` is already in scope inside `save_telegram_message/6` from `legacy_patient.professional_id` — zero extra query. Calls the same `AletheaJobs.ClinicalRecordOutboxWorker.new/1` (content-agnostic worker).
- **Pros:** respects bounded-context ownership, no reverse dependency, small isolated diff, matches ADR-003's "add a clause, zero restructuring" story.
- **Cons:** small duplication of the allowlist idiom; the worker's name (`ClinicalRecordOutboxWorker`) becomes a minor stale-naming smell once it also consumes `Alethea.Clinical` events — flag as a moduledoc note, not a rename, in this issue's scope.
- **Effort:** Low, isolated.

`Rag.Indexer` gaining a read-only `fetch_and_decrypt(:patient_message, ...)` clause is NOT the same kind of violation — `Rag.Indexer` is inherently a cross-context aggregator by ADR-003's design already reading 5 `ClinicalRecord` schemas; this is an already-anticipated extension of an existing seam, not new coupling. Cosmetic follow-up (not blocking): consider a future rename of `Alethea.ClinicalRecord.Rag` to a neutral `Alethea.Rag` namespace once it demonstrably spans 2 contexts.

## Recommendation

**Approach 2.** It is the only option consistent with CLAUDE.md's hexagonal-architecture convention and `Alethea.Clinical`'s documented "no shared writer" boundary.

## Additional finding: transactional-integrity gap

`save_message/7`/`save_telegram_message/6` do a bare `Repo.insert()` with no transaction, unlike every `Alethea.ClinicalRecord` outbox emitter (`lib/alethea/clinical_record.ex` lines 210-239, 261-289, 488-509, 695-709, 760-781), which all use `Ecto.Multi.insert(:record, ...) |> Oban.insert(:outbox_event, fn ... end) |> Repo.transaction()`. To emit `patient_message_received` without a durability gap, `save_message/7` must adopt the same `Ecto.Multi` shape, gated to `direction == "inbound"` only — safely isolated to the single inbound call site (`telegram_message_worker.ex:142`); the two outbound call sites (L285, L695) are untouched since ADR-003's "voz del paciente" is patient-authored content only.

## Slice boundaries (flag for sdd-tasks)

Multi-file, cross-context change touching 2 bounded contexts + a Mix task + a LiveView + a new module. Rough authored-line estimate (excluding tests) is 130-180 lines; with tests this plausibly approaches or exceeds the 400-line PR budget. Recommend splitting along the same incremental-WU precedent #196 used:

- **Slice 1** (no wiring): `Indexer.eligibility/1` + `fetch_and_decrypt(:patient_message, ...)`, reindex task extension, `ConsultationLive` label — independently testable via `Indexer.index_event/1` with a manually-shaped args map.
- **Slice 2** (wiring): new `Alethea.Clinical.Outbox` + `Ecto.Multi` conversion + actual emit on inbound save.

## Risks

1. Transactional-integrity gap in `save_message/7` (bare insert, no outbox atomicity) must be fixed as part of this change, not deferred.
2. Scope creep risk: gating `patient_message_received` to inbound-only must be explicit in spec/design or a future contributor may accidentally index AI-elicited replies as "patient voice."
3. Naming smell on `AletheaJobs.ClinicalRecordOutboxWorker` once it consumes cross-context events — needs a moduledoc note, tracked as a non-blocking follow-up.
4. Likely exceeds the 400-line PR budget — needs explicit slicing decision before `sdd-apply`.

## Key learnings

1. The issue's cited function `Clinical.save_message/8` does not exist; the real functions are `save_message/7` and `save_telegram_message/6`.
2. `Alethea.AI.Embeddings.Ollama` already exists and is already wired into dev config, contrary to the issue implying new adapter work.
3. `Alethea.ClinicalRecord.Outbox` cannot dispatch `Alethea.Clinical.Message` because that struct has no `professional_id` field.
4. `save_message/7` currently performs a bare `Repo.insert` with no transaction, unlike every existing ClinicalRecord outbox emitter.
5. Only one of three `save_telegram_message/6` call sites is inbound, making direction-gated outbox emission safe and isolated.
