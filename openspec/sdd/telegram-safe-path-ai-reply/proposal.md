# Proposal — telegram-safe-path-ai-reply

**Source issue:** alethea-org/Alethea#84 — "Telegram safe-path: real AI reply via shared AI worker + anchored diagnosis"
**Artifact store:** hybrid (mirrored to Engram `sdd/telegram-safe-path-ai-reply/proposal`)
**Strict TDD:** active — test runner `mix test`.
**Depends on exploration:** `openspec/sdd/telegram-safe-path-ai-reply/exploration.md` (Engram `sdd/telegram-safe-path-ai-reply/explore`).

## Intent

**Problem.** The Telegram inbound safe path produces AI replies through a hand-rolled,
dead-end seam. `handle_safe_path/6` builds a 2-message prompt via `build_llm_messages/2`
and calls `AI.llm().chat(messages, [])`. That `:ai_llm` slot is configured in exactly one
place (`config/test.exs:96` → `Alethea.AI.LLM.Fake`); there is no dev or prod wiring, so in
any non-test environment `AI.llm/0` raises. The Telegram worker is the ONLY production caller
of that seam. Result: the Telegram channel cannot generate a real clinical reply, it bypasses
the project's mandatory PII sanitization + emotion-enrichment pipeline, and — unlike WhatsApp —
it persists **no AI diagnosis**, so the safe-path reply is not source-anchored to the inbound
patient message (violating the "source anchoring" AI standard).

**Why now.** Issue #84 is the safe-path completion for the Telegram channel. WhatsApp
(`AletheaJobs.ProcessMessageWorker`) already routes through the shared, sanitizing
`Alethea.AI.PhiWorker` via the `:phi_worker` app-env seam and anchors a diagnosis to the
inbound message. Telegram must reach clinical parity so both channels feed the same
governed AI pipeline and the same source-anchored clinical record. Leaving the orphan
`:ai_llm` seam in place is also an active liability: it is an unwired, unsanitized code path
that would raise in production and duplicates a discovery layer that already exists.

**Success looks like.**
1. A safe-path Telegram message produces a real AI reply through `Alethea.AI.PhiWorker`
   (PII-sanitized, emotion-enriched, `GuidedConversationChain`-generated), identical in
   governance to the WhatsApp path.
2. Each safe-path reply persists an AI diagnosis anchored to the inbound patient message via
   `Clinical.save_ai_diagnosis(inbound.id, chain_result)`.
3. The orphan `:ai_llm` seam (module, config, tests) is fully removed; `:ai_embeddings`,
   `:ai_whisper`, and the legacy `Alethea.AI.LLMConfig` remain untouched.
4. The Telegram worker test suite drives the AI pipeline through the Mox
   `Alethea.AI.PhiWorkerMock` seam, not raw module doubles + `Application.put_env`.

## Scope

### In scope

- **Route the safe path through `phi_worker()`.** In `lib/alethea/jobs/telegram_message_worker.ex`,
  replace `AI.llm().chat(messages, [])` with
  `phi_worker().process(%{message_id: inbound.id, raw_content: text, patient_context: ctx})`,
  mirroring `AletheaJobs.ProcessMessageWorker`. Add a private `phi_worker/0` helper resolving
  `Application.get_env(:alethea, :phi_worker, Alethea.AI.PhiWorker)`.
- **Anchor a diagnosis on the safe path.** Add `Clinical.save_ai_diagnosis(inbound.id, chain_result)`
  (NEW behavior for the Telegram safe path today).
- **Persistence ordering (resolved product decision — see below):** save outbound `Message` →
  save AI diagnosis → ONLY THEN enqueue `TelegramOutboundWorker`.
- **Delete `build_llm_messages/2`** — the hand-rolled prompt builder is subsumed by PhiWorker's
  internal `GuidedConversationChain`.
- **Remove the `:ai_llm` seam ENTIRELY:**
  - `Alethea.AI.llm/0` and its "3 slots" moduledoc framing in `lib/alethea/ai.ex` (reduce to 2 slots).
  - `lib/alethea/ai/llm.ex` (`Alethea.AI.LLM` behaviour) — delete file.
  - `lib/alethea/ai/llm/fake.ex` (`Alethea.AI.LLM.Fake`) — delete file.
  - `config/test.exs:96` (`:ai_llm` config line) — delete.
  - `test/alethea/ai_test.exs` — delete the 2 `llm/0` tests (keep embeddings/whisper).
  - `test/alethea/ai/llm_test.exs` — delete whole file.
  - `test/alethea/ai/adapter_discovery_test.exs` — delete the 1 `:ai_llm` test (keep others).
- **Migrate `test/alethea/jobs/telegram_message_worker_test.exs`** from raw `ProbeLLM`/`FailingLLM`
  doubles + `Application.put_env(:ai_llm, ...)` to the Mox `Alethea.AI.PhiWorkerMock` seam
  (`expect`/`stub` inline; drop the Probe/Failing modules and env writes).
- **Add the mandated sentiment regression test** for this AI-pipeline change (concrete shape
  deferred to spec/design — see "Open decision" below).

### Out of scope (explicit non-goals)

- **Session lifecycle** (issue #85) — no `SessionManager`, no `session.id` on the Telegram path.
- **Session summaries.**
- **Inbound↔outbound FK / `reply_to_message_id`** — the traceability link stays as-is (recorded
  via job args, not a schema FK). No `Message` schema change.
- **Dashboard surfacing** of the new diagnosis.
- **Crisis path** (`handle_crisis_path`), the `EmotionAnalysisWorker` enqueue, and
  `TelegramOutboundWorker` / `:telegram_client` seam — all untouched.
- **`:ai_embeddings`, `:ai_whisper`, and `Alethea.AI.LLMConfig`** — MUST be preserved
  (LLMConfig is the legacy v1 module used by the chains — a DIFFERENT module from the deleted
  `Alethea.AI.LLM`). Do NOT touch `test/alethea/ai/llm_config_test.exs`.
- **Fixing pre-existing doc drift.** `ADR-001` (`openspec/adr/001-llm-en-groq.md`) frames the
  removed `Alethea.AI.LLM` as the stable Groq interface; its real role is
  `LLMConfig`/`GuidedConversationChain`. Note that ADR-001 **should be reconciled**, but do NOT
  fix it in this change. Likewise the pre-existing `PhiWorkerBehaviour.process/1` `@callback ::
  map()` vs actual `{:ok, _} | {:error, _}` mismatch is not introduced here and not fixed here.

## Approach

### Approach 1 — direct substitution (SELECTED)

Swap the orphan seam for the shared, governed one in place, then delete the orphan. This is
almost entirely deletions plus a small substitution well under the 400-line budget.

1. Add private `phi_worker/0` to `TelegramMessageWorker` (mirror WhatsApp's line 18).
2. In `handle_safe_path/6`: keep the existing `build_patient_context/2` step (unchanged), then
   replace the `messages = build_llm_messages(...)` + `AI.llm().chat(...)` block with
   `phi_worker().process(%{message_id: inbound.id, raw_content: text, patient_context: ctx})`.
3. Keep Telegram's fail-loud **`raise`** convention on `{:error, reason}` (WhatsApp returns
   `{:error, _}`; both satisfy fail-loud + Oban retry, and the existing test asserts
   `assert_raise RuntimeError, ~r/service_unavailable/`). The empty-content branch is subsumed:
   PhiWorker returns `{:ok, chain_result}` with a `response`; adapt the empty guard to
   `chain_result.response` or drop it per design.
4. In the success branch, apply the resolved ordering: `save_telegram_message(... "outbound"
   "elicited" nil)` → `Clinical.save_ai_diagnosis(inbound.id, chain_result)` → `enqueue_outbound(...)`.
   Wrap in a `with` so a diagnosis-save failure aborts BEFORE enqueue (fail-loud → retry).
5. Delete `build_llm_messages/2`, remove the `alias Alethea.AI`, and update the moduledoc
   step 7 wording (`Alethea.AI.llm().chat/2` → PhiWorker).
6. Delete the `:ai_llm` seam files/config/tests listed in scope; trim `lib/alethea/ai.ex` to two
   slots.
7. Rewrite the migrated worker tests against `PhiWorkerMock` (`process/1` map arg shape).

**Resolved product decision — safe-path persistence ordering (partial-failure semantics).**
Order is: **save outbound `Message` → save AI diagnosis → ONLY THEN enqueue
`TelegramOutboundWorker`.** Persisting the diagnosis BEFORE enqueuing the outbound delivery
makes Oban retries safe (a retry after a mid-step crash re-runs deterministic DB saves rather
than re-sending a message the patient already received) while preserving the clinical
source-anchor. This is chosen OVER mirroring WhatsApp's send-then-diagnose ordering, which
risks a double-send on retry. Telegram outbound is ALREADY async via the `:telegram_outbound`
queue, so moving the diagnosis save ahead of the enqueue adds no patient-perceived latency.

### Approach 2 — wrap PhiWorker behind `:ai_llm` (REJECTED)

Keep the `:ai_llm` discovery slot and make its adapter delegate to PhiWorker. Rejected: it
contradicts the acceptance criterion (remove the orphan seam), keeps a redundant discovery layer
with a contract (`chat/2` list-shape) that mismatches PhiWorker's `process/1` map-shape, and
leaves the unwired-in-prod liability in place.

## Affected areas

| Area | File | Change |
|---|---|---|
| Telegram worker | `lib/alethea/jobs/telegram_message_worker.ex` | Add `phi_worker/0`; rewrite `handle_safe_path/6` to call `phi_worker().process/1`; add `save_ai_diagnosis`; reorder save→diagnose→enqueue; delete `build_llm_messages/2`; drop `alias Alethea.AI`; moduledoc step 7 |
| AI discovery | `lib/alethea/ai.ex` | Remove `llm/0`; moduledoc 3→2 slots; keep `embeddings/0`/`whisper/0` |
| LLM behaviour | `lib/alethea/ai/llm.ex` | Delete file |
| LLM fake | `lib/alethea/ai/llm/fake.ex` | Delete file |
| Test config | `config/test.exs:96` | Delete `:ai_llm` line (keep embeddings/whisper) |
| AI test | `test/alethea/ai_test.exs` | Delete 2 `llm/0` tests |
| LLM test | `test/alethea/ai/llm_test.exs` | Delete file |
| Adapter discovery test | `test/alethea/ai/adapter_discovery_test.exs` | Delete 1 `:ai_llm` test |
| Telegram worker test | `test/alethea/jobs/telegram_message_worker_test.exs` | Migrate `ProbeLLM`/`FailingLLM` + `put_env(:ai_llm)` → `PhiWorkerMock`; add diagnosis-anchor tests + sentiment regression test |
| **Preserve (do NOT touch)** | `test/alethea/ai/llm_config_test.exs`, `:ai_embeddings`/`:ai_whisper` + fakes/tests | Unchanged |
| Doc drift (note only) | `openspec/adr/001-llm-en-groq.md` | Flag for reconcile; do NOT edit here |

## Risks / open questions

- **Test-migration precision (primary risk).** 3 tests + 1 setup line move from raw module
  doubles (`ProbeLLM`/`FailingLLM` implementing the list-shape `Alethea.AI.LLM.chat/2`) to Mox
  `PhiWorkerMock` with a DIFFERENT arg shape (`%{message_id, raw_content, patient_context}` map,
  not `[message()]`). Every assertion on message-list shape must be rewritten. The crisis
  "LLM NOT invoked" test needs no explicit assertion change — Mox `verify_on_exit!` fails on any
  unexpected `process/1` call; just remove Probe + `put_env`.
- **New behavior needs new tests.** Diagnosis anchoring on the safe path is new — add tests
  asserting `save_ai_diagnosis(inbound.id, ...)` runs, and that a diagnosis-save failure aborts
  BEFORE `enqueue_outbound` (partial-failure ordering).
- **PhiWorker success shape has no `extracted_emotions` key.** `%{response, source_message_id,
  model_version, behavior_type: :elicited}`; `Clinical.save_ai_diagnosis/2` defaults it to `%{}`
  (same as WhatsApp today — compatible).
- **Inherited emotion-context race (NOT a regression).** `get_message_emotions/1` usually returns
  `""` because `EmotionAnalysisWorker` is enqueued async, not run inline — identical to WhatsApp.
- **Pre-existing doc drift left in place** (ADR-001 → `:ai_llm`; `PhiWorkerBehaviour.process/1`
  `@callback` spec mismatch). Noted, not fixed here.

### Open decision for sdd-spec / sdd-design

- **Concrete definition of the mandated "sentiment regression test."** CLAUDE.md requires a
  sentiment regression test for every AI-pipeline change. Candidate shapes (pick in spec/design):
  (a) assert `EmotionAnalysisWorker` stays enqueued on the safe path after the PhiWorker swap
  (guards the emotion-enrichment feed), and/or (b) pin deterministic emotion scores feeding
  `PhiWorker` (via `Clinical.get_message_emotions/1`) so the enriched context is regression-locked.

## Out of scope (summary)

Session lifecycle (#85), session summaries, inbound↔outbound FK, dashboard surfacing, ADR-001
fix (reconcile flagged, not done here), `PhiWorkerBehaviour` spec fix, and any change to
`:ai_embeddings` / `:ai_whisper` / `Alethea.AI.LLMConfig`.

## Next

Ready for `sdd-spec` and `sdd-design` (can run in parallel). The one product decision (safe-path
ordering) is resolved and encoded above; the only open item is the concrete sentiment-regression
test shape, deferred to spec/design.
