# Issue 392 — Deliver bounded, guarded journaling replies

## Objective

Telegram replies acknowledge the patient's experience and stay within the journaling role instead of becoming therapy or general-purpose assistance: structured instructions, role-preserving bounded history, full sanitization, validated output with a safe fallback, bounded length.

Reference: https://github.com/alethea-org/Alethea/issues/392 (parent spec #389, stories 1-3, 10-16, 19, 32).

Branch: `feat/392-guarded-journaling-replies` (worktree, branched from `origin/main` @ d0cb932).
Developed in parallel with #390 (`feat/390-telegram-resumable-reply`); see "Cross-issue contract".

## Problem (verified on the branch point)

- Live system prompt is three generic lines in `lib/alethea/ai/chains/guided_conversation_chain.ex:121-126`; the `system_prompt:` key in `config/config.exs:162-170` is never read.
- History: `Clinical.list_recent_messages/2` (`lib/alethea/clinical.ex:182-189`) + `build_patient_context/2` (:215-235) produce a flat newline-joined string with no roles. Timestamps are second-truncated with no tie-breaker. The current inbound is already persisted, so it appears both in the context and as the user message.
- `Alethea.AI.Sanitizer` is applied only to the latest message (`lib/alethea/ai/phi_worker.ex:22`); history is unsanitized. `PhiWorker` also appends emotion scores (:24-39), which is inferred clinical data.
- `Alethea.AI.ClinicalSafetyPatterns` (`diagnostic_patterns/0`, `prescriptive_patterns/0`, `normalize/1`) is not called on the Telegram path.
- Generation config: temperature 0.0, max_tokens 512; no reply-length bound specific to journaling.
- The worker test seam mocks `phi_worker().process/1` (Mox `Alethea.AI.PhiWorkerMock`), so logic inside `PhiWorker` or the chain is invisible to `perform/1` tests.

## Design decisions

1. **Worker-side reply generation seam.** A new module owns "produce the reply for this inbound": load role-structured history, call the AI worker boundary, validate the output, substitute the fallback. `handle_safe_path/7` calls it once and receives `{:ok, chain_result} | {:error, reason}` with `chain_result` keeping `:response`. Validation and history shaping therefore sit on the worker side of the mocked boundary and are observable through `perform/1`.
2. **Role-structured bounded history.** Up to the last 10 messages before the current inbound, chronological, each tagged patient or Alethea, excluding the current inbound by id (it is supplied once, as the current turn). Ordering is deterministic under equal timestamps via a stable secondary sort; prefer no migration.
3. **Sanitize everything supplied to the model.** History and current turn both go through `Alethea.AI.Sanitizer`. The emotion-score block is removed from the journaling prompt. No clinician records or inferred clinical data are supplied.
4. **Structured instructions.** Role, tone (one warm-professional tone), reply shape (brief acknowledgement, at most one exploratory question), redirection rules (unrelated and repeated unrelated requests; practical advice explored, not solved; diagnoses, medication, emotional analysis, clinician notes -> therapist, without confirming or denying; honest AI identity), prohibitions (diagnosis, prescribing, dream interpretation, clinical jargon, suggested activities, comparisons with other patients, opinions about mentioned people), and representative examples. Patient-facing copy is Spanish, consistent with the existing bot.
5. **Output guard.** Generated text is checked with the existing diagnostic and prescriptive patterns before it can be persisted or delivered. Blocked output never reaches the patient; a neutral exploratory fallback is substituted from a small set of variants, chosen deterministically per inbound so tests and retries are stable.
6. **Length bound through generation configuration.** A journaling-specific max-tokens value plus an instruction for short replies. No post-generation sentence truncation; an output cut off by the token limit must not be delivered as if complete.
7. **Roles reach the model as roles.** The chain sends prior turns as distinct patient/Alethea messages rather than one flattened context string.

## Cross-issue contract with #390

- #392 owns the body of `handle_safe_path/7` between loading context and obtaining `chain_result` (currently :224-260) and nothing else in the worker. It does not touch inbound persistence (:141-156), `persist_and_enqueue_outbound/7`, `enqueue_outbound/6`, the outbound worker, or migrations for identity/delivery.
- #390 wraps that call with a "reply already exists -> skip generation" guard and reuses the persisted reply, which is what makes a varied fallback safe across retries.
- History is bounded at, and excludes, the current inbound by id, so a #390 resume regenerates from the same snapshot.
- New worker tests go in `test/alethea/jobs/telegram_message_worker_guardrails_test.exs`; the shared 1862-line test file is edited only where an existing assertion must change (the AI-worker call-shape assertion near :287).
- In `lib/alethea/clinical.ex`, add a new history function rather than rewriting lines adjacent to `save_telegram_message/6`.

## Scope

In: Telegram patient journaling reply generation — instructions, history, sanitization, output validation and fallback, length bound, tests.
Out: retries, identity, delivery state (#390); debounce/aggregation, running summary, topic exploration limits and soft close, stale-response suppression, service-unavailable notice (other #389 slices); classifier work; crisis protocol or confirmed-case copy.

## Tasks

- [x] T1 — Role-structured, sanitized, bounded history through the reply seam. New generation seam called from `handle_safe_path/7`; last 10 prior messages with explicit roles, chronological, stable order, current turn not duplicated; all material sanitized; emotion-score block removed. Route: delegated (worktree writer; multi-file).
- [x] T2 — Output guard with varied neutral fallback. Diagnostic/prescriptive output blocked before persistence and delivery; persisted outbound and delivery job carry the fallback; variants deterministic per inbound. Route: delegated.
- [x] T3 — Structured instructions, examples, role messages, and length bound. Prompt contract tests for the rules and prohibitions the worker seam cannot establish; journaling max-tokens configuration; no truncated reply delivered. Route: delegated.

Each task closes with at least one Conventional Commit on the feature branch, tests alongside the behavior.

## Acceptance criteria (from the issue)

- [x] Structured instructions with representative examples, one warm-professional tone, brief acknowledgement before at most one exploratory question. (`journaling_prompt_test.exs`; `guided_conversation_chain_test.exs` "sends the journaling instructions as the only system message")
- [x] Up to the last 10 conversation messages in chronological, explicit patient/Alethea roles, stable ordering, no duplicated current turn. (guardrails test, "conversation history supplied to the model"; `clinical_test.exs` `list_conversation_turns/3`; chain test "conversation roles")
- [x] All conversational material supplied to the model is sanitized; protected clinician records and inferred clinical data excluded. (guardrails test, "sanitization of everything supplied to the model"; `phi_worker_test.exs`)
- [x] Unrelated and repeated unrelated requests receive brief journaling redirection; practical-advice requests explore the concern rather than solve it. (prompt contract: `journaling_prompt_test.exs` "redirection rules" and `examples/0`. Model compliance is not testable without a live model.)
- [x] Requests about diagnoses, medication, emotional analysis, or clinician notes direct the patient to their therapist without confirming or denying protected details; AI-identity questions get an honest answer. (prompt contract, same file)
- [x] Instructions prohibit diagnosis, prescribing, dream interpretation, clinical jargon, suggested activities, comparisons with other patients, and opinions about mentioned people. (`journaling_prompt_test.exs` "prohibitions")
- [x] Generated output validated with the existing diagnostic/prescriptive patterns before delivery; blocked output never reaches the patient; varied neutral exploratory fallback substituted. (guardrails test, "generated output is validated…"; `journaling_output_guard_test.exs`; `journaling_fallback_test.exs`)
- [ ] Reply length bounded through generation configuration without misleading sentence truncation. **Partly met.** Bound: `max_tokens: 160` reaches the model as `num_predict` (chain test). No text is ever trimmed. A reply the AI worker reports as `truncated: true` is withheld and replaced by the fallback (guardrails test, "a reply cut off by the length limit"). Gap: with the default `:local` provider the signal never arrives, because `lib/alethea/ai/chat_models/ollama_chat.ex` discards Ollama's `done_reason` and always builds a `:complete` message. That file is outside the #392 edit surface; until it maps `done_reason: "length"` to `status: :length`, a local reply that hits the bound is delivered as generated.
- [x] Behavior tests through `TelegramMessageWorker.perform/1` with the AI worker boundary controlled; focused deterministic prompt/validation tests only for contracts the worker seam cannot establish. No live model or classifier calls.

## Checks

- Test-first: RED observed before each behavior, then GREEN.
- Project rule: every AI pipeline change includes a sentiment regression test.
- `MIX_TEST_PARTITION=_392 mix test test/alethea/jobs test/alethea/ai test/alethea/telegram test/alethea/clinical_test.exs`
- `MIX_TEST_PARTITION=_392 mix precommit`

## Delivery

Forecast: above ~400 authored changed lines (new seam, guard, prompt, config, tests). Strategy `ask-on-risk`: chain strategy to be chosen by the user before any pull request; work-unit commits are the slice boundaries. Push, PR, and merge are user decisions. Issue label is `status:needs-triage`; branch protection has required `status:approved` before merge.

## Progress

- Worktree, CodeGraph index, deps, and partitioned test database `alethea_test_392` prepared.
- T1 done: `Alethea.Telegram.JournalingReply.generate/3` is the seam `handle_safe_path/7` calls; `Clinical.list_conversation_turns/3` supplies the bounded role-tagged history; `PhiWorkerBehaviour.process/1` now takes `%{message_id, sanitized_content, history}`; the emotion-score block is gone from `PhiWorker`.
- T2 done: `Alethea.AI.JournalingOutputGuard.check/1` validates the generated text inside the seam; blocked text is replaced by `Alethea.Telegram.JournalingFallback.for_inbound/1` before the worker can persist or enqueue anything.
- T3 done: `Alethea.AI.JournalingPrompt` holds the structured instructions and examples; `max_tokens` for the journaling chain is 160; truncated replies are withheld.
- Open: Ollama adapter does not report length-limited replies (see acceptance criteria). Needs a decision/owner for `lib/alethea/ai/chat_models/ollama_chat.ex`.
- Next: user decision on the Ollama adapter follow-up and on the delivery/chain strategy.

## Decisions made during implementation

- T1: tie-break for equal second-truncated timestamps is `(timestamp, direction, id)` — patient before Alethea inside one second, then id. No migration. Two same-direction messages inside one second keep a stable but arbitrary order (known limit; burst aggregation is another #389 slice).
- T1: history is bounded by strict position before the current inbound in that order, so a reply already stored for the current inbound is never read back as history.
- T1: the AI worker boundary contract changed from `%{message_id, raw_content, patient_context}` to `%{message_id, sanitized_content, history}`; the callback return type now states the real `{:ok, map} | {:error, term}`. `PhiWorker` re-sanitizes (idempotent) as the last step before the model.
- T1: an unloadable or undecryptable history degrades to an empty history (same as the previous `""` context fallback) with a content-free warning.
- T1: role messages in the chain (design decision 7) landed with T1 rather than T3, because the chain has to accept the new `history` shape for T1 to be coherent on its own.
- T1: the worker's private `phi_worker/0` (previously :86-90) was removed because the seam now resolves the boundary; leaving it would fail `compile --warnings-as-errors`. The worker moduledoc step 7 still says "emotion-enriched" and is left untouched (outside the #392 edit region).
- T2: four fallback variants, selected with `:erlang.phash2(inbound.id, 4)` — deterministic per inbound, varied across inbounds.
- T2: a blocked result keeps the chain result shape but carries `response: <fallback>`, `model_version: "journaling-fallback"` and `guardrail: :diagnostic | :prescriptive`; the `ai_diagnoses` row anchored to the inbound therefore stores the fallback, not the blocked text. The block is logged with reason and message id only.
- T2: the existing pattern catalog also blocks a reply that merely names medication or a diagnosis while redirecting to the therapist. Kept as is (conservative); T3's prompt examples redirect without those words.
- T3: `max_tokens: 160` (config and `suggested_max_tokens/0`); the instructions ask for at most three short sentences. Temperature stays 0.0.
- T3: token-limit cut-off is handled by signal, not by text heuristics: the chain sets `truncated: true` when the LangChain message status is `:length`, and the seam substitutes the fallback with `guardrail: :incomplete`. A punctuation heuristic was rejected (false positives, and it would have invalidated the shared test file's default stub reply).
- T3: the dead `system_prompt:` key was removed from `config/config.exs`; the prompt lives in code, static, with no interpolation.
- T3: the chain's `LLMChain.run/1` result handling now also matches LangChain's `{:error, chain, reason}`; before, a failed model call raised `CaseClauseError` inside the chain instead of returning `{:error, reason}`.
- T3: seven examples (journaling, unrelated request, repeated unrelated request, practical advice, clinical information, medication, AI identity); each passes the output guard.

## Verification evidence

- T1 RED: `MIX_TEST_PARTITION=_392 mix test test/alethea/jobs/telegram_message_worker_guardrails_test.exs` → 1/8 passed, 7 failed (`key :history not found`, `key :sanitized_content not found`, raw e-mail addresses and the duplicated current turn visible in `patient_context`).
- T1 GREEN: same command → 8 passed.
- T1 focused set: `MIX_TEST_PARTITION=_392 mix test test/alethea/jobs test/alethea/ai test/alethea/telegram test/alethea/clinical_test.exs` → 463 passed (baseline on d0cb932: 446 passed).
- T1 note: the `PhiWorker` emotion-score test and the chain role-message tests were written after the implementation (GREEN only); their worker-level counterparts were RED first.
- T1 commit: 5d52bd2 `feat(telegram): supply role-structured sanitized history to journaling replies`.
- T2 RED: `MIX_TEST_PARTITION=_392 mix test test/alethea/jobs/telegram_message_worker_guardrails_test.exs` → 10/15 passed, 5 failed (blocked text present in the persisted outbound and the delivery job; `model_version` still `phi-4-mini`).
- T2 GREEN: `MIX_TEST_PARTITION=_392 mix test test/alethea/jobs/telegram_message_worker_guardrails_test.exs test/alethea/ai/journaling_output_guard_test.exs test/alethea/telegram/journaling_fallback_test.exs` → 26 passed.
- T2 commit: a7912d5 `feat(telegram): block diagnostic and prescriptive journaling replies`.
- T3 RED: `MIX_TEST_PARTITION=_392 mix test test/alethea/jobs/telegram_message_worker_guardrails_test.exs test/alethea/ai/chains/guided_conversation_chain_test.exs test/alethea/ai/journaling_prompt_test.exs` → failures for the undefined `JournalingPrompt`, missing `truncated`, `num_predict` 512, and the truncated fragment being delivered; later `CaseClauseError` for the model-failure test.
- T3 GREEN: `MIX_TEST_PARTITION=_392 mix test test/alethea/jobs test/alethea/ai test/alethea/telegram test/alethea/clinical_test.exs` → 503 passed (2 doctests, 501 tests), 0 failed.
- Closure: `MIX_TEST_PARTITION=_392 mix precommit` → exit 0; 1833 passed (6 doctests, 1827 tests), 5 skipped, 0 failed.
- T3 commit: adfd30d `feat(ai): give journaling replies structured instructions and a length bound`.
- Authored changed lines at T3: `git diff --shortstat d0cb932..adfd30d` → 19 files changed, 1544 insertions(+), 117 deletions(-) (about 1000 of the insertions are tests and this document). Above the ~400-line delivery budget: chain strategy is a pending user decision; T1/T2/T3 commits are the slice boundaries.
