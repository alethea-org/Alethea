# Exploration — follow-latest-topic-393 (#393)

**Status:** exploration complete
**Issue:** #393 — Follow the latest topic and close exploration gently
**Parent:** #389 — Refine Telegram patient journaling conversation
**Blocked by:** #391 (reply-once-after-burst), #392 (bounded, guarded journaling replies) — both CLOSED, merged.
**Scope:** parent stories 4-7, 9, 32; contributes to (does not own) story 17.

## Executive summary

Topic and exploration-limit tracking does not exist anywhere yet. Recommend the model flag a "new situation" through structured output from the generation call that already exists. Code then counts questions and enforces the limit in `JournalingReply`, storing the counts as small non-PHI fields on the accepted reply row, read from the same bounded history snapshot `generate_burst/2` already uses. **#393 does not depend on #394** (the protected running summary) — it can ship standalone.

## Current state

### `lib/alethea/telegram/journaling_reply.ex`

- `generate/3` (L64) just calls `generate_burst/2` (L89).
- The request is `%{message_id: anchor.id, sanitized_content: members joined "\n\n", history: up to 10 turns before the EARLIEST member}` (L93-102).
- The result is the chain map. `guard/2` (L122-138) swaps in a `JournalingFallback` reply on `:diagnostic`, `:prescriptive`, or `:incomplete` and sets `:guardrail`.
- It knows nothing about topics or counts today.

### `lib/alethea/ai/phi_worker_behaviour.ex:11-15`

The request is exactly `message_id`, `sanitized_content`, and `history` — no slot for a mode flag or structured-output expectation yet.

### `lib/alethea/ai/chains/guided_conversation_chain.ex`

- Sends one system message, the history as role messages, then the current turn (L123-131).
- Returns `%{response, truncated, source_message_id, model_version: "phi-4-mini", behavior_type: :elicited}` (L143-152) with `max_tokens` 160.
- The output is plain text with no extra metadata slot to attach a topic signal to.

### `lib/alethea/ai/journaling_prompt.ex`

- The prompt is static, with sections Rol / Tono / Forma de cada respuesta / Cuando la conversación se sale del registro / Prohibido siempre / Ejemplos.
- Already says "como máximo UNA pregunta" per reply (L70).
- **There is no three-per-stretch rule, no follow-the-latest-topic or no-revival rule, no multi-topic burst rule, and no closing invitation.** The limit is completely absent, not just unenforced.
- `test/alethea/ai/journaling_prompt_test.exs` checks the exact list of section headings (L24-31) and that the prompt has no slot for patient data (L34-38).

### `lib/alethea/telegram/journaling_fallback.ex:16-21`

All four variants end with an exploratory question. The issue counts fallback questions toward the limit, so after the limit a blocked reply needs a closing-style fallback instead.

### Where state could live — nowhere today

- `messages` (`lib/alethea/clinical/message.ex`) has `delivery_state`, `reply_to_message_id`, and `replied_by_message_id` — non-PHI fields set by code, so there's precedent for adding small metadata columns there.
- `clinical_sessions` holds only open/closed and timestamps; sessions time out after 30 minutes of inactivity (`telegram_message_worker.ex:356`).
- `ai_diagnoses` holds `model_version`, `extracted_emotions`, and `ai_response`.
- No conversational state is persisted anywhere; everything is recomputed from history each time.

### What counts as "accepted" (the issue's own AC6)

- `TelegramBurstReplyWorker.run_save_transaction/6` (L166-207) commits the reply (as `"pending"`), the member coverage, the AI record, and the delivery job in one transaction. Any staleness or race rolls everything back and re-arms the job.
- A committed pending reply can still be superseded later, either by `Clinical.claim_telegram_delivery/1` (`clinical.ex:618-669`, claim-or-supersede at dispatch) or by a later burst absorbing it (`supersede_absorbed/1`, L437-447).
- So "accepted" means **committed and not superseded**. `list_conversation_turns/3` already uses that filter (`clinical.ex:885` excludes only superseded; failed and ambiguous replies stay in history).

### Retry stability

History is bounded at the earliest burst member. A pending reply that the current burst absorbs comes after its own members, so it is already outside that snapshot. Reading stretch state from the same snapshot therefore ignores both rolled-back and about-to-be-superseded replies, and gives the same answer on every retry.

### Closing-copy precedent

The only one is `SessionTimeoutWorker`'s `@goodbye_message` ("Tu sesión de hoy ha concluido…"), sent with `patient_id: nil` and not saved as a Message. The soft closing invitation is new copy for this issue.

### Multi-topic bursts (AC1, story 9)

Members are joined by a blank line with no labels (`journaling_reply.ex:93-96`; the join is pinned by `test/alethea/telegram/journaling_reply_test.exs:52`). The blank line is a usable boundary. Getting "acknowledge the topics, ask about the latest" needs a prompt rule plus an example, not a new input format. Explicit labels risk the model echoing them.

### Test conventions

- `test/alethea/jobs/telegram_message_worker_guardrails_test.exs` drives `TelegramMessageWorker.perform/1`, then `run_burst_reply/0` (performs the armed `TelegramBurstReplyWorker` job), with `expect(PhiWorkerMock, :process, ...)`.
- It asserts on the payload sent to the model, the decrypted saved outbound row, and the `TelegramOutboundWorker` job body. `seed_turn/4` pins timestamps.
- Prompt contracts are tested as checks on normalized prompt text plus checks that every example passes the guard and asks at most one question.

## Approaches compared — how to detect a topic boundary

### 1. Model signals it in structured output (e.g. JSON `{reply, new_situation}`) from the existing call; code counts and enforces — RECOMMENDED

- **Pros**: one call; semantic judgement; no classifier; the limit is enforced by code and testable with the mock.
- **Cons**: changes the chain's output contract; phi-4-mini may not produce valid JSON reliably; JSON uses part of the 160-token budget (truncation risk); needs a parse-failure path.
- **Effort**: Med-High.

### 2. A second model call that only classifies topic change

- **Cons**: twice the latency and cost; it is a classifier, which the issue explicitly scopes out (story 30 is separate work).
- **Effort**: High. Not recommended.

### 3. Code-based similarity (embeddings or word overlap)

- **Cons**: needs tuned thresholds, which is classifier selection/evaluation (out of scope); unreliable across topics.
- **Effort**: High. Not recommended.

### 4. Prompt only, no stored state

- **Pros**: lowest effort.
- **Cons**: the three-question limit and the "accepted outcomes" rule (AC3, AC6) can't be enforced or tested deterministically.
- **Effort**: Low. Rejected — fails the issue's own testability requirement.

## Recommendation

Use approach 1, with the logic living in `JournalingReply`, which already owns the snapshot, the guard, and fallback substitution. #391 made `TelegramBurstReplyWorker` the only caller, so this is the natural seam.

1. Read the latest accepted reply's exploration fields from the bounded snapshot.
2. Pass a static mode flag (e.g. limit reached) in the request. The chain turns it into a fixed instruction section, so no patient data enters the prompt.
3. Parse `new_situation` from the model's output.
4. Decide in code:
   - **New situation:** start a new stretch (count 1 if the reply asks a question).
   - **Same situation, under the limit:** add 1 if the reply asks a question.
   - **Same situation, at the limit:** use a closing invitation. If the model asked a question anyway, replace it with fixed closing copy (same pattern as `JournalingFallback`).
5. When at the limit, the fallback must also pick a closing variant instead of a question.
6. Return `:exploration` metadata in the result. `TelegramBurstReplyWorker` passes it to `save_telegram_reply` inside the existing transaction.
7. Store it as new nullable non-PHI columns on `messages` (e.g. `exploration_questions` smallint and `closing_invitation` boolean). Never store topic text.

For multi-topic bursts, keep the blank-line join and add a prompt rule and example.

**#394 relationship: independent.** #393 needs only per-reply counters, not a summary; the no-revival rule works from the 10-turn history. The overlap is only on the request shape and the prompt — the two issues need a merge order, not a functional dependency.

## Decisions for the proposal (not yet resolved — real open questions)

1. Does a crisis reply (`crisis_bypass`) end or reset a stretch?
2. Does a new session (after the 30-minute timeout) reset the stretch?
3. Should failed or ambiguous replies count toward history? History currently includes them.
4. What format should the signal take (JSON or something else)?
5. What happens when parsing fails? Suggested default: treat it as "same situation" and still count deterministically.

## Affected areas

- `lib/alethea/telegram/journaling_reply.ex` — read state, pass mode, parse signal, enforce limit, pick fallback.
- `lib/alethea/ai/phi_worker_behaviour.ex`, `lib/alethea/ai/phi_worker.ex`, `lib/alethea/ai/chains/guided_conversation_chain.ex` — request mode field and structured-output parsing.
- `lib/alethea/ai/journaling_prompt.ex` (+ its test) — new sections and examples.
- `lib/alethea/telegram/journaling_fallback.ex` — closing variants.
- `lib/alethea/clinical.ex` (`save_telegram_reply/5`, a snapshot read), `lib/alethea/clinical/message.ex`, plus a migration.
- `lib/alethea/jobs/telegram_burst_reply_worker.ex` — pass the metadata into the save.
- Tests: the guardrails test (key assertion), `journaling_reply_test.exs`, a new behaviour test through `TelegramMessageWorker.perform/1` plus `run_burst_reply/0`.

## Risks

1. The local phi-4-mini model may not return structured output reliably, and the 160-token reply cap now also has to hold that structure.
2. Spotting a topic change is still the model's judgement; only the counting and the limit are guaranteed by code.
3. Several existing contracts must change on purpose: the request type in `PhiWorkerBehaviour`; the guardrails test that checks the request has exactly three keys (`telegram_message_worker_guardrails_test.exs:132`); the prompt test that checks the exact section headings and that the prompt is static.
4. All four fallback replies end with a question, so after the limit they would break the three-question rule unless given a closing-aware variant.
5. #394 will touch the same request shape and prompt, so the two issues need a merge order (not a functional dependency).
6. The change will probably exceed 400 changed lines, so chained PRs are likely — consistent with #391's precedent in this same parent spec.

## Key learnings

1. `JournalingPrompt` has a one-question-per-reply rule but no three-question stretch limit, topic-following rule, or closing invitation.
2. All four `JournalingFallback` variants end with an exploratory question, so they must become stretch-aware for #393.
3. A committed burst reply can still be superseded at dispatch, so "accepted" means committed and not superseded.
4. History bounded at the earliest burst member excludes absorbed pending replies, so stretch state read from that snapshot stays the same on every retry.
5. The guardrails test checks that the model request has exactly three keys, so adding exploration mode must update that test on purpose.
