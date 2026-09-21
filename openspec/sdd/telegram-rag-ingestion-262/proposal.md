# Proposal — telegram-rag-ingestion-262

**Source issue:** alethea-org/Alethea#262 — "Ingestar mensajes de Telegram en el RAG (Voz del Paciente - ADR-003)"
**Artifact store:** hybrid (mirrored to Engram `sdd/telegram-rag-ingestion-262/proposal`)
**Depends on exploration:** `openspec/sdd/telegram-rag-ingestion-262/exploration.md` / Engram `sdd/telegram-rag-ingestion-262/explore`
**Fixed inputs (not re-decided here):** ADR-003 (three voices, eventos semanticables, chunk = complete event, outbox-incremental ingest, immediate purge), CLAUDE.md security mandates #1 and #5, the #196 projection contract.
**Execution mode:** auto — the product/design forks below could NOT be asked interactively. They are recorded as **explicit open questions with recommendations** in the final section and MUST be resolved by the product owner before `sdd-apply`.
**Note on sources:** no shell is available in this phase, so `gh issue view 262` could not be run; the issue's acceptance criteria were supplied verbatim by the orchestrator and are mirrored one-for-one in Success criteria.

## Intent

**Problem.** ADR-003 decided the RAG is the patient's *navigable clinical record* with three voices — paciente, psicólogo, sistema. Today only the psychologist's voice exists: #196 wired `Alethea.ClinicalRecord` events (clinical notes, cited evidence, clinician observations, accepted AI proposals, functional-analysis drafts) into `clinical_record_rag_chunks`. `Alethea.Clinical.Message` — the Telegram journaling stream, the literal *voz del paciente* — never emits an outbox event, so nothing the patient ever wrote is retrievable or citable in the grounded clinical chat.

**Why now.** The asymmetry is user-visible and clinically misleading. A psychologist asks the consultation chat "¿cuántas crisis tuvo este mes?" or "¿me mencionó algo del suegro?" — exactly ADR-003's motivating questions — and gets an answer grounded only in what the *professional* wrote, silently omitting the patient's own words. The chat looks complete but is systematically one-sided, and the clinician has no signal that a voice is missing. The consumer side (`Retrieval`, `Consultation.Source`, `Indexer`'s eligibility seam) was built generically for precisely this extension; the only missing piece is a producer.

**Success.** An inbound Telegram message becomes a first-class, encrypted, retrievable, citable clinical event within the normal outbox latency; the consultation chat cites it as "Mensaje del paciente" with its timestamp; the operator reindex tool rebuilds it idempotently alongside every other voice; and no AI-authored text is ever cited back as if the patient had said it.

## Scope

### In scope

- **New outbox event `patient_message_received`** for inbound Telegram messages, produced by a new `Alethea.Clinical`-owned outbox builder (D1) and consumed by the existing, unmodified worker (D2).
- **Transactional emission**: convert `Clinical.save_message/7`'s persistence to `Ecto.Multi` so the `Message` row and its outbox job commit atomically, gated to the inbound branch only (D3). This closes a pre-existing durability gap, not just a new-feature concern — see Q2.
- **Indexer ingestion of `:patient_message`**: one `eligibility/1` clause plus one `fetch_and_decrypt/5` clause reading `Alethea.Clinical.Message`, decrypting with the patient's DEK via `PatientVault`, stamping `source_resource_type: "patient_message"` and `source_occurred_at` from `message.timestamp` (D4).
- **Operator reindex coverage**: `mix alethea.rag.reindex --patient-id <uuid> --confirm` includes inbound patient messages, idempotently, through the same `replace_chunks/2` delete-then-insert convergence.
- **Consultation UI label**: one `source_kind_label("patient_message")` clause → `"Mensaje del paciente"`, rendered with the existing date/time formatting.
- **Tests**: `IndexerTest` (eligibility + fetch/decrypt + `index_event/1`), a new `Clinical.OutboxTest`, `TelegramMessageWorkerTest` (event emitted on inbound, **not** on either outbound call site), retrieval coverage, `ConsultationLiveTest` label, reindex-task coverage, RAG fixtures helper.

### Out of scope (explicit non-goals)

- **Outbound / AI-authored messages.** Never indexed. This is the load-bearing boundary of ADR-003's voice model — see Q1.
- **A new embeddings adapter.** `Alethea.AI.Embeddings.Ollama` already exists and is already wired (dev → Ollama, test → Fake); `Indexer.embed_chunks/1` already dispatches through `AI.embeddings()`. The issue text implies otherwise; it is wrong.
- **Changes to `Retrieval` or `Consultation.Source`.** Neither hardcodes a resource-type list; `source_resource_type` flows through as an opaque string. Only the LiveView label mapping changes.
- **Audio, attachments, OCR, wearables.** ADR-003 already excludes attachments; only free text is embedded.
- **Extending `Alethea.ClinicalRecord.Outbox`'s closed vocabulary.** Rejected on hexagonal grounds (D1).
- **Renaming `AletheaJobs.ClinicalRecordOutboxWorker` or the `Alethea.ClinicalRecord.Rag` namespace.** Cosmetic; see Q4.
- **Retention / legal deletion for patient-message chunks.** #197 covers the six `ClinicalRecord` tables only. See Q6 — a real discovered gap, but a separate change.
- **Retrieval ranking or per-voice balancing.** See Q5.

## Capabilities

> This repository has no `openspec/specs/` source-of-truth tree; deltas land at `openspec/sdd/{change}/spec.md` per repo convention.

### New capabilities

- `patient-message-rag-ingestion`: inbound-only eligibility and the patient-voice boundary, transactional outbox emission from the journaling context, patient-DEK-encrypted chunk projection, idempotent reindex coverage, and patient-voice citation presentation.

### Modified capabilities

- `clinical-rag-projection`: the ingest-eligibility table gains `patient_message_received` → `{:index, :patient_message}`, and `source_resource_type` gains `"patient_message"`. The projection's consumer, chunking, encryption and idempotency contracts are unchanged.

## Approach

```
Telegram inbound update
  └─ Jobs.TelegramMessageWorker (L142, the ONLY inbound call site)
       └─ Clinical.save_telegram_message/6 → Clinical.save_message/7
            └─ Ecto.Multi                                              [D3, NEW]
                 ├─ Multi.insert(:message, Message.changeset(...))
                 └─ Oban.insert(:outbox_event, ...)  IF direction == "inbound"
                       └─ Clinical.Outbox.event(                       [D1, NEW module]
                            "patient_message_received", message, professional_id)
                          professional_id ← legacy_patient.professional_id
                                             (already in scope, zero extra query)
                 └─ Repo.transaction()  — all-or-nothing

  ══ same Oban queue, SAME worker, unmodified ══                       [D2]
       └─ AletheaJobs.ClinicalRecordOutboxWorker
            └─ Rag.Indexer.index_event/1
                 ├─ eligibility("patient_message_received")
                 │       → {:index, :patient_message}                  [NEW clause]
                 └─ fetch_and_decrypt(:patient_message, ...)           [NEW clause, D4]
                        Repo.get(Message) → resolve_dek(v, ...)
                        → PatientVault.decrypt(encrypted_content, dek)
                        → {text, to_usec(message.timestamp), nil, v, dek}
                 └─ chunk → embed → PatientVault.encrypt
                 └─ replace_chunks({"patient_message", id}, attrs)     — idempotent

Read path (no change needed): Retrieval → Consultation.answer/4 → Source
  └─ ConsultationLive.source_kind_label("patient_message")             [NEW clause]
         → "Mensaje del paciente" + existing format_datetime/1

Operator path: mix alethea.rag.reindex --patient-id <uuid> --confirm
  └─ @resource_kinds + "patient_message"
  └─ patient_messages(patient_id): direction == "inbound" only
  └─ enqueue/1 routes by resource_type: ClinicalRecord.Outbox.event/2
        vs Clinical.Outbox.event/3 (the extra professional_id comes from
        the already-fetched Alethea.Accounts.Patient)
```

### Key decisions

| # | Decision | Rationale |
|---|---|---|
| **D1** | **New `Alethea.Clinical.Outbox.event/3`**, owned by the journaling context, taking `(event_type, message, professional_id)` explicitly. Do **not** extend `Alethea.ClinicalRecord.Outbox`. | Extending the existing builder would make `Alethea.ClinicalRecord` (a domain core) import a schema from a different bounded context — exactly the "sin writer compartido" coupling `Alethea.Clinical`'s own moduledoc disclaims and CLAUDE.md's hexagonal rule forbids. It also breaks that module's uniform struct→map shape: `Message` has no `professional_id` field, so `event/2` would need a special case. Cost of the new module is ~40 lines and ~10 duplicated allowlist lines; cost of the alternative is a reverse dependency between contexts. |
| **D2** | **Reuse `AletheaJobs.ClinicalRecordOutboxWorker` unmodified.** | Its `perform/1` matches only the 5-key args shape and dispatches to `Indexer.index_event/1`; it is content-agnostic and, per ADR-003, *is* the single unified RAG-ingest consumer for all three voices. Reuse also inherits the already-correct failure classification (`{:cancel, :not_found}` for deleted sources, retry for transient embedding failures) for free. |
| **D3** | **Convert `save_message/7` to `Ecto.Multi`, gated to the inbound branch.** The external contract `{:ok, Message.t()} \| {:error, term()}` is preserved by unwrapping `{:ok, %{message: msg}}` and remapping `{:error, :message, changeset, _}` onto the existing changeset-error path (the `telegram_message_id` unique-constraint branch the worker depends on must keep its exact shape). | Today it is a bare `Repo.insert` with no transaction — the only outbox emitter in the codebase that would be. Every `ClinicalRecord` emitter uses `Multi.insert \|> Oban.insert \|> Repo.transaction`. Emitting without atomicity means a crash between the two writes silently drops the indexing signal: the message exists, is never indexed, and nothing reports it. The only recovery would be the manual reindex task — an operator command nobody knows to run. See Q2. |
| **D4** | **Chunk provenance for messages:** `source_resource_type: "patient_message"`, `source_occurred_at: to_usec(message.timestamp)`, `target_behavior_id: nil`, `encryption_version` and DEK taken from the message's own row via the existing `resolve_dek/4`. | `messages.timestamp` is `:utc_datetime` (second precision) while `Chunk.source_occurred_at` is `:utc_datetime_usec` and `insert_all/3` performs no cast — the same widening `clinical_note`/`functional_analysis_draft` already need. Messages default to `encryption_version: 1`, so `resolve_dek/4` returns the shared patient DEK with no extra query and no clinical-record key is required — satisfying AC2 ("encriptados con el DEK del paciente") exactly. Messages carry no target-behavior link, so `source_link/2` correctly renders no deep link. |
| **D5** | **Event/type vocabulary fixed as `patient_message_received` / `"patient_message"`.** | Taken verbatim from the issue's acceptance criteria; the past-tense event naming matches the existing `*_created` / `*_accepted` / `*_saved` convention. |

## Affected areas

| Area | File | Impact |
|---|---|---|
| Journaling outbox | `lib/alethea/clinical/outbox.ex` | **New** — `event/3`, allowlisted args, reuses the existing worker |
| Journaling writer | `lib/alethea/clinical.ex` | Modified — `save_message/7` → `Ecto.Multi`, inbound-gated emit; `save_telegram_message/6` passes `legacy_patient.professional_id` through |
| RAG ingest | `lib/alethea/clinical_record/rag/indexer.ex` | Modified — one `eligibility/1` clause, one `fetch_and_decrypt/5` clause, `alias Alethea.Clinical.Message` |
| Operator tooling | `lib/mix/tasks/alethea.rag.reindex.ex` | Modified — `@resource_kinds`, inbound-only fetch, `enqueue/1` routed by resource type |
| Consultation UI | `lib/alethea_web/live/consultation_live.ex` | Modified — one `source_kind_label/1` clause |
| Telegram worker | `lib/alethea/jobs/telegram_message_worker.ex` | **Verify only** — L142 inbound unchanged in shape; L285 and L695 outbound must remain non-emitting |
| Retrieval / Source | `lib/alethea/clinical_record/rag/{retrieval,consultation/source}.ex` | **No change** — already generic over `source_resource_type` |
| Tests | `indexer_test.exs`, new `clinical/outbox_test.exs`, `telegram_message_worker_test.exs`, `rag_fixtures.ex`, reindex-task test, `consultation_live_test.exs` | New/Modified |

## Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| **AI-authored text cited as patient evidence** if the inbound gate is wrong or later widened. Creates a self-reinforcing loop: model output becomes grounding for future model answers. | **High impact / Low likelihood if specified** | Q1 must be answered explicitly; the inbound-only rule belongs in the spec as a named scenario with a negative test asserting **no** outbox job for either outbound call site, not merely in a code comment. |
| **Silent indexing loss** if the `Ecto.Multi` conversion is deferred (Q2 answered "split it out"). | Medium | If deferred, Slice 2 must not ship until the transaction fix lands; otherwise the feature is delivered with a known lossy path. Recommendation is to fix it here. |
| **Regression in Telegram duplicate handling** — the worker relies on the `telegram_message_id` unique-constraint changeset error being surfaced unchanged and retry-eligible. The `Multi` error shape differs. | Medium | Explicit remapping in D3 plus a regression test replaying the same `telegram_message_id`. |
| **400-line review budget overrun.** | **High** | Two-slice split (Q3). `sdd-tasks` owns the formal forecast. |
| **Retrieval dilution** — patient messages are orders of magnitude more numerous and much shorter than clinical notes, and may crowd the clinician's voice out of top-k. | Medium | Q5. No ranking change proposed in this scope; needs a product answer before it becomes a support complaint. |
| **Patient-message chunks fall outside #197 retention/legal deletion**, which covers the six `ClinicalRecord` tables only. | Medium | Q6. They remain reachable via the patient DEK, so they are *not* orphaned ciphertext, but they have no tombstone path. Flag as an explicit known limitation. |
| **Embedding cost/latency at message volume** on the Ollama adapter — one embed call per inbound message versus a handful per clinical note. | Low | Existing Oban queue, retries and backoff already bound this; reindex of a chatty patient is the worst case and is operator-triggered. |

## Rollback plan

No migration and no schema change, so rollback is a plain revert plus one purge:

1. Revert the PR(s). Emission stops immediately; the worker and indexer return to their #196 behavior. An unknown `patient_message_received` event still in the queue hits `eligibility/1`'s catch-all → `{:unknown, event}` → `:ok`, so in-flight jobs drain harmlessly rather than crashing.
2. Delete the projection rows: `DELETE FROM clinical_record_rag_chunks WHERE source_resource_type = 'patient_message'`. The projection is non-authoritative and fully rebuildable; no clinical source data is touched.
3. The `Ecto.Multi` conversion is behavior-preserving for the outbound paths and reverts cleanly on its own.

## Dependencies

- **Blocking:** none. #196 (projection) and #197 (tombstone seam) are merged; `Alethea.AI.Embeddings.Ollama` is already wired.
- **Constrained by:** ADR-003 (voices, chunk = complete event, purge mechanism), CLAUDE.md mandates #1 (patient-level encryption) and #5 (sanitize before external LLM calls — unchanged, embeddings stay local).
- **May require:** a short ADR-003 amendment recording the inbound-only rule if Q1's answer is anything other than the recommendation.

## Success criteria

Mirrors the issue's acceptance criteria one-for-one.

- [ ] An inbound Telegram message emits an outbox event and is indexed into `clinical_record_rag_chunks` with `source_resource_type: "patient_message"`.
- [ ] Chunks are encrypted at rest with the patient's DEK via `PatientVault`; a raw `SELECT` returns binary, never text.
- [ ] `Consultation.answer/4` retrieves and cites patient messages when semantically relevant to the clinical query.
- [ ] `ConsultationLive` renders the source label "Mensaje del paciente" with the message's own date and time.
- [ ] `mix alethea.rag.reindex --patient-id <uuid> --confirm` includes patient messages and converges to the same chunk set on repeated runs.
- [ ] **Negative criterion (not in the issue, added deliberately):** outbound/AI-authored messages emit no event and produce no chunk — asserted by test at both outbound call sites.
- [ ] Message row and outbox job commit atomically; neither can exist without the other.
- [ ] Unit and integration tests in `IndexerTest`, `RetrievalTest` and `ConsultationLiveTest`.
- [ ] `mix precommit` passes.

## Locked decisions (Q1-Q6, all confirmed with the recommended option)

- **Q1 — Inbound-only.** `patient_message_received` fires only for `direction == "inbound"`. Outbound/AI-authored replies are never indexed under this event.
- **Q2 — Transaction fix in scope.** `save_message/7` is converted to `Ecto.Multi`, gated to the inbound branch, as part of #262 — not split into a separate PR.
- **Q3 — Slicing, operator-reachable slice first.** Slice 1 = `Clinical.Outbox` + `Indexer` eligibility/fetch_and_decrypt + reindex-task extension + `ConsultationLive` label. Slice 2 = the `Ecto.Multi` conversion + live inbound-gated emission + worker tests.
- **Q4 — Keep the worker name.** `AletheaJobs.ClinicalRecordOutboxWorker` is not renamed (Oban persists the worker name in `oban_jobs.worker`; renaming strands in-flight jobs). Add a moduledoc note only.
- **Q5 — No trivial-message filter.** Index all inbound messages, no length/signal cutoff. Per-voice retrieval balancing is deferred as a future follow-up measured against real data.
- **Q6 — Retention/legal-deletion is an explicit non-goal.** #197's retention/tombstone path covers only the six `ClinicalRecord` tables; patient-message chunks are out of scope here, documented as a known limitation with a follow-up issue to be filed.

## Proposal question round — RESOLVED, see Locked decisions above

Auto mode prevented an interactive round. These are real forks with product consequences, not harness mechanics. Each carries a recommendation; `sdd-spec` and `sdd-design` should proceed on the recommendations **only if the orchestrator confirms them**.

### Mandated questions

**Q1 — Inbound-only scoping. Confirm that `patient_message_received` fires ONLY for `direction == "inbound"`, never for outbound AI/system replies.**

*Recommendation: yes, inbound-only.* ADR-003's voice table assigns messages to the *paciente* row; AI-generated replies belong to the *sistema* voice, which ADR-003 lists as a distinct source (RoBERTa labels, inferred psychometrics, summaries) precisely so "todo lo que el sistema sabe del paciente" can be audited separately. Indexing outbound text would (a) let the consultation chat cite model output under the label "Mensaje del paciente", i.e. attribute AI words to the patient in a clinical record; (b) violate CLAUDE.md's source-anchoring mandate, since the citation would point at a message the patient never wrote; and (c) create a closed loop where the model's own prior output becomes retrieval grounding for its next answer, amplifying any earlier error. The gate is cheap and safe: only one of the three `save_telegram_message/6` call sites is inbound. **If the product owner wants the AI side searchable, that is a separate "system voice" capability with its own label and its own spec — not a widening of this one.**

**Q2 — Transaction-fix scope. `save_message/7` has no transaction today. Is converting it to `Ecto.Multi` in scope for #262, or a separate preceding PR?**

*Recommendation: fix it here, scoped tightly to the inbound branch.* An outbox event emitted outside a transaction with its source row is not an outbox pattern — it is two independent writes that can diverge. A crash between them leaves a message that exists but is never indexed, with no error, no retry and no alert; the clinician sees a chat that is quietly missing evidence, which is the exact failure this issue exists to eliminate. Shipping the feature on a known-lossy path to keep the diff literal would be a false economy. The change is small and provably isolated: the two outbound call sites (L285, L695) already run inside `Repo.transaction` and are untouched, and the only behavioral risk — the `telegram_message_id` duplicate-error shape the worker depends on — is explicitly preserved in D3 and regression-tested. *Alternative if rejected:* land it as a standalone preceding PR and **block** Slice 2 on it; do not ship emission without it.

**Q3 — Slicing. Confirm a two-slice split, and confirm the split point.**

*Recommendation: two slices, but with a corrected boundary versus the exploration's.* The exploration put `Alethea.Clinical.Outbox` in Slice 2, but the reindex task needs `Clinical.Outbox.event/3` to enqueue anything — so Slice 1 would not be independently shippable. Proposed instead:

- **Slice 1 — patient voice, operator-reachable.** `Clinical.Outbox` (pure builder, no caller in the live path), `Indexer` eligibility + `fetch_and_decrypt` clauses, reindex-task extension, `ConsultationLive` label, plus tests. This slice is genuinely end-to-end verifiable through the reindex command and already satisfies AC2–AC5 and AC6; a patient's history becomes citable by running one operator command.
- **Slice 2 — live wiring.** `save_message/7` `Ecto.Multi` conversion (Q2) + inbound-gated emission + worker tests. This adds the automatic half of AC1 and the negative outbound criterion.

This boundary mirrors #196's own WU precedent (indexer shipped as an independently testable, initially uncalled unit before its consumer was wired) and keeps each slice with a clear finish, autonomous verification and a trivial rollback. `sdd-tasks` still owns the formal 400-line forecast; the cached delivery strategy is `ask-on-risk`, so this needs an orchestrator decision before apply.

**Q4 — `AletheaJobs.ClinicalRecordOutboxWorker` naming, now that it also consumes `Alethea.Clinical` events.**

*Recommendation: keep the name; update the moduledoc.* Per ADR-003 this worker is the single unified RAG-ingest consumer for all three voices, so the accurate name would be something like `RagIngestWorker` — but renaming an `Oban.Worker` module is not cosmetic at runtime: the module name is persisted in `oban_jobs.worker`, so a rename strands every enqueued and retryable job under the old name and needs a compatibility shim or a drain window. That is real operational risk bought for zero behavioral gain, inside a change already at budget risk. Add a moduledoc line stating it now consumes `Alethea.Clinical.Outbox` events too, and track the rename (together with the `Alethea.ClinicalRecord.Rag` → `Alethea.Rag` namespace move the exploration flags, now that the package demonstrably spans two contexts) as a separate housekeeping issue with its own migration plan.

### Discovered during proposal (not in the orchestrator's list, but product-relevant)

**Q5 — Retrieval volume and noise.** Patient messages are far more numerous and far shorter than clinical notes ("ok", "sí", an emoji). Every message becomes one full-event chunk under ADR-003's chunking rule. Two product decisions follow: (a) should trivially short or low-signal messages be excluded from indexing, and by what rule (minimum token count? sentiment/label-bearing only?); and (b) does top-k retrieval need per-voice balancing so the patient's volume cannot crowd the clinician's notes out of the answer? *Recommendation: index all inbound messages in this change (no filter — a one-word "sí" can be clinically meaningful in context, and an arbitrary length cutoff is a silent clinical judgement the system should not make unilaterally), and treat per-voice retrieval balancing as a follow-up measured against real data rather than guessed at now.* Flagging it so it is an accepted tradeoff rather than a surprise.

**Q6 — Retention and legal deletion coverage.** #197's retention, legal deletion and terminal crypto-erasure cover the six `ClinicalRecord` tables only (BR3). Patient-message chunks fall outside that scope entirely: they have no retention clock, no tombstone path, and no purge trigger. They are encrypted under the shared patient DEK, so they are not orphaned ciphertext and they do disappear if that key is ever destroyed — but nothing today ages them out or deletes them on request. *Recommendation: explicitly out of scope for #262 and recorded as a known limitation, with a follow-up issue to extend retention to the journaling voice.* This needs an answer because it is a compliance-shaped gap, and "we did not think about it" and "we considered it and deferred it" are very different positions to be in later.
