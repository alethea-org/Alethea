# Archive Report — telegram-session-reminders (#97)

**Change:** telegram-session-reminders — restore day-before session reminders on Telegram (enqueue-at-interaction).
**Issue:** alethea-org/Alethea#97 (CLOSED). Final follow-up of PRD #83.
**PR:** #103 (squash-merged to `main` as `d852ee4`).
**Status:** ✅ shipped, verified, adversarially reviewed (3 judges), merged.
**Store:** hybrid (Engram topic keys `sdd/telegram-session-reminders/*`).

## What shipped

Reminders were disabled when the WhatsApp path was retired (#87). This change restores them on **Telegram** via **enqueue-at-interaction**:

- New pure `Alethea.Accounts.SessionSchedule.next_datetime/3` — next weekly-session occurrence (UTC, wrap-around, exact-equal-time rolls +7).
- The inert `AletheaJobs.SessionReminderWorker` (kept as a no-op in #87) is repurposed to deliver via the existing `Alethea.Jobs.TelegramOutboundWorker` (static Spanish body, `patient_id: nil`), queue `:sessions`, `max_attempts: 3`, `unique: [keys: [:patient_id, :session_date], period: :infinity]`.
- Enqueue trigger `schedule_session_reminder/3` fires inside `TelegramMessageWorker.process_bound_message/6` — the one live moment the plaintext `chat_id` is in-process — scheduling the reminder for `next_session - 24h` only when that instant is still in the future (24h guard; silent skip on missing schedule).

**Design rationale:** the raw Telegram `chat_id` is deliberately never persisted decryptably (one-way HMAC `ChatIdHash`), so a midnight cron cannot address a Telegram user. Enqueue-at-interaction reuses the in-process `chat_id` (same `oban_jobs.args` PHI surface already accepted for the goodbye job), adds **no new PHI-at-rest and no schema change**. Product-owner decision (Approach A). Accepted tradeoff: a patient who never messages between sessions receives no reminder (documented non-requirement).

## Delivery

Single PR (~127 authored lib lines + tests; 400-budget risk Low). Full SDD cycle + apply run **inline on Opus** (ccm/MiniMax unavailable). Strict TDD. `mix precommit` green (571 passed) at merge.

## Judgment Day (3 judges: jd-judge-a + jd-judge-b + review-risk)

- **0 CRITICAL / 0 SEVERE — nothing merge-blocking.** All three verified `next_datetime/3` math, Oban dedup, the 24h guard, and test integrity (non-vacuous).
- **Convergent finding ① (3/3) — fixed in-PR:** `schedule_session_reminder/3` no longer swallows enqueue errors. A dedup conflict surfaces as `{:ok, _}` → success; a genuine `{:error, reason}` is logged PHI-safely (hash prefix + non-PHI `session_date` + `AletheaJobs.SafeReason.for_log/1`, which emits only changeset field-keys — never the raw `chat_id`) and does not fail the clinical inbound message (best-effort).
- **Convergent finding ② (3/3) — follow-up #102:** a reminder is not cancelled/refreshed when a patient's schedule changes mid-week; the proper fix (cancel in-flight Oban jobs on schedule change) touches accounts/dashboard and was out of scope. #102 also captures the tz-naive-UTC drift and the PHI-retention/no-Pruner observations.

## Follow-ups

1. **#102** — cancel/refresh session reminders on schedule change; + tz-naive `session_time` and Oban Pruner retention.
2. **#101** — patient-identity channel-neutralization (legacy WhatsApp schema strip) — still open, independent.

## Feature status

PRD #83 (Telegram-only journaling pipeline) remains complete; #97 restores the reminder capability that #87 had to disable, closing the last functional gap from the WhatsApp retirement.
