# Design — telegram-rag-ingestion-262 (#262)

**Depends on:** `proposal.md` (D1–D5, Q1–Q6 locked) · `exploration.md` · ADR-003
**Artifact store:** hybrid (mirrored to Engram `sdd/telegram-rag-ingestion-262/design`)
**Delivery:** 2 slices (Q3). Neither slice exceeds the 400-line review budget; combined they would.

## Technical Approach

Add a **producer** for the patient voice. Every consumer seam already exists and is generic
(`ClinicalRecordOutboxWorker` → `Indexer.index_event/1` → `Retrieval` → `Consultation.Source`).
The change is: a new bounded-context-owned outbox builder, two new `Indexer` clauses, an operator
reindex path, one label clause, and — separately — the transactional wiring of the live inbound save.

Slice 1 is operator-reachable end-to-end via `mix alethea.rag.reindex` with **zero calls from the
live path**, mirroring #196's WU2 precedent (indexer shipped uncalled and independently testable).
Slice 2 wires the live inbound emission and fixes the pre-existing atomicity gap.

## Architecture Decisions

| # | Decision | Alternatives rejected | Rationale |
|---|---|---|---|
| **AD1** | New `Alethea.Clinical.Outbox.event/3`, owned by the journaling context; same `@allowed_args` idiom, same `AletheaJobs.ClinicalRecordOutboxWorker.new/1` target. | Extend `ClinicalRecord.Outbox.event/2` with a `%Message{}` clause. | `ClinicalRecord` is a domain core; importing `Clinical.Message` is a reverse cross-context dependency that `Alethea.Clinical`'s own moduledoc ("sin writer compartido") and CLAUDE.md's hexagonal rule forbid. `Message` also has no `professional_id`, so `event/2`'s uniform struct→map shape would need a special case. Cost: ~35 lines + ~5 duplicated allowlist lines. |
| **AD2** | **`Ecto.Multi` gated to `direction == "inbound"`.** The outbound branch keeps its current bare `Repo.insert`, byte-for-byte. | Convert unconditionally for uniformity. | Both outbound call sites (`telegram_message_worker.ex:285`, `:695`) run **inside an enclosing `Repo.transaction`**. Ecto nested transactions take no savepoint: a failing inner `Repo.transaction(multi)` rolls back the *outer* transaction, after which the callers' `Repo.rollback(reason)` in the `else` branch can no longer run correctly. Gating keeps the two outbound paths provably untouched and shrinks the Slice-2 blast radius to one branch. |
| **AD3** | Error remap `{:error, :message, changeset, _changes}` → `{:error, changeset}`. Non-negotiable, not cosmetic. | Let the 4-tuple surface. | Two consumers depend on the `%Ecto.Changeset{}` shape: (a) the `telegram_message_id` unique-constraint branch in `save_message/7` and the caller contract `{:ok, Message.t()} \| {:error, term()}`; (b) **`AletheaJobs.SafeReason.for_log/1` pattern-matches `%Ecto.Changeset{}`** and falls through to `inspect/1` otherwise — a 4-tuple would inspect the whole changeset (`changes`, `data`) into the raised message at `telegram_message_worker.ex:154`, a PHI-hygiene regression. |
| **AD4** | Reuse `resolve_dek/4` verbatim from `message.encryption_version`; `target_behavior_id: nil`; `source_occurred_at: to_usec(message.timestamp)`. | Hard-pin to `patient_dek`. | Messages default to `encryption_version: 1` and no in-tree caller ever casts it, so `resolve_dek(1, …)` returns the already-loaded shared patient DEK with **no extra query and no clinical-record key requirement** — exactly AC2. A hypothetical v2 message row would resolve the CR DEK and fail loudly as `{:error, :decryption_failed}` (retry→discard), never mis-index. See Open Questions. |
| **AD5** | `Clinical.Outbox.event/3` guards `when is_binary(professional_id)`. | Silently skip emission on `nil`. | `professional_id` is `validate_required` on `Accounts.Patient`, so `nil` means a malformed in-memory struct. Enqueuing `professional_id: nil` would make the worker crash-loop (`Repo.get(Professional, nil)` raises `ArgumentError`) 5 times per message. Failing at the writer, in dev/test, is the correct blast radius. Silently skipping would reintroduce the exact silent-loss failure this change removes. |

## Data Flow

```
SLICE 2 (live)                          SLICE 1 (already shipped, uncalled by live path)
Telegram inbound (worker L142)
  └─ save_telegram_message/6 → save_message/7
       └─ direction == "inbound"?
            yes → Ecto.Multi
                    ├─ Multi.insert(:message, Message.changeset(...))
                    └─ Oban.insert(:outbox_event, fn %{message: m} ->
                         Clinical.Outbox.event(                    ◄── AD1
                           "patient_message_received", m, patient.professional_id))
                    └─ Repo.transaction()  ── all-or-nothing
            no  → Repo.insert()  (unchanged, AD2)

  ══ existing queue :clinical_record_outbox, worker UNMODIFIED (D2) ══
       └─ ClinicalRecordOutboxWorker.perform/1  (5-key args contract)
            └─ Indexer.index_event/1
                 ├─ eligibility("patient_message_received") → {:index, :patient_message}
                 └─ index_resource/5 → Professional + Patient → KEK → patient DEK
                      └─ fetch_and_decrypt(:patient_message, …)   ◄── AD4
                 └─ chunk → embed → PatientVault.encrypt(dek)
                 └─ replace_chunks({"patient_message", id}, attrs)   (idempotent)

Operator: mix alethea.rag.reindex --patient-id <uuid> --confirm
  └─ patient_messages/1 (direction == "inbound" ONLY)
  └─ enqueue/2 routes by resource_type → JournalingOutbox.event/3(…, patient.professional_id)

Read path (unchanged): Retrieval → Consultation.answer/4 → Source
  └─ ConsultationLive.source_kind_label("patient_message") → "Mensaje del paciente"
```

## Interfaces / Contracts

### 1. `lib/alethea/clinical/outbox.ex` — NEW (Slice 1)

Mirrors `ClinicalRecord.Outbox`'s **shape**, does not extend it. No `resource_type/1` dispatch: this
module is closed over exactly one struct, so the type is a literal.

```elixir
defmodule Alethea.Clinical.Outbox do
  @moduledoc """
  Builds content-free Oban job args for `Alethea.Clinical` journaling
  domain events (GitHub #262, ADR-003 "voz del paciente"). Mirrors
  `Alethea.ClinicalRecord.Outbox`'s shape and reuses the SAME consumer
  (`AletheaJobs.ClinicalRecordOutboxWorker`), but is owned by this
  bounded context: `Alethea.ClinicalRecord` must not import
  `Alethea.Clinical.Message` (see this context's moduledoc boundary note).

  `professional_id` is passed explicitly because `Message` carries no
  such field — it is reached through `messages.patient_id -> patients`.
  """
  alias Alethea.Clinical.Message
  alias AletheaJobs.ClinicalRecordOutboxWorker

  @allowed_args ~w(event resource_type resource_id patient_id professional_id)

  @spec event(String.t(), Message.t(), Ecto.UUID.t()) :: Ecto.Changeset.t()
  def event(event_type, %Message{} = message, professional_id)
      when is_binary(event_type) and is_binary(professional_id) do
    %{
      "event" => event_type,
      "resource_type" => "patient_message",
      "resource_id" => message.id,
      "patient_id" => message.patient_id,
      "professional_id" => professional_id
    }
    |> Map.take(@allowed_args)
    |> ClinicalRecordOutboxWorker.new()
  end
end
```

Args contract verified against the consumer: `ClinicalRecordOutboxWorker.perform/1` matches exactly
the 5 string keys `"event" | "resource_type" | "resource_id" | "patient_id" | "professional_id"`;
anything else → `{:cancel, {:malformed_args, keys}}`. No worker change required (Q4: name kept;
add one moduledoc line noting it now also consumes `Alethea.Clinical.Outbox` events).

### 2. `lib/alethea/clinical_record/rag/indexer.ex` — 2 clauses + 1 alias (Slice 1)

```elixir
alias Alethea.Clinical.Message   # cross-context READ only; the Indexer is an
                                 # aggregator by ADR-003 design (already reads 5 CR schemas)

# with the other eligibility/1 clauses, BEFORE the is_binary catch-all:
def eligibility("patient_message_received"), do: {:index, :patient_message}

# with the other fetch_and_decrypt/5 clauses:
defp fetch_and_decrypt(:patient_message, resource_id, patient, kek, patient_dek) do
  case Repo.get(Message, resource_id) do
    nil ->
      {:error, :not_found}

    message ->
      with {:ok, dek} <- resolve_dek(message.encryption_version, patient, kek, patient_dek),
           {:ok, text} <- PatientVault.decrypt(message.encrypted_content, dek) do
        # `messages.timestamp` is `:utc_datetime` (second precision);
        # `Chunk.source_occurred_at` is `:utc_datetime_usec` and
        # `insert_all/3` does not cast — widen or `check_usec!/2` rejects it.
        # No `to_naive`/`from_naive!` wrap here: unlike `clinical_note.inserted_at`,
        # `timestamp` is already a `DateTime`.
        # `target_behavior_id: nil` — a message carries no behavior link, so
        # `source_link/2` correctly renders no deep link.
        {:ok, text, to_usec(message.timestamp), nil, message.encryption_version, dek}
      end
  end
end
```

Ordering constraint: the `eligibility/1` clause MUST precede `def eligibility(event) when is_binary(event)`.
`resolve_dek/4`, `to_usec/1`, `PatientVault.decrypt/2` are used verbatim — signatures confirmed at
`indexer.ex:344-347`, `:401-403`, `patient_vault.ex:35-50`.

### 3. `lib/mix/tasks/alethea.rag.reindex.ex` (Slice 1)

```elixir
alias Alethea.Clinical.Message
alias Alethea.Clinical.Outbox, as: JournalingOutbox   # explicit alias per the
                                                      # Clinical/ClinicalRecord collision rule

@resource_kinds ~w(clinical_note consultation_evidence clinician_observation ai_proposal functional_analysis_draft patient_message)

defp eligible_entries(patient_id) do
  clinical_notes(patient_id) ++ consultation_evidences(patient_id) ++
    clinician_observations(patient_id) ++ accepted_ai_proposals(patient_id) ++
    functional_analysis_drafts(patient_id) ++ patient_messages(patient_id)
end

# INBOUND ONLY (Q1 / ADR-003 voice boundary): outbound rows are
# AI-authored and must never be citable as "Mensaje del paciente".
defp patient_messages(patient_id) do
  Message
  |> where([m], m.patient_id == ^patient_id and m.direction == "inbound")
  |> Repo.all()
  |> Enum.map(&{"patient_message_received", "patient_message", &1})
end
```

`enqueue/1` becomes `enqueue/2` (the patient is already loaded by `run_reindex/2` —
`fetch_patient/1` returns `%Accounts.Patient{}`, so `professional_id` costs zero extra queries):

```elixir
defp enqueue_entries(entries, patient) do   # threaded from run_reindex/2
  ...  case enqueue(entry, patient) do ...
end

defp enqueue({event, "patient_message", message}, patient) do
  event |> JournalingOutbox.event(message, patient.professional_id) |> enqueue_job()
end

defp enqueue({event, _resource_type, record}, _patient) do
  event |> Outbox.event(record) |> enqueue_job()
end
```

`count_by_resource_type/1` and `format_counts/1` pick up `patient_message` automatically from
`@resource_kinds` — no change. `enqueue_job/1` (the `:rag_reindex_enqueue` test seam) is unchanged.

### 4. `lib/alethea_web/live/consultation_live.ex` (Slice 1)

One clause, inserted after `functional_analysis_draft` (line 143) and **before** the
`source_kind_label(other)` catch-all at line 144:

```elixir
defp source_kind_label("patient_message"), do: "Mensaje del paciente"
```

Date/time rendering is already generic (`format_datetime/1`, line 152) and
`source_link/2`'s `%{target_behavior_id: nil}` clause (line 146) already returns `nil` — no deep link.

### 5. `lib/alethea/clinical.ex` — `save_message/7` → `Ecto.Multi` (Slice 2)

External contract unchanged: `{:ok, Message.t()} | {:error, term()}`. `@spec` unchanged.

```elixir
with {:ok, dek} <- get_dek(patient, dek),
     {:ok, encrypted_content} <- PatientVault.encrypt(text, dek) do
  attrs = ...   # unchanged, including the telegram_message_id Map.put

  changeset = Message.changeset(%Message{}, attrs)

  changeset
  |> persist(direction, patient)
  |> case do
    {:ok, message} ->
      {:ok, message}

    {:error, changeset} ->
      # Telegram duplicates are surfaced as raw changeset errors so the
      # worker treats them as retry-eligible (REQ-C3) and so
      # `SafeReason.for_log/1` still matches `%Ecto.Changeset{}` (AD3).
      {:error, changeset}
  end
end

# AD2: only the inbound branch becomes transactional. The two outbound
# call sites (telegram_message_worker.ex:285, :695) already run inside an
# enclosing Repo.transaction; a nested Ecto.Multi failure there would roll
# back the OUTER transaction before the caller's own Repo.rollback/1 runs.
defp persist(changeset, "inbound", patient) do
  Ecto.Multi.new()
  |> Ecto.Multi.insert(:message, changeset)
  |> Oban.insert(:outbox_event, fn %{message: message} ->
    Outbox.event("patient_message_received", message, patient.professional_id)
  end)
  |> Repo.transaction()
  |> case do
    {:ok, %{message: message}} -> {:ok, message}
    # AD3: collapse the Multi 4-tuple back to the historical shape.
    {:error, :message, %Ecto.Changeset{} = changeset, _changes} -> {:error, changeset}
    {:error, _step, reason, _changes} -> {:error, reason}
  end
end

defp persist(changeset, _direction, _patient), do: Repo.insert(changeset)
```

`alias Alethea.Clinical.Outbox` is added to the existing `alias Alethea.Clinical.{Message, Summary, Trend}` group.
`save_telegram_message/6` needs **no signature change**: it already passes the legacy
`%Accounts.Patient{}` (which carries `professional_id`) into `save_message/7` as arg 1.
The `cond` at `clinical.ex:68-79` is dead (both branches return the same value) and collapses
to a single `{:error, changeset}` with the comment preserved — a behavior-preserving simplification.

## File Changes

| Slice | File | Action | Description |
|---|---|---|---|
| 1 | `lib/alethea/clinical/outbox.ex` | Create | `event/3`, allowlisted args, reuses existing worker (AD1, AD5) |
| 1 | `lib/alethea/clinical_record/rag/indexer.ex` | Modify | 1 alias + 1 `eligibility/1` clause + 1 `fetch_and_decrypt/5` clause (AD4) |
| 1 | `lib/mix/tasks/alethea.rag.reindex.ex` | Modify | `@resource_kinds`, `patient_messages/1` (inbound-only), `enqueue/2` routing |
| 1 | `lib/alethea_web/live/consultation_live.ex` | Modify | 1 `source_kind_label/1` clause |
| 1 | `lib/alethea_jobs/clinical_record_outbox_worker.ex` | Modify | moduledoc note only (Q4 — no rename; Oban persists the module name in `oban_jobs.worker`) |
| 2 | `lib/alethea/clinical.ex` | Modify | `save_message/7` → `persist/3`; inbound-gated Multi + error remap (AD2, AD3) |
| 2 | `lib/alethea/jobs/telegram_message_worker.ex` | **Verify only** | No code change. L142 inbound unchanged; L285/L695 must stay non-emitting |
| — | `rag/retrieval.ex`, `rag/consultation/source.ex` | **No change** | Already generic over `source_resource_type` |

## Testing Strategy

Conventions mirrored from `indexer_test.exs` (`use Alethea.DataCase, async: false` — the
`:ai_embeddings` slot is global; `setup :verify_on_exit!`; one `test` per eligibility clause; args
maps built by hand) and `rag_fixtures.ex` (`create_professional!/0`, `create_patient!/1`,
`insert_chunk!/5`, `stub_query_embedding/1`, `clear_pending_outbox!/1`).

### Slice 1

| Layer | What | Approach |
|---|---|---|
| Unit | `eligibility("patient_message_received") == {:index, :patient_message}` | One `test` in the "indexable events" describe |
| Unit | `Clinical.Outbox.event/3` → new `test/alethea/clinical/outbox_test.exs` | Assert `changeset.changes.args` has exactly the 5 allowlisted keys, `worker == "AletheaJobs.ClinicalRecordOutboxWorker"`, `resource_type == "patient_message"`; assert a nil `professional_id` raises `FunctionClauseError` (AD5) |
| Integration | `index_event/1` on a real inbound `Message` | Seed via `Clinical.save_message/7`, run `index_event/1`, assert one `Chunk` with `source_resource_type == "patient_message"`, `target_behavior_id == nil`, `source_occurred_at == to_usec(message.timestamp)`, and `PatientVault.decrypt(chunk.encrypted_content, patient_dek) == {:ok, text}` |
| Security | Chunk opacity (AC2) | Raw `Repo.query!("SELECT encrypted_content FROM clinical_record_rag_chunks")` returns binary ≠ plaintext |
| Integration | Idempotency | Run `index_event/1` twice; assert chunk count converges (`replace_chunks/2` delete-then-insert) |
| Integration | Reindex task | `capture_io` the `ALETHEA_RAG_REINDEX_DRY_RUN` line and assert `patient_message=N`; with `--confirm` + the `:rag_reindex_enqueue` seam, assert **only inbound** rows enqueue (seed 2 inbound + 1 outbound → expect 2) |
| UI | `ConsultationLive` label | `insert_chunk!(..., source_resource_type: "patient_message")` + `stub_query_embedding(near_vector())`, assert `html =~ "Mensaje del paciente"` and the formatted `%d/%m/%Y %H:%M` |

### Slice 2 — including the Q1 boundary enforcement (concrete)

| Layer | What | Approach |
|---|---|---|
| Unit | Inbound emits | `Clinical.save_message(patient, txt, dek, "inbound", "spontaneous")` → `assert_enqueued(worker: AletheaJobs.ClinicalRecordOutboxWorker, args: %{"event" => "patient_message_received", "resource_id" => msg.id, "professional_id" => patient.professional_id})` |
| Unit | **Outbound emits nothing** | `save_message(..., "outbound", "elicited")` → `refute_enqueued(worker: AletheaJobs.ClinicalRecordOutboxWorker)` |
| Integration | **`test "neither outbound call site emits a patient-voice outbox event"`** in `telegram_message_worker_test.exs` — the named Q1 enforcement mechanism | Drive one full safe-path `perform/1` (inbound save + PhiWorker reply + outbound save at L285). Then: `jobs = all_enqueued(worker: AletheaJobs.ClinicalRecordOutboxWorker)`; `assert length(jobs) == 1`; `assert hd(jobs).args["resource_id"] == inbound.id`. Exactly-one + identity-pinned-to-the-inbound-row is strictly stronger than a count delta: it fails both if the outbound save emits and if emission is mis-attributed. Repeat the same assertion in the crisis describe block for L695 (`handle_crisis_path/9`) |
| Regression | Telegram duplicate handling survives the Multi (AD3) | Replay the same `telegram_message_id`; assert `{:error, %Ecto.Changeset{} = cs}` and `Keyword.has_key?(cs.errors, :telegram_message_id)`; assert `SafeReason.for_log(cs) == "[:telegram_message_id]"` (guards the PHI path); assert the failed insert enqueued **no** outbox job (atomicity, AC7) |
| Regression | Atomicity both ways | Force `Oban.insert` failure (invalid args via a stubbed builder) and assert no `Message` row persists |
| Regression | Outbound paths still transactional | Existing `telegram_message_worker_test.exs` rollback tests (~L1260) must pass unmodified — they are the AD2 guard |

**Known Slice-2 test-noise regression:** six existing `save_message/7` call sites use `"inbound"`
(`accounts_test.exs:96,206`, `clinical_record_test.exs:1084`, `source_ref_test.exs:48,88`,
`emotion_analysis_worker_test.exs:121`, `session_timeout_worker_test.exs:62`,
`alethea_demo_process_test.exs:110`) and will now enqueue an outbox job. Worker-filtered
`assert_enqueued`/`refute_enqueued` calls are unaffected; any unfiltered job-count assertion must
call `RagFixtures.clear_pending_outbox!/1`. Run the full `mix test` before slice sign-off.

## Threat Matrix

**N/A** — no routing, shell command, subprocess, VCS/PR automation, executable-file classification,
or process-integration boundary is introduced. `mix alethea.rag.reindex` is an existing
operator-run Mix task; this change extends its *data selection* only (one query, one dispatch
clause) and adds no argument parsing, no shell invocation, and no new switch.

## Migration / Rollout

**No migration, no schema change.** Rollback = revert + one purge:

1. Revert. In-flight `patient_message_received` jobs drain harmlessly — `eligibility/1`'s
   `is_binary` catch-all classifies them `{:unknown, event}` → `:ok`.
2. `DELETE FROM clinical_record_rag_chunks WHERE source_resource_type = 'patient_message';`
   The projection is non-authoritative and fully rebuildable; no clinical source data is touched.
3. Slice 2 reverts independently of Slice 1 (Slice 1 has no live-path caller).

Backfill for existing patients is the already-designed operator path:
`mix alethea.rag.reindex --patient-id <uuid> --confirm` (on-demand only, never scheduled — ADR-003).

## Review Workload Forecast

| Slice | Scope | Est. authored lines (add+del) |
|---|---|---|
| **1** | `Clinical.Outbox` (~35) + Indexer (~20) + reindex task (~25) + label (1) + worker moduledoc (~3) + tests (~240) | **≈ 320** |
| **2** | `save_message/7` Multi conversion (~75 changed) + worker moduledoc (~3) + tests (~185) | **≈ 265** |

Each slice sits under the 400-line budget; a single combined PR (~585) would not. Slice 1 targets
`feat/262-telegram-rag-ingestion`; Slice 2 targets Slice 1's branch (Feature Branch Chain).
`sdd-tasks` owns the formal guard lines.

## Open Questions

- [ ] **AD4 v2 caveat (non-blocking):** `resolve_dek/4` interprets `encryption_version: 2` as
      "clinical-record DEK". For a `Message` that is semantically wrong (messages are always
      patient-DEK). Every in-tree writer leaves the schema default `1`, so this is unreachable
      today and would fail loudly (`{:error, :decryption_failed}` → retry → discard) rather than
      mis-index. If message-level v2 is ever introduced, add an explicit
      `{:cancel, {:unsupported_message_encryption_version, v}}` clause instead.
- [ ] **Q6 follow-up issue** (retention/legal deletion for `patient_message` chunks) must be filed
      before this change closes — documented as an accepted limitation, not an oversight.
- [ ] **Q5 follow-up** (per-voice retrieval balancing) deferred until measurable against real data.
