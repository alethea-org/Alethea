# Proposal — telegram-session-reminders (#97)

**Change:** telegram-session-reminders — Telegram day-before session reminders.
**Issue:** alethea-org/Alethea#97 (final follow-up of PRD #83).
**Decided approach:** **A — enqueue-at-interaction** (product-owner decision).

## Intent

Patients on Telegram get no advance nudge before a scheduled session, hurting attendance/continuity. #97 closes this. Raw Telegram `chat_id` is never at rest (one-way HMAC `Alethea.Telegram.ChatIdHash`, deliberate cryptographic erasure — no decode, no encrypted column), so a midnight cron cannot address a Telegram user. We reuse the plaintext `chat_id` that already rides in `oban_jobs.args` **during a live inbound message** (same PHI surface as `SessionTimeoutWorker`'s goodbye), compute the patient's next session, and enqueue a reminder for `next_session - 24h`.

## Scope

### In scope
- Repurpose inert `lib/alethea_jobs/session_reminder_worker.ex` (moduledoc invites #97) into the reminder enqueue/delivery worker; static Spanish template mirroring `@goodbye_message`.
- Enqueue from the live inbound Telegram path (plaintext chat_id in-process); compute next session from `session_day_of_week`/`session_time`; deliver via `Alethea.Jobs.TelegramOutboundWorker` (chat_id + chat_id_hash args, Pacer rate-limit).
- Oban `unique` dedup keyed on (patient, session target date); past-window guard; silent skip when no schedule / no Telegram binding.
- Tests (worker behavior + `Fake.sends/0`); update `daily_scheduler_worker_test.exs:61` refute.

### Non-goals
- Reminding **silent** patients who haven't interacted since last session — accepted tradeoff, documented follow-up.
- Any WhatsApp reintroduction.
- #101 legacy-schema neutralization.
- Phi-generated / dynamic reminder copy.

## Approach

Mirror `SessionTimeoutWorker`'s job-args dispatch (channel/chat_id/chat_id_hash). At inbound-message processing, if the patient has a schedule + Telegram binding, compute `next_session`; if `next_session - 24h` is future, enqueue a reminder scheduled for that instant with `unique` on the target date. The worker sends a static Spanish body through `TelegramOutboundWorker`.

## Affected areas

| Area | Impact | Description |
|------|--------|-------------|
| `lib/alethea_jobs/session_reminder_worker.ex` | Modified | Repurpose inert module → enqueue + delivery |
| live inbound Telegram path (`telegram_message_worker.ex` flow) | Modified | Enqueue trigger site |
| `Alethea.Jobs.TelegramOutboundWorker` | Reused | Delivery, unchanged |
| `test/.../session_reminder_worker_test.exs` | New | Behavior + `Fake.sends` |
| `test/.../daily_scheduler_worker_test.exs:61` | Modified | Update refute |
| `config/test.exs` | Reused | Fake adapter already wired (`:71`) |

## Behavioral contract

- **Fires:** ~24h before the next session, for patients who interacted via Telegram after that point.
- **Skipped:** no schedule; no Telegram binding; `next_session - 24h` already past (within-24h interaction → no immediate/late reminder).
- **Dedup:** Oban `unique` on (patient, session target date) — repeated inbound messages never stack; MUST NOT double-remind.

## Risks

| Risk | Likelihood | Mitigation |
|------|------------|------------|
| Silent-patient gap (no reminder without interaction in window) | High | Accepted tradeoff; documented follow-up candidate |
| Duplicate reminders | Low | Oban `unique` on target date |
| PHI exposure via plaintext chat_id | Low | Same existing surface as goodbye; no new at-rest storage |
| Wrong next-session math | Low | Reuse `DailySchedulerWorker` slot logic; unit tests |

## Rollback

Revert the worker + enqueue-trigger commit; module returns to inert. No migration, no schema change → clean revert. Delivery worker/config untouched.

## Review workload forecast

~120–180 changed lines (worker repurpose + enqueue site + tests + one refute update). **400-line budget risk: Low.** Single-PR change; no chaining.
