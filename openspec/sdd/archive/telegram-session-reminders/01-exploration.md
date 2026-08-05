# Exploration — telegram-session-reminders (#97)

**Change:** telegram-session-reminders — restore day-before session reminders on the Telegram channel.
**Issue:** alethea-org/Alethea#97 (final follow-up of PRD #83).
**Branch:** `feat/telegram-session-reminders` off `main` (86a18c0).
**Status:** Explore complete — **BLOCKED on a security/PHI decision** before propose.

## The central finding (verified)

The feature as written in #97 is **architecturally blocked** by the Telegram identity design.

- To deliver a proactive reminder, `Alethea.Jobs.TelegramOutboundWorker.perform/1` needs the **plaintext** `chat_id` — `telegram_outbound_worker.ex:74` does `Map.fetch!(args, "chat_id")` → `Client.send_message(chat_id, body)`. The hash alone is only the Pacer rate-limit key; it cannot address a Telegram message.
- The raw `chat_id` is **never stored at rest**. `Alethea.Telegram.ChatIdHash` is a one-way HMAC-SHA256 with no `decode`/`decrypt` (`chat_id_hash.ex:20-25`): *"the system never stores, queries, or logs a raw Telegram chat_id"* — a deliberate cryptographic-erasure surface. `rg` confirmed **no encrypted chat_id column exists anywhere**; `foundation_patients` carries only `telegram_chat_id_hash` (`patient.ex:61`).
- `AletheaJobs.DailySchedulerWorker` runs on the midnight cron `"0 0 * * *"` with **no live-webhook context** and no chat_id/telegram source at all.

Why `SessionTimeoutWorker`'s goodbye works but the cron can't: the goodbye is enqueued **during a live inbound Telegram message**, when the plaintext `chat_id` is in-process and rides forward inside `oban_jobs.args` (the existing PHI surface). A midnight cron has no such moment.

## What is NOT the blocker

The **scheduling anchor exists**. Legacy `Alethea.Accounts.Patient` has `session_day_of_week` (1-7) + `session_time` (`patient.ex:15-16`). `DailySchedulerWorker` already computes `tomorrow_dow` and queries active patients on that slot to enqueue `WeeklyReportWorker` (`session_dt - 2h`). The reminder would reuse the same anchor. (`Clinical.Session` from #85 is message-grouping — no future date — not usable here.)

## Identity path

- Legacy `Patient` (`patients`) has the schedule but **no** Telegram field.
- `Foundation.Accounts.Patient` (`foundation_patients`) has `telegram_chat_id_hash` + a nullable `belongs_to :legacy_patient`. Existing `Foundation.Accounts.legacy_patient/1` only goes foundation→legacy; a reminder starting from the legacy schedule needs the **reverse** lookup (net-new query). #101 (legacy-schema neutralization) is not assumed done.

## Options (security decision — owner's call)

| # | Approach | Reminds whom | PHI-at-rest cost |
|---|----------|--------------|------------------|
| **A** | **Enqueue-at-interaction** — reuse the live-webhook `chat_id` (already rides in `oban_jobs.args`), enqueue a future reminder job at inbound/session-close time scheduled for `next_session - 24h`. | Only patients who interacted since their last session (silent patients get none; degrades gracefully for active journaling patients). | **None new** — respects "never store raw chat_id". |
| **B** | **Store encrypted chat_id** — new Cloak/`PatientVault`-encrypted column on `foundation_patients`; cron decrypts and reminds everyone. | Every scheduled patient. | **Reverses** the documented cryptographic-erasure design; expands PHI-at-rest; needs product/security sign-off + migration + populate-on-onboarding. |
| **C** | **Descope** — close #97, reminders stay OFF, document the constraint. | Nobody. | None. |

Orchestrator recommendation: **A** — it satisfies the spirit of #97 (proactive day-before push over Telegram) without reversing a documented security posture, and it reuses the exact `SessionTimeoutWorker` delivery pattern. The tradeoff (silent patients) is acceptable for an active journaling loop and can be revisited later.

## Open design questions (for propose/design)

- Reminder timing: fire at enqueue-anchor time vs `scheduled_at = session_dt - 24h`.
- Message content: static Spanish template (mirror `SessionTimeoutWorker @goodbye_message`) — recommended — vs Phi-generated.
- Idempotency/dedup: no existing pattern for a recurring reminder; needs a per-(patient, target-date) unique key.
- Reuse the inert `SessionReminderWorker` module (its moduledoc invites repurposing) vs a fresh module.
- Skip behavior for patients with no Telegram binding / no legacy bridge (expect silent skip).

## Test notes

- `session_reminder_worker_test.exs` was **deleted** in #87 PR-A — author fresh.
- `daily_scheduler_worker_test.exs:61` has `refute_enqueued(worker: SessionReminderWorker)` to update.
- Telegram Fake adapter (`Alethea.Telegram.Client.Fake`, `Fake.sends/0`) is wired in `config/test.exs:71` + `dev.exs:123`.
