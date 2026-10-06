# Issue 390 — Make a Telegram journaling reply resumable and duplicate-safe

## Objective

One persisted patient message completes its reply despite worker retries, concurrent executions, and outbound retries, without creating another patient-visible response.

Reference: https://github.com/alethea-org/Alethea/issues/390 (parent spec #389, stories 31 and 32).

Branch: `feat/390-telegram-resumable-reply` (worktree, branched from `origin/main` @ d0cb932).
Developed in parallel with #392 (`feat/392-guarded-journaling-replies`); see "Cross-issue contract".

## Problem (verified on the branch point)

- `messages.telegram_message_id` has a GLOBAL partial unique index (`messages_telegram_message_id_unique`); `messages` stores no chat identifier, only `patient_id`. Telegram message ids are per chat, so two patients can collide.
- `TelegramMessageWorker.process_bound_message/6` (`lib/alethea/jobs/telegram_message_worker.ex:141-156`) raises on the duplicate insert. Any failure after the inbound insert (LLM error, empty reply, diagnosis failure, enqueue failure) makes every Oban retry die on the duplicate, so the reply is never produced. Pinned today by `test/alethea/jobs/telegram_message_worker_test.exs:721-768`.
- No inbound -> outbound link on `messages`; only `ai_diagnoses.message_id` (non-unique). Concurrent runs can insert two diagnoses and two outbound rows.
- `persist_and_enqueue_outbound/7` commits at :283-299 and enqueues at :303 outside the transaction: a crash in between leaves a persisted reply with no delivery job.
- No delivery state. Reply body and chat id live only in Oban args; Telegram's returned message id is discarded.
- `Alethea.Telegram.Client.Req` maps every transport failure, including a timeout after the request was sent, to `{:error, :network}`, which `TelegramOutboundWorker` blindly reschedules.

## Design decisions

1. **Conversation-scoped identity.** Replace the global unique index with a partial unique index on `(patient_id, telegram_message_id)`. The chat hash lives on `foundation_patients` (one Telegram chat per patient), so `patient_id` is the conversation scope; no new chat column on `messages`.
2. **Resume, do not re-insert.** Inbound persistence becomes find-or-insert by that identity. A re-execution loads the existing inbound and resumes from its recorded outcome.
3. **One logical reply per inbound.** The outbound message records the inbound that caused it (reply provenance) under a unique constraint. Concurrent executions race on that constraint; the loser reuses the winner's reply instead of generating or persisting another. No generation happens when a reply already exists.
4. **Recoverable delivery intent.** The outbound row carries an explicit delivery state. A resume that finds a persisted reply without a completed delivery re-establishes the delivery job; the job is keyed by the outbound message so repeats collapse into one.
5. **Explicit outcomes, no blind resend.** Delivery states distinguish at least: pending, sent (acknowledged, Telegram message id stored), ambiguous, failed. The outbound worker claims the row before sending; an acknowledged delivery is never sent again; a failure known to precede the send may retry; a failure after the request may have reached Telegram (timeout, or a re-execution that finds the row already claimed) is recorded as ambiguous and is NOT resent. At-most-one is traded against delivery certainty by design: an ambiguous journaling reply may never arrive.
6. **Crisis lane delivery policy is unchanged.** Crisis replies keep configured content, priority 0 / `:telegram_outbound_crisis`, the single-transaction persistence, and today's resend behavior. The no-resend-on-ambiguity rule applies to the journaling lane only. Inbound resume and reply dedupe at the persistence level apply to both lanes. If the guarantee cannot be met without changing crisis delivery policy, stop and report the blocker.
7. **No new plaintext clinical data.** Delivery state is non-sensitive metadata; reply content stays in the existing encrypted column.

## Cross-issue contract with #392

- #392 owns reply generation: the body of `handle_safe_path/7` between loading context and obtaining `chain_result` (currently :224-260), which it replaces with one call returning `{:ok, chain_result} | {:error, reason}` where `chain_result` keeps `:response`.
- #390 owns everything before that call (inbound identity and resume) and after it (`persist_and_enqueue_outbound/7`, `enqueue_outbound/6`, outbound worker, client outcome mapping, migrations). #390 does not rewrite the generation lines; the "reply already exists -> skip generation" guard goes around the call, not inside it.
- New worker tests go in `test/alethea/jobs/telegram_message_worker_idempotency_test.exs`; the shared 1862-line test file is edited only where an existing assertion must change (:721-768 inverted).
- #392 varies its blocked-output fallback; that is only safe because #390 reuses the persisted reply rather than regenerating.

## Scope

In: Telegram patient journaling path — inbound worker orchestration, outbound worker, Telegram client outcome mapping, `Alethea.Clinical` persistence functions, `Message` schema, migrations, tests.
Out: prompt, history, sanitization, output validation (#392); debounce/aggregation, stale-response suppression, service-unavailable notice (other #389 slices); classifier work; crisis protocol or copy changes.

## Tasks

- [x] T1 — Conversation-scoped inbound identity and resume. Migration swapping the unique index; find-or-insert inbound; a retry after a failure past the inbound insert resumes and produces the reply; equal Telegram message ids for two patients do not collide. Route: delegated (worktree writer; multi-file).
- [x] T2 — One logical reply with recoverable delivery intent. Reply provenance under a unique constraint; existing reply reused on repeated and concurrent executions (no second generation, diagnosis, or outbound row); crash between persistence and enqueue recovered on resume; crisis reply content, priority, and persistence unchanged. Route: delegated.
- [x] T3 — Explicit delivery outcomes in the outbound path. Delivery state on the reply; acknowledged delivery never resent; ambiguous transport outcome represented and not resent on the journaling lane; pre-send failures still retry; crisis lane behavior unchanged. Route: delegated.

Each task closes with at least one Conventional Commit on the feature branch, tests alongside the behavior.

## Acceptance criteria (from the issue)

- [x] Reprocessing an already persisted inbound resumes its existing outcome rather than failing on a duplicate insert or restarting completed work.
- [x] Message identity is scoped to the patient's Telegram conversation; equal Telegram message identifiers in different conversations do not collide.
- [x] Reply provenance, persisted outbound content, and delivery intent remain recoverable across failure between persistence and enqueue.
- [x] Concurrent executions, repeated jobs, and outbound retries reuse one logical reply; an acknowledged successful delivery is not sent again.
- [x] Ambiguous transport outcomes are represented explicitly and do not cause blind resend; at-most-one is demonstrated for the claimed failure cases.
- [x] Existing deterministic crisis replies retain their configured content, priority, and persistence guarantees.
- [x] Behavior tests through `TelegramMessageWorker.perform/1` with the AI worker boundary controlled; controlled outbound delivery where actual-send behavior matters. No live model or classifier calls.

## Checks

- Test-first: RED observed before each behavior, then GREEN.
- `MIX_TEST_PARTITION=_390 mix test test/alethea/jobs test/alethea/telegram test/alethea/clinical_test.exs`
- `MIX_TEST_PARTITION=_390 mix precommit`

## Delivery

Forecast: above ~400 authored changed lines (three tasks, two workers, migration, tests). Strategy `ask-on-risk`: chain strategy to be chosen by the user before any pull request; work-unit commits are the slice boundaries. Push, PR, and merge are user decisions. Issue label is `status:needs-triage`; branch protection has required `status:approved` before merge.

## Progress

- Worktree, CodeGraph index, deps, and partitioned test database `alethea_test_390` prepared.
- T1 done: composite identity index, `Clinical.find_or_save_telegram_inbound/4`, worker resumes the persisted inbound; the old duplicate-raise test in `telegram_message_worker_test.exs` is inverted.
- T2 done: `messages.reply_to_message_id` under a unique index, `Clinical.save_telegram_reply/5` / `get_telegram_reply/1` / `telegram_reply_text/2`, worker reuses the persisted reply on repeated and concurrent executions and re-establishes delivery on resume; delivery job keyed by the outbound message.
- T3 done: `messages.delivery_state` / `delivered_telegram_message_id`, claim-before-send in `TelegramOutboundWorker`, `Client.not_delivered?/1`, Req adapter separates "connection never established" from ambiguous transport failures, inbound resume only re-establishes a pending delivery.
- All tasks complete. Next: user chooses the delivery (chain) strategy; no push or PR was made.

## Verification evidence

### T1

- RED: `MIX_TEST_PARTITION=_390 mix test test/alethea/jobs/telegram_message_worker_idempotency_test.exs` -> 0/3 passed, all three raising `failed to persist inbound (reason=[:telegram_message_id])`.
- GREEN: same command -> 3 passed. `mix test test/alethea/jobs/telegram_message_worker_test.exs test/alethea/jobs/telegram_message_worker_idempotency_test.exs test/alethea/clinical_test.exs` -> 60 passed.
- Decisions beyond the design: the reply is persisted in the inbound's own session (`inbound.session_id`) on resume; `EmotionAnalysisWorker` is enqueued with a per-inbound Oban unique key so a resume does not analyse the same message twice.
- Commit: `883e2b6` feat(telegram): scope inbound identity to the conversation and resume it

### T2

- RED: `MIX_TEST_PARTITION=_390 mix test test/alethea/jobs/telegram_message_worker_idempotency_test.exs` -> 3/9 passed, the six new reply tests failing (no `reply_to_message_id`, second generation/outbound row on repeat, `failed to persist inbound`-free but duplicate outbound rows on the concurrent run, no recovery after the failed enqueue).
- GREEN: same command -> 9 passed. `MIX_TEST_PARTITION=_390 mix test test/alethea/jobs test/alethea/telegram test/alethea/clinical_test.exs` -> 246 passed (2 doctests, 244 tests).
- Concurrency is demonstrated by "two concurrent executions of the same job produce one reply and one delivery job": both executions are held inside generation, then race on the reply's unique index.
- Decisions beyond the design: a concurrent loser has already generated (holding a DB lock across the LLM call was rejected); its text is discarded. A resumed reply ships the persisted, decrypted content, not regenerated text or the current crisis-message configuration. A resumed crisis execution raises `:crisis_detected` again (at-least-once alert). The delivery lane on resume follows the persisted row's `behavior_type`.
- Commit: `b03d59a` feat(telegram): keep one logical reply per inbound and recover its delivery

### T3

- RED: `MIX_TEST_PARTITION=_390 mix test test/alethea/jobs/telegram_message_worker_idempotency_test.exs` -> 9/20 passed, the eleven delivery-outcome tests failing (state never recorded, ambiguous and 5xx errors rescheduled, acknowledged reply resent by a duplicate job). Adapter: `mix test test/alethea/telegram/client/req_test.exs` against the previous adapter -> 11/14 passed, three failing on `{:error, :network}`.
- GREEN: idempotency file -> 20 passed; `test/alethea/telegram/client` -> 21 passed.
- Closure: `MIX_TEST_PARTITION=_390 mix test test/alethea/jobs test/alethea/telegram test/alethea/clinical_test.exs` -> 260 passed (2 doctests, 258 tests). `MIX_TEST_PARTITION=_390 mix precommit` -> exit 0, 1799 passed (6 doctests, 1793 tests), 5 skipped.
- At-most-one is demonstrated for: acknowledged delivery re-executed; ambiguous transport error; Telegram 5xx; execution that died mid-send; two concurrent executions of one delivery job (the second starts while the first request is in flight); repeated inbound job after the delivery job is gone.
- Decisions beyond the design: Telegram 5xx counts as ambiguous on the journaling lane (the request reached Telegram); a plain transport `:timeout` is ambiguous because connect and receive timeouts are indistinguishable; an unknown error shape is ambiguous; the execution holding the claim may overwrite an `ambiguous` mark set by an observer with what it actually saw (`sent` or released to `pending`); the delivery job key covers incomplete jobs only, since the row claim is the guarantee; ambiguous outcomes are logged (hash prefix, message id, fixed outcome label), not dead-lettered or broadcast. Crisis lane: no claim and every error still retried; the row only records `sent` (a repeated job does not resend an acknowledged crisis reply) and `failed` on dead-letter.
- Commit: `71a3c4a` feat(telegram): record delivery outcomes and never blindly resend a reply
