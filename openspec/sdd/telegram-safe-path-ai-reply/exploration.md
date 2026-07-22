# Exploration — telegram-safe-path-ai-reply

**Source issue:** alethea-org/Alethea#84 — "Telegram safe-path: real AI reply via shared AI worker + anchored diagnosis"
**Artifact store:** hybrid (mirrored to Engram `sdd/telegram-safe-path-ai-reply/explore`)
**Strict TDD:** active — test runner `mix test`.

## Current State

`lib/alethea/jobs/telegram_message_worker.ex` safe path (`handle_safe_path/6`, ~lines 157–189):
1. Builds `context` via `Clinical.build_patient_context(legacy_patient, context_limit)` (same helper WhatsApp uses).
2. Builds a hand-rolled 2-message list via private `build_llm_messages/2` (~lines 533–545).
3. Calls `AI.llm().chat(messages, [])` (~line 171) — `AI.llm/0` (`lib/alethea/ai.ex`) resolves `Application.fetch_env!(:alethea, :ai_llm)`.
4. On `{:ok, %{content: reply}}` (non-empty) → `persist_and_enqueue_outbound/6`: saves outbound `Message` via `Clinical.save_telegram_message(..., "outbound", "elicited", nil)` + enqueues `TelegramOutboundWorker`. **No `save_ai_diagnosis` call on this path today** (TODO'd away, comment ~lines 208–212).
5. On empty content or `{:error, reason}` → `raise` a descriptive `RuntimeError` (fail-loud). Oban `max_attempts: 3` retries.

`:ai_llm` is a dead-end seam: `config/test.exs:96` is the ONLY place it's configured (`Alethea.AI.LLM.Fake`); no dev/runtime entry, so `AI.llm()` raises in dev/prod. Telegram worker line 171 is the ONLY production caller. It is one of three parallel v2 discovery slots (`:ai_llm`, `:ai_embeddings`, `:ai_whisper`) in `lib/alethea/ai.ex`; embeddings/whisper are unrelated and MUST be preserved.

## Reference pattern — `AletheaJobs.ProcessMessageWorker` (WhatsApp)

`lib/alethea_jobs/process_message_worker.ex` (`process_clinical_message/4`, ~lines 82–164):
- `phi_worker()` resolves `Application.get_env(:alethea, :phi_worker, Alethea.AI.PhiWorker)` (private fn, line 18).
- Safe path: save inbound → enqueue `EmotionAnalysisWorker` → `Clinical.build_patient_context/2` → `phi_worker().process(%{message_id: inbound.id, raw_content: text, patient_context: ctx})`.
- On `{:ok, chain_result}`: `with {:ok, _outbound} <- Clinical.save_message(..., chain_result.response, ..., "outbound", "elicited", ...), {:ok, _diagnosis} <- Clinical.save_ai_diagnosis(inbound.id, chain_result) do send end` — **exact anchoring pattern to mirror**.
- On `{:error, reason}`: returns `{:error, reason}` → Oban retries. (Telegram convention instead `raise`s; both satisfy fail-loud+retry. Keep Telegram's explicit-raise style — the existing `FailingLLM` test asserts `assert_raise RuntimeError, ~r/service_unavailable/`.)

## `Alethea.AI.PhiWorker` interface (`lib/alethea/ai/phi_worker.ex`)

`@spec process(%{message_id, raw_content, patient_context}) :: {:ok, map()} | {:error, term()}`. Internally: `Sanitizer.sanitize(raw_content)` → enrich `patient_context` with `Clinical.get_message_emotions(message_id)` (returns `""` on not_found) → `GuidedConversationChain.run/1`. Success shape: `%{response, source_message_id, model_version: "phi-4-mini", behavior_type: :elicited}` — **no `extracted_emotions` key**; `Clinical.save_ai_diagnosis/2` defaults it to `%{}` (same as WhatsApp today, compatible).

Test seam: `config/test.exs:37` → `:phi_worker` = `Alethea.AI.PhiWorkerMock`; `Mox.defmock(... for: Alethea.AI.PhiWorkerBehaviour)` in `test/test_helper.exs`. Global static Mox mock; tests use `PhiWorkerMock |> expect(:process, fn ... end)` inline (no `Application.put_env`). Prior art: `test/alethea_jobs/process_message_worker_test.exs:101-114`.

## `:ai_llm` removal blast radius

| File | Reference | Action |
|---|---|---|
| `lib/alethea/jobs/telegram_message_worker.ex:171` (+moduledoc, `build_llm_messages/2`) | `AI.llm().chat(...)` | Replace with `phi_worker().process(...)`; delete `build_llm_messages/2` |
| `lib/alethea/ai.ex` | `def llm, do: configured!(:ai_llm)` + "3 slots" moduledoc | Remove `llm/0`, update moduledoc to 2 slots; keep `embeddings/0`/`whisper/0` |
| `lib/alethea/ai/llm.ex` | `Alethea.AI.LLM` behaviour | Delete file |
| `lib/alethea/ai/llm/fake.ex` | `Alethea.AI.LLM.Fake` | Delete file |
| `config/test.exs:96` | `:ai_llm` config | Delete line (keep embeddings/whisper) |
| `test/alethea/ai_test.exs` | 2 `llm/0` tests | Delete those 2; keep embeddings/whisper |
| `test/alethea/ai/llm_test.exs` | whole file | Delete |
| `test/alethea/ai/adapter_discovery_test.exs` | 1 `:ai_llm` test | Delete that test; keep others |
| `test/alethea/jobs/telegram_message_worker_test.exs` | `ProbeLLM`/`FailingLLM` (lines 52-67), `Application.put_env(:ai_llm,...)` setup (line 78) + 3 tests (242/323/354) | Migrate to `PhiWorkerMock` expect/stub; remove `:ai_llm` env writes; delete Probe/Failing |
| `test/alethea/ai/llm_config_test.exs` | `Alethea.AI.LLMConfig` (legacy v1, used by chains) | **DO NOT TOUCH** — different module |
| `openspec/adr/001-llm-en-groq.md` | frames `Alethea.AI.LLM` as the stable Groq interface | Doc drift — real role is `LLMConfig`/`GuidedConversationChain`; propose/design should note so ADR isn't left stale |

`:ai_embeddings`/`:ai_whisper` and their Fakes/tests untouched. No other production caller of `AI.llm/0` found via full-repo Grep.

## Unaffected / confirmed stays

- `TelegramOutboundWorker` + `:telegram_client` seam — only consumes `body` string; orthogonal.
- `enqueue_emotion_analysis(inbound.id, hash_prefix)` (~line 136) — fires before crisis/safe branch on every bound message; not touched.
- Crisis path (`handle_crisis_path` ~line 429, `save_ai_diagnosis` ~line 446) — untouched; crisis is the only current `save_ai_diagnosis` caller in this file.

## Open decisions for sdd-propose / sdd-design (not blocking)

1. **Safe-path diagnosis ordering / partial-failure semantics**: mirror WhatsApp's `with` chain (outbound save → diagnosis save → both must succeed before enqueue), or explicitly decide behavior if diagnosis save fails after outbound already persisted.
2. **"Sentiment regression test" definition**: CLAUDE.md mandates one for every AI pipeline change. Likely a Telegram safe-path test asserting `EmotionAnalysisWorker` stays enqueued and/or pinning deterministic emotion scores feeding `PhiWorker`. Name it in propose/design.

## Risks

- Test migration precision: 3 tests + 1 setup line move from raw module doubles (`ProbeLLM`/`FailingLLM` implementing `Alethea.AI.LLM`) to Mox `PhiWorkerMock` with a DIFFERENT arg shape (`%{message_id, raw_content, patient_context}` map, not `[message()]` list). Assertions on message-list shape must be rewritten. Crisis "LLM NOT invoked" test needs no explicit assertion change — Mox `verify_on_exit!` already fails on any unexpected `process/1` call; just remove Probe/put_env.
- Diagnosis anchoring is NEW behavior on safe path — needs its own tests; mirror WhatsApp `with` ordering.
- Pre-existing drift (optional one-line fixes, not introduced here): `PhiWorkerBehaviour.process/1` `@callback :: map()` doesn't match actual `{:ok,_}|{:error,_}`; ADR-001 references the unused `:ai_llm` stub.
- Emotion-context race inherited from WhatsApp (get_message_emotions usually returns `""` because EmotionAnalysisWorker is enqueued, not inline) — NOT a regression.

## Recommendation

**Approach 1 — direct substitution.** Replace `AI.llm().chat` with `phi_worker().process(...)`, add `phi_worker/0` helper (mirror WhatsApp), delete `build_llm_messages/2`, add `save_ai_diagnosis(inbound.id, chain_result)`, delete the `:ai_llm` seam entirely (module/config/tests). Mostly deletions; well under the 400-line budget. Rejected Approach 2 (wrap PhiWorker behind `:ai_llm`) — contradicts the acceptance criterion and keeps a redundant discovery layer with a mismatched contract.

**Ready for proposal:** yes.
