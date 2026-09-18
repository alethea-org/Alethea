# Tasks: telegram-rag-ingestion-262 (#262 — Telegram RAG ingestion, patient voice)

## Review Workload Forecast

| Field | Value |
|-------|-------|
| Estimated changed lines | Slice 1 ≈320, Slice 2 ≈265 (combined ≈585) |
| 400-line budget risk | Slice 1: Low. Slice 2: Low. Combined: High |
| Chained PRs recommended | Yes |
| Suggested split | PR 1 (Slice 1) → PR 2 (Slice 2) |
| Delivery strategy | ask-on-risk |
| Chain strategy | feature-branch-chain |

Decision needed before apply: Yes
Chained PRs recommended: Yes
Chain strategy: feature-branch-chain
400-line budget risk: Low (per slice) / High (combined)

### Suggested Work Units

| Unit | Goal | Likely PR | Focused test command | Runtime harness | Rollback boundary |
|------|------|-----------|----------------------|-----------------|-------------------|
| 1 | Slice 1: new `Clinical.Outbox` + `Indexer` patient_message clauses + reindex task + label, operator-reachable only | PR 1 (base: `feat/262-telegram-rag-ingestion`) | `mix test test/alethea/clinical/outbox_test.exs test/alethea/clinical_record/rag/indexer_test.exs test/mix/tasks/alethea.rag.reindex_test.exs test/alethea_web/live/consultation_live_test.exs` | `mix alethea.rag.reindex --patient-id <uuid> --confirm` (real operator path, zero live callers) | Revert file set; purge `patient_message` chunks; no live-path impact |
| 2 | Slice 2: `save_message/7` → `persist/3` Multi, inbound-gated, live emission | PR 2 (base: PR 1's branch) | `mix test test/alethea/clinical_test.exs test/alethea/jobs/telegram_message_worker_test.exs` | Full `mix test` (regression sweep, per design's noise-list) | Revert `clinical.ex` diff only; outbound path untouched by construction (AD2) |

## Phase 1: Slice 1 — Journaling Outbox Builder (Req: Journaling outbox builder)

- [x] 1.1 RED: `test/alethea/clinical/outbox_test.exs` — `event/3` returns changeset with exactly 5 allowlisted args, `resource_type == "patient_message"`, worker `AletheaJobs.ClinicalRecordOutboxWorker`; nil `professional_id` raises `FunctionClauseError` (AD5).
- [x] 1.2 GREEN: create `lib/alethea/clinical/outbox.ex` — `Alethea.Clinical.Outbox.event/3(event_type, %Message{}, professional_id)`, `@allowed_args`, guards `is_binary(event_type) and is_binary(professional_id)` (AD1, AD5).

## Phase 2: Slice 1 — Indexer Ingestion (Req: Indexer ingestion of patient messages, Patient-DEK encryption)

- [x] 2.1 RED: `indexer_test.exs` — add `eligibility("patient_message_received") == {:index, :patient_message}` in the indexable-events describe (must precede `is_binary` catch-all).
- [x] 2.2 RED: `indexer_test.exs` — integration test: seed inbound `Message` via `Clinical.save_message/7`, run `index_event/1`, assert one `Chunk` with `source_resource_type == "patient_message"`, `target_behavior_id == nil`, `source_occurred_at == to_usec(message.timestamp)`, decrypts via patient DEK.
- [x] 2.3 RED: `indexer_test.exs` — missing message: `fetch_and_decrypt(:patient_message, <deleted-id>, ...)` path yields `{:error, :not_found}` via `index_event/1` on a stale resource_id. **DEVIATION**: spec/tasks said `{:cancel, :not_found}` directly from `index_event/1`; verified against all 5 existing resource kinds that `index_event/1` always returns `{:error, :not_found}` for a missing resource and only `ClinicalRecordOutboxWorker.classify/1` remaps to `{:cancel, :not_found}` (confirmed by that worker's own test suite). Implemented identically for consistency, per the apply instruction to mirror an existing clause's exact shape.
- [x] 2.4 RED: security test — raw `Repo.query!` on `clinical_record_rag_chunks` for a `patient_message` row returns binary ciphertext, not plaintext (AC2).
- [x] 2.5 RED: idempotency test — run `index_event/1` twice on same patient_message, assert chunk count converges (no dupes).
- [x] 2.6 GREEN: `lib/alethea/clinical_record/rag/indexer.ex` — `alias Alethea.Clinical.Message`; `eligibility("patient_message_received")` clause before catch-all; `fetch_and_decrypt(:patient_message, resource_id, patient, kek, patient_dek)` clause per design section 2 (AD4, `to_usec/1`, no `DateTime.from_naive!`).

## Phase 3: Slice 1 — Operator Reindex + UI Label (Req: Idempotent operator reindex coverage, Patient-voice citation label)

- [x] 3.1 RED: `test/mix/tasks/alethea_rag_reindex_test.exs` (actual filename on disk differs from the dotted name above) — seed 2 inbound + 1 outbound message; dry run reports `patient_message=2`; `--confirm` enqueues exactly 2 via `:rag_reindex_enqueue` seam; second run converges (no dupes).
- [x] 3.2 GREEN: `lib/mix/tasks/alethea.rag.reindex.ex` — `alias Alethea.Clinical.Message`, `alias Alethea.Clinical.Outbox, as: JournalingOutbox`; added `patient_message` to `@resource_kinds`; `patient_messages/1` filters `direction == "inbound"`; threaded `patient` through `enqueue_entries/2`/`enqueue/2`; new `enqueue({event, "patient_message", record}, patient)` clause routing to `JournalingOutbox.event(record, patient.professional_id)`.
- [x] 3.3 RED: `consultation_live_test.exs` — seed a `patient_message` chunk via `insert_chunk!/5`, stub embedding near-match, assert rendered HTML has `"Mensaje del paciente"` + formatted date/time.
- [x] 3.4 GREEN: `lib/alethea_web/live/consultation_live.ex` — add `source_kind_label("patient_message")` clause after the `functional_analysis_draft` clause, before the `other` catch-all.
- [x] 3.5 GREEN (docs-only, no test): `lib/alethea_jobs/clinical_record_outbox_worker.ex` — moduledoc note that it now also consumes `Alethea.Clinical.Outbox` events (Q4, no rename).

## Phase 4: Slice 2 — Transactional Inbound Emission (Req: Transactional, inbound-gated event emission)

- [x] 4.1 RED: `clinical_test.exs` — `save_message(patient, txt, dek, "inbound", "spontaneous")` → `assert_enqueued(worker: AletheaJobs.ClinicalRecordOutboxWorker, args: %{"event" => "patient_message_received", "resource_id" => msg.id, "professional_id" => patient.professional_id})`.
- [x] 4.2 RED: `clinical_test.exs` — outbound: `save_message(..., "outbound", "elicited")` → `refute_enqueued(worker: AletheaJobs.ClinicalRecordOutboxWorker)`.
- [x] 4.3 RED (AD3): `clinical_test.exs` — replay same `telegram_message_id` → `{:error, %Ecto.Changeset{} = cs}`, `Keyword.has_key?(cs.errors, :telegram_message_id)`, `SafeReason.for_log(cs) == "[:telegram_message_id]"` (no raw 4-tuple leak to `SafeReason.for_log/1`); assert no outbox job enqueued.
- [x] 4.4 RED: `clinical_test.exs` — atomicity: force `Oban.insert` failure inside the Multi. **DEVIATION**: implemented via a genuine Postgres CHECK-constraint violation on `oban_jobs` scoped to the test's unique `professional_id` (`assert_raise Ecto.ConstraintError`), mirroring `ClinicalRecordTest`'s "create_target_behavior/3 — atomicity" precedent exactly, instead of a "stubbed builder" — `Outbox.event/3` is a plain function, not a Mox-mockable port/behaviour, so there is no seam to inject a broken changeset without reaching into private internals (same constraint that precedent test already documented for `ClinicalRecord`'s own outbox Multi). Assert no `Message` row persists — confirmed GREEN.
- [x] 4.5 GREEN: `lib/alethea/clinical.ex` — added `Outbox` to the existing `alias Alethea.Clinical.{Message, Outbox, Summary, Trend}` group; refactored `save_message/7` to build the changeset then call private `persist/3`; `persist(changeset, "inbound", patient)` uses `Ecto.Multi.insert(:message, ...) |> Oban.insert(:outbox_event, fn %{message: m} -> Outbox.event("patient_message_received", m, patient.professional_id) end) |> Repo.transaction()`, case-mapped to `{:ok, %{message: message}} -> {:ok, message}` / `{:error, :message, changeset, _changes} -> {:error, changeset}` / `{:error, _step, reason, _changes} -> {:error, reason}` (AD2, AD3); `persist(changeset, _direction, _patient)` stays bare `Repo.insert(changeset)` byte-for-byte. The dead `cond` (both branches returned the same `{:error, changeset}`) collapsed away per design's "Learned" note.

## Phase 5: Slice 2 — Worker Regression + Q1 Boundary Enforcement (Req: End-to-end citation, Outbound never emits)

- [x] 5.1 RED: `telegram_message_worker_test.exs` — named test `"neither outbound call site emits a patient-voice outbox event"` in the safe-path describe: drive one full `perform/1`, `jobs = all_enqueued(worker: AletheaJobs.ClinicalRecordOutboxWorker)`, `assert length(jobs) == 1`, `assert hd(jobs).args["resource_id"] == inbound.id`.
- [x] 5.2 RED: repeat 5.1's exact assertion in the crisis describe block (covers `handle_crisis_path/9`, ~L684-707 on current line numbers).
- [x] 5.3 GREEN: confirmed 5.1/5.2 pass with zero code changes to `telegram_message_worker.ex` (verify-only file per design) — both tests were GREEN on first run because AD2 holds by construction (outbound routes through `persist/3`'s bare-`Repo.insert` clause).
- [x] 5.4 Regression: audited all 6 flagged noisy call sites (`accounts_test.exs:96,206`, `clinical_record_test.exs:1084`, `source_ref_test.exs:48,88`, `emotion_analysis_worker_test.exs:121`, `session_timeout_worker_test.exs:62`, `alethea_demo_process_test.exs:110`) plus `clinical_record/rag/indexer_test.exs` (also seeds inbound messages via `save_message/7`, not on the original flagged list) and `clinical_record/rag/consultation/live_test.exs`'s `state_snapshot/0` (`Repo.all(Oban.Job)` before/after equality). **Finding**: none of the 6 flagged sites, nor the two additional ones found, has an unfiltered job-count assertion that the new `patient_message_received` outbox job would break — all existing `assert_enqueued`/`refute_enqueued` calls near those sites are worker-filtered to a DIFFERENT worker (`TelegramOutboundWorker`, `SessionTimeoutWorker`) or absent entirely, and `RagFixtures.clear_pending_outbox!/1` was confirmed to already filter by worker name (`AletheaJobs.ClinicalRecordOutboxWorker`, the SAME worker `Clinical.Outbox` targets) so it would have covered both event families had a fix been needed. No `clear_pending_outbox!/1` call sites were added — confirmed by running all 8 files together (122/122 passed) plus the full `telegram_message_worker_test.exs` (48/48) and `clinical_test.exs` (8/8) in isolation.
- [x] 5.5 Regression: confirmed existing outbound rollback tests (`"diagnosis-save failure raises BEFORE enqueueing..."` ~L790-840, the crisis-path R3 forced-failure test ~L1171-1272) pass unmodified (AD2 guard) — part of the 48/48 full-file run.

## Phase 6: Cleanup

- [ ] 6.1 File follow-up issue for Q6 (retention/legal-deletion, `patient_message` chunks out of scope for #262). **NOT filed by this apply batch** — flagged for the orchestrator (this executor has no `gh`/network mandate in scope).
- [ ] 6.2 Run `mix precommit` on both slices before each PR. **NOT run by this apply batch** per the orchestrator's explicit testing/verification protocol (focused tests only, no full suite, no commit) — left for the orchestrator/verify phase.
