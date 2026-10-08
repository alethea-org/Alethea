# Exploration — reply-once-after-burst-391 (#391)

**Status:** exploration complete
**Issue:** #391 — Reply once after a patient finishes a message burst
**Parent:** #389 — Refine Telegram patient journaling conversation
**Blocked by:** #390 (resumable/duplicate-safe reply) — CLOSED, merged as PR #397.
**Scope:** parent stories 8, 22, 31, 32 only.

## Corrections to the brief

1. **The local checkout was stale during exploration** — HEAD was `feat/365-continue-from-version`, lacking #390 and #392. The orchestrator has since checked out a fresh `origin/main` (commit `8e3cbac`) which includes both. Exploration below reads #390/#392 from GitHub raw source; line numbers are approximate and must be re-verified by design against the now-fresh local tree.
2. **#392 ("Deliver bounded, guarded journaling replies") is CLOSED and merged** (PR #398), not open as the parent issue list suggested at the time this was checked. It added `Alethea.Telegram.JournalingReply.generate/3`, which is now the reply-generation call #391 builds around.
3. **Worker paths**: the workers live in `lib/alethea/jobs/` (`Alethea.Jobs.TelegramMessageWorker`, `Alethea.Jobs.TelegramOutboundWorker`), not `lib/alethea_jobs/` as initially assumed. Tests are in `test/alethea/jobs/`.
4. **CodeGraph did not help** — the index returned only JS/Python symbols for Elixir queries; fell back to Grep/Read and GitHub raw source.

## Executive summary

#390 delivered one reply per inbound message and a delivery state machine (`pending|sending|sent|ambiguous|failed`), but explicitly left debounce/aggregation and stale-response suppression out of scope — #391 starts from zero on those. Recommend a durable Oban job delayed ~45s per patient, pushed back by each new inbound message (mirroring the existing `SessionTimeoutWorker` pattern), plus staleness re-checks at persist time and at dispatch time inside the outbound worker's claim step.

## Current state

### What #390 already delivered (on main)

- Inbound messages are de-duplicated per patient conversation; a retry resumes the saved message (`Clinical.find_or_save_telegram_inbound/4`).
- Each reply records the one inbound it answers (`messages.reply_to_message_id`, unique index).
- Each reply has a delivery state: `pending|sending|sent|ambiguous|failed`. The outbound worker claims the row before sending (`claim_telegram_delivery/1`).
- `TelegramDeliverySweepWorker` runs every 5 minutes and marks claims stuck in `sending` for over 600s as `ambiguous`.
- **#390's own task doc explicitly named "debounce/aggregation, stale-response suppression" as out of scope.** Today there is no debounce, no snapshot/staleness check, and no burst concept.

### Inbound worker today (`Alethea.Jobs.TelegramMessageWorker`)

- Crisis check: `CrisisMonitor.detect/1` already runs on every inbound, before any generation.
- Safe path: generates the reply synchronously inside the inbound job (now via #392's `JournalingReply.generate/3`).
- Crisis path: bypasses the model, saves a `crisis_bypass` reply in one transaction, and enqueues it on `:telegram_outbound_crisis` with priority 0. AC6's "immediate crisis check" already exists as a structural fact — what's new for #391 is cancelling/superseding any pending *ordinary* reply when crisis fires mid-burst.

### Emotion analysis (AC7)

Already structurally independent. It is a separate job on queue `:ai_analysis`, unique per message, enqueued before the crisis/safe split — confirms AC7 holds by construction, nothing to build here.

### Outbound worker (`Alethea.Jobs.TelegramOutboundWorker`)

- Waits on `Pacer.acquire/1` first, then claims the row (journaling lane only), then sends.
- Retries are manual reschedules (`max_attempts: 1`, `_attempt` arg, 429 Retry-After, backoff with jitter).
- Each retry re-runs the claim, so this is the natural place for AC4's "checked again at dispatch, including after queue/rate-limit waits and on retries."

### AI worker boundary (mockable seam)

- Mock: `Alethea.AI.PhiWorkerMock` (Mox, registered in `test/test_helper.exs:16`, `config/test.exs:27`) for `PhiWorkerBehaviour.process/1`.
- Concurrency test pattern already established: two `Task.async` calls to `perform/1`, each blocked inside the stub until the test sends `:release` — the pattern to mirror for burst-race tests.
- Outbound delivery is driven through `Client.Fake.queue_responses` plus `all_enqueued` and `TelegramOutboundWorker.perform/1`.
- #390's tests live in `test/alethea/jobs/telegram_message_worker_idempotency_test.exs`.

### Existing debounce precedent

`SessionTimeoutWorker` (`lib/alethea_jobs/session_timeout_worker.ex`) already implements a debounce using Oban's `replace: [scheduled: [:scheduled_at]]` with `unique: [fields: [:args], period: :infinity]`, covered by a renewal test. This is the idiomatic pattern to mirror for #391's burst-window job. Oban is 2.22.1 on the Basic engine (no Pro — confirms no access to Oban Pro's more advanced debounce/batch plugins).

### Test conventions

Existing `test/alethea/jobs/telegram_message_worker_idempotency_test.exs` (#390's own tests) establishes the exact job-perform-entry-point integration style the parent spec's testing decisions demand: drive `TelegramMessageWorker.perform/1` directly, substitute the AI worker boundary via Mox, assert persisted records + enqueued delivery jobs, not internal state.

## Approaches compared

### A. Oban job delayed ~45s, unique per patient among waiting jobs only, each inbound pushes it back; staleness check at persist and at dispatch — RECOMMENDED

- **Pros**: mirrors the existing `SessionTimeoutWorker` pattern exactly; durable across restarts and multi-node (unlike a GenServer timer); testable through `perform_job`/time manipulation in ExUnit.
- **Cons**: needs a new "superseded" delivery state and a burst-coverage model (which inbound rows does one reply cover) that doesn't exist yet.
- **Effort**: Medium.

### B. Per-patient GenServer timer

- **Cons**: lost on restart, single-node only, conflicts with this project's "Oban is mandatory for the message pipeline" mandate (CLAUDE.md).
- **Rejected.**

### C. Cron polling for patients idle ≥45s

- **Cons**: cron granularity (at most once a minute) makes replies late; adds polling overhead for no real benefit over A.
- **Fallback only, not recommended.**

## Recommendation

Approach A:
- The safe branch of the inbound worker stops generating synchronously and instead (re-)arms a single burst-reply Oban job keyed on `[:patient_id]`, unique among `:scheduled` jobs, pushing `scheduled_at` ~45s into the future on every new ordinary inbound message.
- Record which inbound rows a reply covers — prefer an explicit column on inbound rows set via a conditional UPDATE (makes AC5's "at most one patient-visible reply" provable in a test, not just assumed).
- The burst-reply job's own execution re-checks "has anything newer arrived since I was scheduled" before generating, and the outbound worker's claim step re-checks again before actually sending (AC4).
- Add a `superseded` delivery state; the crisis path, on firing, marks any still-`pending` ordinary reply for that patient as `superseded` instead of letting it through.

## Affected areas

- `lib/alethea/jobs/telegram_message_worker.ex` — safe-path branch stops synchronous generation, arms/reschedules the burst job instead; crisis path marks pending ordinary replies `superseded`.
- A new burst-reply Oban worker (new file) — mirrors `SessionTimeoutWorker`'s debounce idiom.
- `lib/alethea/jobs/telegram_outbound_worker.ex` — dispatch-time staleness re-check inside the existing claim step (AC4).
- Message/reply schema — new `superseded` delivery state; a burst-coverage column or join table on inbound rows.
- `test/alethea/jobs/` — new tests mirroring #390's job-perform-entry-point integration style for: window renewal, burst coverage/ordering, crisis-mid-burst supersession, dispatch-time staleness recheck, delivery idempotency across overlapping burst jobs.

## Risks

1. **Out-of-order processing within a burst**: the `telegram_inbound` queue runs 10 jobs concurrently, so burst messages can be processed out of order. `telegram_message_id` is a string column, so ordering by it compares text, not numbers — needs a numeric/timestamp ordering key for "preserving message order" (AC2).
2. **Unrecallable in-flight replies**: a reply already in `sending` or `ambiguous` state cannot be superseded — a crisis reply could still go out right after an ordinary one that was already dispatched. Needs an explicit decision on whether this residual race is accepted or needs narrowing.
3. **Unsent replies leaking into model history**: `list_conversation_turns` (or equivalent context-builder for the next generation) does not appear to filter by delivery state today — a withheld/superseded reply's text could leak into the model's history for a later turn unless explicitly filtered.
4. **Generation contract change**: `JournalingReply.generate/3` (from #392) and whatever `ai_diagnosis`-style helper exists currently take one inbound message as input. Supporting a multi-message burst as a single generation input needs a prompt/anchor contract change — but that change belongs to #392's module, not #391's new scope; #391 should treat this as an integration point to coordinate carefully, not re-litigate #392's own design.
5. **Line budget**: likely exceeds 400 given this repo's established precedent (new worker + schema/state addition + dispatch-time recheck + the mandated test coverage) — expect a chained-PR recommendation at design time, consistent with #316/#317/#328/#364's precedent in this session.

## Key learnings

1. The Telegram workers live in `lib/alethea/jobs/`, not `lib/alethea_jobs/`.
2. Issue #390 explicitly excluded debounce and stale-response suppression, so #391 starts with no snapshot or burst mechanism at all.
3. `SessionTimeoutWorker`'s `replace: [scheduled: [:scheduled_at]]` plus `unique` pattern is the existing debounce precedent to mirror for the new burst-reply job.
4. The outbound worker already claims the row after `Pacer.acquire/1`, so the dispatch-time eligibility re-check (AC4) belongs inside that existing claim step.
5. Asynchronous emotion analysis is already structurally independent of reply generation (separate `:ai_analysis` queue job), so AC7 holds by construction with no new work needed.
