# Design — telegram-safe-path-ai-reply

**Source issue:** alethea-org/Alethea#84
**Approach:** 1 — direct substitution (selected in proposal)
**Artifact store:** hybrid (mirrored to Engram `sdd/telegram-safe-path-ai-reply/design`)
**Strict TDD:** active — test runner `mix test`.
**Inputs:** `proposal.md`, `exploration.md`, project skill `langchain-elixir`.

## 1. Architecture approach

No new architectural layer. This change **collapses one seam onto an existing,
governed one**. The Telegram inbound Oban worker (`Alethea.Jobs.TelegramMessageWorker`)
stops being a special-case AI caller (its own `AI.llm().chat/2` orphan seam) and
becomes a second consumer of the same `:phi_worker` port that the WhatsApp worker
(`AletheaJobs.ProcessMessageWorker`) already uses. Both channels then converge on
one port → one adapter → one sanitizing/emotion-enriching chain:

```
inbound (WhatsApp)  ─┐
                     ├─► phi_worker() ──► Alethea.AI.PhiWorker.process/1
inbound (Telegram)  ─┘        (port: :phi_worker, default Alethea.AI.PhiWorker)
                                   │  Sanitizer.sanitize → get_message_emotions
                                   │  enrich context → GuidedConversationChain.run
                                   ▼
                             {:ok, %{response, source_message_id, model_version,
                                     behavior_type: :elicited}} | {:error, term}
```

Pattern: **Ports & Adapters (hexagonal)** — the project's established pattern.
`phi_worker/0` is the port lookup (`Application.get_env(:alethea, :phi_worker,
Alethea.AI.PhiWorker)`), identical to WhatsApp line 18. Tests bind the port to the
Mox `Alethea.AI.PhiWorkerMock` (already configured `config/test.exs:37`,
`Mox.defmock … for: Alethea.AI.PhiWorkerBehaviour` in `test/test_helper.exs`).

The `:ai_llm` "v2 discovery slot" is deleted entirely; the parallel `:ai_embeddings`
and `:ai_whisper` slots and the **separate** legacy `Alethea.AI.LLMConfig` module are
untouched. `Alethea.AI` drops from a 3-slot to a 2-slot discovery surface.

## 2. Component map & data flow

### 2.1 Rewritten `handle_safe_path/6` (lib/alethea/jobs/telegram_message_worker.ex)

Keep the existing `build_patient_context/2` step; replace the message-building +
`AI.llm().chat` block with a `phi_worker().process/1` call; move persistence into a
`with`-guarded helper that enforces the RESOLVED ordering.

```elixir
defp handle_safe_path(foundation_patient, chat_id, chat_id_hash, hash_prefix, inbound, text) do
  context_limit =
    Application.get_env(:alethea, Alethea.Clinical, [])[:recent_message_limit] || 10

  {:ok, legacy_patient} = FoundationAccounts.legacy_patient(foundation_patient)

  context =
    case Clinical.build_patient_context(legacy_patient, context_limit) do
      {:ok, ctx} -> ctx
      {:error, _reason} -> ""
    end

  case phi_worker().process(%{
         message_id: inbound.id,
         raw_content: text,
         patient_context: context
       }) do
    {:ok, %{response: reply} = chain_result}
    when is_binary(reply) and reply != "" ->
      persist_and_enqueue_outbound(
        foundation_patient,
        chat_id,
        chat_id_hash,
        hash_prefix,
        chain_result,
        inbound.id
      )

    {:ok, %{response: _empty}} ->
      raise "TelegramMessageWorker: PhiWorker returned empty response " <>
              "(hash_prefix=#{hash_prefix})"

    {:error, reason} ->
      raise "TelegramMessageWorker: PhiWorker error: #{inspect(reason)} " <>
              "(hash_prefix=#{hash_prefix})"
  end
end
```

`phi_worker/0` helper (mirror WhatsApp line 18), placed near the top of the module:

```elixir
defp phi_worker, do: Application.get_env(:alethea, :phi_worker, Alethea.AI.PhiWorker)
```

### 2.2 Persistence helper — RESOLVED ordering (save outbound → save diagnosis → enqueue)

`persist_and_enqueue_outbound/6` now receives the whole `chain_result` (not just the
reply string) so `save_ai_diagnosis/2` can read `:response`, `:model_version`,
`:extracted_emotions`. The `with` chain guarantees the diagnosis is committed BEFORE
the outbound delivery is enqueued; any failure of either DB save aborts (fail-loud
`raise`) **before** `enqueue_outbound/6`:

```elixir
defp persist_and_enqueue_outbound(
       foundation_patient,
       chat_id,
       chat_id_hash,
       hash_prefix,
       chain_result,
       inbound_message_id
     ) do
  reply = chain_result.response

  with {:ok, outbound} <-
         Clinical.save_telegram_message(
           foundation_patient,
           reply,
           "outbound",
           "elicited",
           nil
         ),
       {:ok, _diagnosis} <-
         Clinical.save_ai_diagnosis(inbound_message_id, chain_result) do
    enqueue_outbound(chat_id_hash, chat_id, outbound.id, reply, hash_prefix,
      patient_id: foundation_patient.id
    )

    :ok
  else
    {:error, reason} ->
      raise "TelegramMessageWorker: failed to persist AI reply/diagnosis " <>
              "(reason=#{inspect(reason)}, hash_prefix=#{hash_prefix})"
  end
end
```

Data-flow ordering per invocation (safe path):

1. `save_telegram_message(foundation_patient, reply, "outbound", "elicited", nil)`
   → outbound `Message` row (source-of-record for what the patient will receive).
2. `Clinical.save_ai_diagnosis(inbound.id, chain_result)` → `ai_diagnoses` row
   **anchored to the inbound patient message** (`message_id: inbound.id`) — the NEW
   source-anchoring behavior. `save_ai_diagnosis/2` defaults `extracted_emotions` to
   `%{}` because PhiWorker's success map has no such key (compatible with WhatsApp).
3. `enqueue_outbound/6` → `TelegramOutboundWorker` on `:telegram_outbound`
   (`lane: :safe`) — the ONLY step that triggers a patient-visible send.

Because (3) is last and is itself async, a crash in (1) or (2) never enqueues a send;
a retry cannot double-send. This is the resolved product decision (chosen over
WhatsApp's send-then-diagnose ordering, which risks a double-send on retry).

### 2.3 Deletions in the worker

- `build_llm_messages/2` (lines ~533–545) — subsumed by PhiWorker's internal
  `GuidedConversationChain`.
- `alias Alethea.AI` (line 70) — no longer referenced.
- Moduledoc step 7 wording: `Alethea.AI.llm().chat/2` → "route through
  `Alethea.AI.PhiWorker` (PII-sanitized, emotion-enriched) and anchor an
  `ai_diagnosis` to the inbound message".

## 3. Error / fail-loud handling

| Condition | PhiWorker returns | Telegram worker action |
|---|---|---|
| Success, non-empty reply | `{:ok, %{response: r, ...}}`, `r != ""` | persist → diagnose → enqueue → `:ok` |
| Success, empty reply | `{:ok, %{response: ""}}` | `raise RuntimeError` (empty-response guard) |
| Pipeline error | `{:error, reason}` | `raise RuntimeError` with `inspect(reason)` |
| Outbound/diagnosis save error | — (DB) | `with … else` → `raise RuntimeError` |

- **Keep Telegram's `raise` convention** on `{:error, reason}` (WhatsApp returns
  `{:error, _}`; both are fail-loud + Oban-retry-eligible). The migrated test asserts
  `assert_raise RuntimeError, ~r/service_unavailable/`, so the error string must still
  interpolate the reason.
- **Empty-content guard.** The prior seam returned `%{content: reply}`; PhiWorker
  returns `%{response: reply}`. DECISION: **keep** a defensive empty-response guard
  (Telegram's stricter fail-loud convention) matched on `chain_result.response`. This
  is deliberately stricter than WhatsApp (which sends whatever `response` is) because
  an empty Telegram reply would otherwise persist an empty outbound `Message` and
  enqueue an empty send. Cost is one extra `case` clause; benefit is a loud failure +
  retry instead of a silent empty delivery. (Alternative — drop the guard to mirror
  WhatsApp — rejected: it removes an existing safety property for no gain.)

## 4. `:ai_llm` removal plan

Delete the orphan seam entirely. Blast radius (all confirmed in exploration; no other
production caller of `AI.llm/0` exists):

| File | Action |
|---|---|
| `lib/alethea/jobs/telegram_message_worker.ex` | `phi_worker/0` added; `handle_safe_path/6` rewritten; `build_llm_messages/2` + `alias Alethea.AI` deleted; moduledoc step 7 updated |
| `lib/alethea/ai.ex` | Delete `llm/0` + its `@doc`/`@spec`; moduledoc "three slots" → "two slots" (drop the `:ai_llm` bullet + the `{llm,…}` fake path reference). **Keep** `embeddings/0`, `whisper/0`, and the shared `configured!/1` helper |
| `lib/alethea/ai/llm.ex` (`Alethea.AI.LLM` behaviour) | Delete file |
| `lib/alethea/ai/llm/fake.ex` (`Alethea.AI.LLM.Fake`) | Delete file |
| `config/test.exs:96` (`config :alethea, :ai_llm, …`) | Delete line |
| `test/alethea/ai_test.exs` | Delete the 2 `llm/0` tests; keep embeddings/whisper tests |
| `test/alethea/ai/llm_test.exs` | Delete whole file |
| `test/alethea/ai/adapter_discovery_test.exs` | Delete the single `:ai_llm` test; keep the rest |

**Preservation guarantee (must remain byte-for-byte untouched):**
`config/test.exs:37` (`:phi_worker`), `config/test.exs:97-98` (`:ai_embeddings`,
`:ai_whisper`), `lib/alethea/ai/embeddings*`, `lib/alethea/ai/whisper*`, and
`Alethea.AI.LLMConfig` + `test/alethea/ai/llm_config_test.exs`. `LLMConfig` is the
legacy v1 module used by the chains — a DIFFERENT module from the deleted
`Alethea.AI.LLM`; do not touch it.

Verification step (design-mandated, run before commit): after deletion,
`rg "ai_llm|Alethea\.AI\.LLM([^C]|$)|AI\.llm\(" lib test config` must return zero hits
(the `[^C]` guard excludes `LLMConfig`).

## 5. Test-double migration design

### 5.1 Remove raw doubles, bind the Mox port

Delete `ProbeLLM` and `FailingLLM` module doubles (list-shape `Alethea.AI.LLM.chat/2`)
and the `Application.put_env(:alethea, :ai_llm, …)` setup line + per-test overrides.
Drive the pipeline through the already-configured `Alethea.AI.PhiWorkerMock`
(map-shape `process/1`). Mox is already imported and `verify_on_exit!` is already in
`setup`. Prior art: `test/alethea_jobs/process_message_worker_test.exs:101-114`.

### 5.2 Per-test expectations

- **Happy path** — replace the "calls the LLM via `AI.llm().chat/2`" test. Assert the
  worker calls the port with the correct **map** shape and inbound anchor:

  ```elixir
  Alethea.AI.PhiWorkerMock
  |> expect(:process, fn %{message_id: mid, raw_content: ^text, patient_context: ctx} ->
    assert is_binary(mid)
    assert is_binary(ctx)
    {:ok, %{
      response: "respuesta clínica",
      source_message_id: mid,
      model_version: "phi-4-mini",
      behavior_type: :elicited
    }}
  end)
  ```

  Every prior assertion on `{:llm_called, messages}` / `is_list(messages)` /
  `%{role: :user}` is **rewritten** to the map shape above (primary migration risk).

- **NEW — diagnosis anchoring.** After a happy-path perform, assert an `ai_diagnoses`
  row exists with `message_id == inbound.id`, `model_version == "phi-4-mini"`,
  `ai_response == "respuesta clínica"` (mirror the crisis-diagnosis assertions already
  in the file, but on the safe path).

- **NEW — partial-failure ordering.** Stub `PhiWorkerMock` to return a valid
  `{:ok, %{response: …}}`, then force `Clinical.save_ai_diagnosis/2` to fail (e.g.
  point `message_id` at a non-existent FK via a stubbed chain_result, OR — cleaner —
  assert the ordering structurally: after a successful perform, exactly one
  `TelegramOutboundWorker` job is enqueued AND one diagnosis row exists; and in a
  diagnosis-failure variant, assert `assert_raise` and `refute_enqueued(worker:
  TelegramOutboundWorker)`). Design preference: the `refute_enqueued`-on-diagnosis-
  failure assertion is the direct proof that enqueue happens strictly after a
  successful diagnosis save.

- **Error path** — replace `FailingLLM`:

  ```elixir
  Alethea.AI.PhiWorkerMock
  |> expect(:process, fn _ -> {:error, :service_unavailable} end)

  assert_raise RuntimeError, ~r/service_unavailable/, fn ->
    TelegramMessageWorker.perform(%Oban.Job{args: args})
  end
  refute_enqueued(worker: TelegramOutboundWorker)
  ```

- **Crisis "LLM NOT invoked" test** — needs **no explicit assertion change**. Mox
  `verify_on_exit!` fails the test on any unexpected `process/1` call, so simply
  removing `ProbeLLM` + the `refute_received {:llm_called, _}` line (and NOT setting an
  `expect`/`stub` on `PhiWorkerMock`) makes the crisis path's "must not call the AI
  pipeline" contract self-enforcing. (Optionally keep an explicit
  `PhiWorkerMock |> expect(:process, 0, fn _ -> … end)` for readability, but it is
  redundant with `verify_on_exit!`.)

## 6. RESOLVED — the mandated "sentiment regression test"

**Decision: assert `EmotionAnalysisWorker` is still enqueued on the safe path after
the PhiWorker swap, keyed on the inbound message id, and assert the same inbound id is
the `message_id` PhiWorker is called with.**

Concrete form (single deterministic test in the safe-path describe block):

```elixir
test "safe path still feeds the sentiment pipeline (regression): enqueues " <>
     "EmotionAnalysisWorker for the inbound message and passes its id to PhiWorker",
     ctx do
  Alethea.AI.PhiWorkerMock
  |> expect(:process, fn %{message_id: mid} ->
    # PhiWorker's get_message_emotions/1 enrichment is keyed on this id.
    {:ok, %{response: "ok", source_message_id: mid,
            model_version: "phi-4-mini", behavior_type: :elicited}}
  end)

  args = build_args("hola, buen día", telegram_message_id: 310, telegram_update_id: 31)
  assert :ok = TelegramMessageWorker.perform(%Oban.Job{args: args})

  inbound = Repo.one(from m in Message, where: m.direction == "inbound")
  assert_enqueued(worker: EmotionAnalysisWorker, args: %{message_id: inbound.id})
end
```

**What it asserts and why it guards against sentiment regression.**
The sentiment feed the *Telegram worker owns* is `enqueue_emotion_analysis(inbound.id,
…)` → `EmotionAnalysisWorker` (RoBERTa) → persists an `EmotionAnalysis` row keyed on
`inbound.id`. PhiWorker's `get_message_emotions(message_id)` later reads exactly that
row to emotion-enrich the LLM context. The test locks TWO invariants the swap could
silently break: (a) the emotion-analysis job is still enqueued for the correct message
after replacing the AI call, and (b) the worker still passes `inbound.id` (not a
foundation/legacy id) as `message_id` to `phi_worker().process/1`, so the enrichment
lookup and the diagnosis anchor share one source id. Determinism comes from Oban
testing mode (`assert_enqueued`) and the inline `PhiWorkerMock` — no RoBERTa/HTTP call.

**Why not deep score-pinning at this layer.** The candidate "pin emotion scores that
`get_message_emotions/1` reads" only exercises code *inside* `Alethea.AI.PhiWorker`,
which is mocked out at the worker boundary. That enrichment path is PhiWorker's own
unit-test responsibility (`test/alethea/ai/…`), and duplicating it here would assert
nothing about the Telegram worker. The chosen id-linkage test is the correct,
non-redundant sentiment guard for THIS module. (If deeper coverage is later desired,
add it as a PhiWorker unit test that inserts a deterministic `EmotionAnalysis` row and
asserts the enriched context — out of scope for #84.)

## 7. Idempotency / retry semantics under the new ordering

- **Primary win — no double-send.** `enqueue_outbound/6` is the last step and runs
  only after both DB saves succeed. A crash anywhere in steps 1–2 (§2.2) enqueues no
  send; an Oban retry (`max_attempts: 3`) cannot re-deliver a message the patient
  already received. This is the resolved-ordering guarantee.
- **Diagnosis is committed before delivery is scheduled**, so the clinical
  source-anchor never lags the patient-visible reply.
- **Known pre-existing limitation (NOT introduced here).** The worker is not fully
  idempotent across a *completed-inbound* retry: `{:ok, inbound} =
  Clinical.save_telegram_message(…, "inbound", …)` uses the `telegram_message_id`
  partial-unique index, so if a prior attempt already committed the inbound row, a
  retry hits a duplicate and raises `MatchError` before reaching the safe path (this
  is exactly what the existing "inbound persistence failure raises" test pins). Net:
  the ordering makes *delivery* retry-safe, but a retry after the inbound already
  committed will fail loud rather than resume and re-save the diagnosis/outbound. The
  practical exposure window between the diagnosis save and the enqueue is two fast
  local DB ops in one invocation. Hardening (wrap outbound-save + diagnosis-save in a
  single `Repo.transaction/1`, or make inbound-save idempotent) is a future
  improvement, explicitly out of scope for #84.

## 8. ADR-style decisions

- **ADR-D1 — Route Telegram safe path through the `:phi_worker` port (not a wrapped
  `:ai_llm`).** Rationale: one governed, sanitizing, emotion-enriching pipeline for
  both channels; removes an unwired-in-prod, unsanitized seam. Rejected: Approach 2
  (adapter behind `:ai_llm`) — keeps a redundant discovery layer whose `chat/2`
  list-contract mismatches PhiWorker's `process/1` map-contract, and contradicts the
  acceptance criterion to delete the orphan.
- **ADR-D2 — Persistence ordering: save outbound → save diagnosis → enqueue.**
  Rationale: retry-safety (no double-send) + source-anchor never lags delivery.
  Rejected: WhatsApp's send-then-diagnose ordering (double-send risk on retry).
- **ADR-D3 — Keep Telegram's fail-loud `raise` on `{:error, _}` and on empty
  response.** Rationale: preserves the existing loud-failure + Oban-retry contract and
  the `assert_raise RuntimeError` test; empty-response guard prevents silent empty
  deliveries. Rejected: returning `{:error, _}` like WhatsApp (would break the
  existing raise-based test and Telegram's stricter convention).
- **ADR-D4 — Sentiment regression = emotion-analysis-enqueue + message-id-linkage
  assertion** (see §6). Rationale: guards the sentiment invariants the worker actually
  owns, deterministically, without duplicating PhiWorker-internal coverage.

**Out of scope (reference only, do NOT author fixes here):**
`openspec/adr/001-llm-en-groq.md` frames the removed `Alethea.AI.LLM` as the stable
Groq interface; its real role is `LLMConfig`/`GuidedConversationChain`. ADR-001
**should be reconciled** in a follow-up, but this change does not edit it. Likewise the
pre-existing `PhiWorkerBehaviour.process/1` `@callback … :: map()` vs actual
`{:ok, _} | {:error, _}` spec mismatch is neither introduced nor fixed here.

## 9. Ready for `sdd-tasks`

Design is complete; the single open decision (sentiment-regression test shape) is
resolved above. Spec (in parallel) + this design are the inputs to task breakdown.
