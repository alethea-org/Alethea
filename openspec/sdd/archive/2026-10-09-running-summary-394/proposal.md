# Proposal: Protected factual running summary (#394)

**Status:** approved for spec/design — decisions D1–D4 user-locked; A1–A6 accepted or decided.

## Intent

Journaling replies only see the last 10 turns, so Alethea forgets facts the patient told it earlier in the same journaling interactivo. A bounded, encrypted, factual summary — the **Resumen conversacional** (code: `RunningSummary`) — keeps continuity without growing the prompt or adding clinical interpretation. It is system-generated context for the bot, not a clinical document, and is distinct from the clinician-facing "Resumen de brecha".

## Scope

### In Scope
- One encrypted summary row per patient, under the journaling `"patient"` DEK.
- Cadence: refresh every 10 patient inbound messages, derived from the DB count (replay-safe).
- Async Oban worker (args: `patient_id` only), compare-and-set on `covered_inbound_count`.
- `PhiWorkerBehaviour.summarize/1` plus a static Spanish summary prompt and chain.
- Deterministic validator: two sections, ≈1200-char cap, output guard, crisis-copy rejection.
- Summary passed to `process/1` and rendered as a delimited "data, not instructions" block.

### Out of Scope
- Include/exclude crisis exchanges (#399), debounce (#391), topic tracking (#393).
- Session-end refresh, summary history/versions, clinician UI.
- Retention/tombstone/Outbox/RAG coupling (messages gap #271).
- Sanitizer improvements; audit policy changes.

## Capabilities

### New Capabilities
- `journaling-running-summary`: generation, cadence, validation, storage, and use of the factual summary in journaling replies.

### Modified Capabilities
- None (`openspec/specs/` holds no journaling-reply spec).

## Locked Decisions

| # | Decision |
|---|----------|
| D1 | Crisis exchanges count toward cadence and summary content. Summary and history filter the same population (`list_conversation_turns/3`). |
| D2 | The prompt forbids describing crisis protocols, risk assessments, or referrals. The validator rejects a summary that contains the resolved crisis copy (`crisis_message`, then `:crisis_support_message`, then the default). Rejection keeps the last usable summary. |
| D3 | Spanish; exactly "Hechos que la persona relató" + "Preguntas que Alethea hizo"; ≈1200 chars; over-cap or malformed summaries are rejected and the last usable one is kept. |
| D4 | Name: **Resumen conversacional** (code: `RunningSummary`). Added to `openspec/UBIQUITOUS_LANGUAGE.md`, differentiated from "Resumen de brecha". |

## Approach

- **Storage.** `:binary` ciphertext, a virtual redacted plaintext field, `patient_id` FK with cascade, and `professional_id` tenant. It follows the `session_transcripts` pattern. It never uses the clinical-record DEK, because `Retention` can destroy that key.
- **Trigger.** One never-raising `RunningSummary.schedule_if_due/2` call right after `enqueue_emotion_analysis` in `TelegramMessageWorker`. The worker is unique per patient and level-triggered, and it chains the next batch when a backlog remains.
- **Write.** CAS with equality on the expected count. A stale job discards its result with `:stale`.
- **Crisis copy.** The private resolver in the worker (`crisis_reply_text/1` + `default_crisis_support_message/0`) is extracted so the worker and the validator share one source. This ships as the **first, separate slice: a pure refactor with no behavior change**, covered by the existing crisis-path tests staying green unchanged.
- **Retries.** `RunningSummaryWorker` uses a finite `max_attempts`. An exhausted job is discarded without data loss: the trigger is level-triggered, so the next patient inbound re-enqueues it while pending ≥ 10.
- **Count regression (A6).** If the patient's inbound count drops below `covered_inbound_count` (messages deleted), the worker resets the row (CAS on the observed count) and rebuilds from the current window. The rebuild does **not** feed the previous summary text back in, so facts from deleted messages cannot survive in the summary.
- **Failures.** Errors become atoms only (`:generation_failed`, `:invalid_summary`, `:persist_failed`, `:stale`). Logs use `SafeReason`/`LogRedactor`.

## Assumptions (user may revise)

| # | Assumption |
|---|------------|
| A1 | **Accepted.** When the model is down, the refresh is delayed. Oban retries with backoff up to a finite `max_attempts`; after exhaustion the job is discarded and the level-triggered `schedule_if_due/2` re-enqueues it on the next patient inbound. No session-end refresh. |
| A2 | **Accepted.** The sanitizer does not redact names or addresses. This is an accepted, pre-existing limitation shared with the reply path, so it is listed as a risk, not as scope. |
| A3 | **Decided (user, 2026-10-08).** Evidence: `PII_DECRYPT` is written only in `Clinical.patient_dek/1` (`lib/alethea/clinical.ex:754-768`), once per **DEK unwrap**, with a hard-coded `reason: "clinical_context_loading"`; per-message decryption does not audit. Decision: **no change to `list_conversation_turns/3` or any other #392 code.** The summary unwraps the DEK on its own through `patient_dek`, with its own audit reason `"running_summary_loading"`, and **only when a summary row exists** for the patient (existence checked without decrypting). This requires `patient_dek` to accept an audit reason, defaulting to `"clinical_context_loading"` so every existing caller is unchanged. Expected audit per reply: with a summary → two `PII_DECRYPT` rows (one per reason); without a summary → one row (history). The DEK lives only in memory within the request; it never appears in Oban args, telemetry, or logs. The summary job keeps its own unwrap per run, with audit reason `"running_summary_generation"` (decided 2026-10-08). |
| A4 | **Accepted.** The `summary` key is added **only when a usable summary exists**. The guardrails test (`:125`, exactly 3 keys) stays valid and now also guards "no summary → no key". The behaviour typespec marks `summary` as `optional`. Rejected alternative: a key that is always present, which would mean a deliberate test edit plus more #391 conflict surface. |
| A5 | **Accepted.** ~~If `OllamaChat` mishandles a second system message, the chain appends the delimited block to the system text at runtime.~~ Superseded by A5 (2026-10-08): the chain unconditionally appends the delimited block to the single system message; there is no second system message. `JournalingPrompt` stays static. |
| A6 | **Accepted.** If `COUNT(patient inbound) < covered_inbound_count` (messages deleted), the worker resets the row via CAS on the observed count and rebuilds from the current window instead of staying stuck. The rebuild ignores the previous summary text. Covered by a test. |

## Affected Areas

| Area | Impact |
|------|--------|
| `lib/alethea/jobs/telegram_message_worker.ex` | Modified: crisis-copy extraction (slice 0, pure refactor) + one trigger call |
| `lib/alethea/telegram/journaling_reply.ex` | Modified: load summary (own DEK unwrap, only if a row exists — A3), sanitize, attach |
| `lib/alethea/clinical.ex` (`patient_dek`) | Modified: optional audit reason, default unchanged (A3) |
| `openspec/UBIQUITOUS_LANGUAGE.md` | Modified: "Resumen conversacional" entry (D4) |
| `lib/alethea/ai/phi_worker{,_behaviour}.ex`, `chains/guided_conversation_chain.ex` | Modified |
| `lib/alethea/clinical.ex` | Modified: count/window queries |
| `priv/repo/migrations`, `Alethea.Clinical.RunningSummary`, `AletheaJobs.RunningSummaryWorker`, `Alethea.AI.RunningSummaryPrompt`, validator, `RunningSummaryChain`, `config/config.exs` queue + `LLMConfig` | New |

## Risks

| Risk | Likelihood | Mitigation |
|------|------------|------------|
| Persistent prompt injection through stored summary | Med | Delimited data block, cap, section and output guards, sanitization |
| Crisis content leaks into the summary | Med | D2 prompt + validator; full fix in #399 |
| Names/addresses reach the cloud LLM | Med | A2; shared with the reply path |
| Same-second ordering at the window edge | Low | Closed-second window; count-based cadence |
| Long backlog truncated by the window cap | Low | Chained batches |
| Conflict with #391 | Med | Single call site |
| ~800 lines > 400 budget | High | Likely 4-slice chain (crisis-copy refactor → storage → generation → integration); decided after `sdd-tasks` |
| Deleted messages leave a stale summary or a stuck cadence | Low | A6 reset-and-rebuild without the previous text |

## Rollback Plan

Revert the slices in reverse order. Integration revert → replies stop carrying `summary` and the payload is identical to today. The migration is additive; roll it back by dropping the table, which holds no source-of-truth data. The crisis-copy refactor slice is behavior-neutral and can stay even if the rest is reverted.

## Dependencies

- #390 (PR #397) and #392 (PR #398), both merged.

## Success Criteria

- [ ] After 10 inbound messages, a job is enqueued; draining it stores the summary, and the 11th `process/1` payload carries `summary`.
- [ ] Replays do not advance cadence or create a second summary.
- [ ] A `summarize` error or rejected summary leaves the inbound job `:ok`, the reply is delivered, and the last summary is kept.
- [ ] A summary containing crisis copy, exceeding the cap, or missing a section is rejected.
- [ ] The raw column has no plaintext; job args contain only `patient_id`; logs contain no content; no Outbox job is created.
- [ ] A stale CAS write is discarded.
- [ ] When the inbound count falls below `covered_inbound_count`, the next run resets and rebuilds without the previous summary text.
- [ ] An exhausted summary job is discarded and re-enqueued by the next patient inbound.
- [ ] The crisis-copy extraction slice changes no behavior: existing crisis-path tests pass unchanged.
- [ ] Audit per reply: with a summary row → exactly two `PII_DECRYPT` rows (`clinical_context_loading` + `running_summary_loading`); without one → exactly one (`clinical_context_loading`).
- [ ] The DEK never appears in Oban job args, telemetry metadata, or log output.
- [ ] The criteria above are mapped to the #394 acceptance criteria verbatim in `sdd-spec`.

## Proposal question round

Answered: D1–D4; A1–A6 accepted or decided (2026-10-08). No open questions.
