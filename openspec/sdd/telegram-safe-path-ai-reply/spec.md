# Delta Spec — telegram-safe-path-ai-reply

**Change:** telegram-safe-path-ai-reply (issue #84) | **Store:** hybrid
**Baseline:** no prior `openspec/specs/{domain}/spec.md` exists for these domains — requirements below are ADDED/REMOVED against current runtime behavior (see proposal).

## Domain: telegram-messaging (Safe Path)

### ADDED Requirements

#### Requirement: Safe-Path Reply via Shared PhiWorker Seam
On the non-crisis path, `TelegramMessageWorker` MUST generate the reply via `phi_worker().process/1` (resolved from `Application.get_env(:alethea, :phi_worker, Alethea.AI.PhiWorker)`), not the removed `:ai_llm` seam.

##### Scenario: Safe-path inbound produces AI reply
- GIVEN a non-crisis inbound Telegram message from a known patient
- WHEN the safe path runs
- THEN `phi_worker().process(%{message_id: inbound.id, raw_content: text, patient_context: ctx})` is called
- AND `chain_result.response` becomes the outbound reply content

#### Requirement: PII Sanitization Before External LLM Call
Patient content MUST be sanitized before reaching any external LLM. The worker MUST NOT build its own prompt or call an external LLM directly; it MUST route exclusively through `PhiWorker`.

##### Scenario: No direct external LLM call
- GIVEN the safe path runs
- WHEN the reply is generated
- THEN only `phi_worker().process/1` is invoked; no `build_llm_messages/2` or `AI.llm().chat/2` call exists

#### Requirement: AI Diagnosis Anchored to Inbound Message
On a successful reply, the system MUST persist an AI diagnosis anchored to the inbound message via `Clinical.save_ai_diagnosis(inbound.id, chain_result)`.

##### Scenario: Diagnosis persisted and anchored
- GIVEN `phi_worker().process/1` returns `{:ok, chain_result}`
- WHEN the safe path completes
- THEN a diagnosis row is saved with `source_message_id == inbound.id`

#### Requirement: Persistence Ordering — Save, Diagnose, Then Enqueue
The system MUST save the outbound `Message`, then save the AI diagnosis, and MUST enqueue `TelegramOutboundWorker` only after both saves succeed. A diagnosis-save failure MUST abort the job (fail-loud) before enqueue.

##### Scenario: Happy-path ordering
- GIVEN a successful `chain_result`
- WHEN the safe path completes
- THEN outbound `Message` → diagnosis → `TelegramOutboundWorker` enqueue happen in that order

##### Scenario: Diagnosis save fails — no double-send on retry
- GIVEN the outbound `Message` save succeeded
- WHEN `Clinical.save_ai_diagnosis/2` fails
- THEN the job raises before enqueueing `TelegramOutboundWorker`
- AND an Oban retry does not re-send the message to the patient

#### Requirement: LLM Failure Is Fail-Loud
If `phi_worker().process/1` returns `{:error, reason}`, the worker MUST raise so Oban retries; it MUST NOT deliver a partial or silent reply.

##### Scenario: PhiWorker error path
- GIVEN `phi_worker().process/1` returns `{:error, reason}`
- WHEN the safe path handles the result
- THEN the worker raises and no `Message`, diagnosis, or enqueue occurs

#### Requirement: Crisis Path Non-Regression
`handle_crisis_path/*` and the safe path's `EmotionAnalysisWorker` enqueue MUST remain unchanged by this swap.

##### Scenario: EmotionAnalysisWorker still enqueued
- GIVEN a non-crisis message is processed successfully
- WHEN the safe path completes
- THEN `EmotionAnalysisWorker` is enqueued as before

##### Scenario: Crisis path untouched
- GIVEN a crisis-flagged inbound message
- WHEN the worker processes it
- THEN crisis handling is identical to pre-change behavior; `phi_worker` is never called

#### Requirement: Sentiment Regression Test
The change MUST include a sentiment regression test covering at least one of: (a) `EmotionAnalysisWorker` stays enqueued on the safe path after the PhiWorker swap, or (b) deterministic emotion scores feeding `PhiWorker` via `Clinical.get_message_emotions/1` are pinned. Design selects the concrete form.

##### Scenario: Regression test guards emotion pipeline
- GIVEN the migrated worker test suite
- WHEN the safe-path AI-pipeline test runs
- THEN it asserts the emotion-enrichment feed is unchanged by the PhiWorker swap

## Domain: ai-discovery (Seam Removal & Test Migration)

### REMOVED Requirements

#### Requirement: `:ai_llm` Discovery Seam
(Reason: orphan seam — configured only in `config/test.exs`, unwired in dev/prod, raises outside tests; superseded by the `:phi_worker` seam already used by WhatsApp.)
(Migration: Telegram safe path calls `phi_worker().process/1`. `Alethea.AI.llm/0`, `Alethea.AI.LLM`, `Alethea.AI.LLM.Fake`, the `config/test.exs` `:ai_llm` line, and associated tests are deleted. `:ai_embeddings`, `:ai_whisper`, `Alethea.AI.LLMConfig` are unaffected.)

### ADDED Requirements

#### Requirement: Telegram Worker Tests Use Mox PhiWorkerMock
`test/alethea/jobs/telegram_message_worker_test.exs` MUST drive the AI pipeline exclusively through Mox `Alethea.AI.PhiWorkerMock` (`expect`/`stub` on `process/1`), not raw module doubles or `Application.put_env(:ai_llm, ...)`.

##### Scenario: Mocked success path
- GIVEN `PhiWorkerMock` is stubbed to return `{:ok, chain_result}`
- WHEN the safe-path test runs
- THEN it asserts the persisted `Message`, diagnosis, and enqueue via the mock, with no `ProbeLLM`/`FailingLLM` doubles present

##### Scenario: Mocked failure path
- GIVEN `PhiWorkerMock` is stubbed to return `{:error, :service_unavailable}`
- WHEN the safe-path test runs
- THEN it asserts the worker raises and no downstream persistence/enqueue occurs
