# Proposal — session-reminder-reschedule-sync (#102)

**Change:** cancel a stale Telegram session reminder when a patient's schedule changes (cancel-on-change).
**Issue:** alethea-org/Alethea#102 (follow-up of #97).

## Intent

Telegram session reminders (#97) are enqueued at inbound-message time for `next_session - 24h`, deduped `unique: [keys: [:patient_id, :session_date], period: :infinity]`. When a professional edits a patient's `session_day_of_week`/`session_time`, the already-scheduled `AletheaJobs.SessionReminderWorker` job for the OLD session is never cancelled — it still fires ("tienes una sesión programada para mañana" for a moved session), and a second reminder later enqueues for the new day.

**Key constraint:** at schedule-change time the actor is the professional in `AletheaWeb.DashboardLive`; the plaintext Telegram `chat_id` is NOT in scope (never at rest — one-way HMAC). Re-enqueuing a corrected reminder there is impossible. Therefore the fix is **cancel-only**: void the stale pending job; the next inbound Telegram message re-enqueues for the new schedule via the existing, unchanged `TelegramMessageWorker.schedule_session_reminder/3`.

## Scope

### In scope
- Jobs-layer `cancel_pending/1` cancelling ALL pending `SessionReminderWorker` jobs for a `patient_id` (state `scheduled`/`available`) via `Oban.cancel_all_jobs/1` + an Ecto query on `worker`, `state`, `fragment("args->>'patient_id' = ?", id)` (UUID compared as string).
- Call it from `AletheaWeb.DashboardLive` immediately after a successful `Accounts.update_patient_session_schedule/3` (`dashboard_live.ex:146`).
- Tests: cancel fn (pending job voided; no-op when none) + DashboardLive call-site integration.

### Non-goals
- Reschedule-in-place / re-enqueue a corrected reminder (blocked by the `chat_id` constraint).
- Guarding `update_patient/2`, `create_patient/2`, `archive_patient/1` — they cast schedule fields but no live caller passes them. Documented **follow-up candidate**, NOT this change.
- Any new reminder timing or content change.

## Approach

Keep the hexagonal boundary #97 set: `Alethea.Accounts` stays Oban-free. Cancellation lives in the JOBS layer (`SessionReminderWorker` or sibling — design decides), invoked by the web adapter after the domain mutation succeeds. Dedup guarantees ≤1 pending job, so cancel-all is safe. Supersedes the archived "acceptable" note at `openspec/sdd/archive/telegram-session-reminders/03-design.md:117`.

## Behavioral contract

On successful schedule change → all pending reminder(s) for that patient cancelled; NO reminder fires until the next inbound Telegram message re-enqueues for the new schedule (accepted transient gap — same tradeoff as #97).

## Affected areas

| Area | Impact | Description |
|------|--------|-------------|
| `lib/alethea_jobs/session_reminder_worker.ex` | Modified | Add `cancel_pending/1` |
| `lib/alethea_web/live/dashboard_live.ex` (~:146) | Modified | Call cancel after schedule update |
| `test/` | New | Cancel fn + call-site tests |

## Risks

| Risk | Likelihood | Mitigation |
|------|------------|------------|
| Transient reminder gap until next inbound | Med | Accepted tradeoff, inherited from #97 |
| UUID-as-string JSONB compare mismatch | Low | `args->>'patient_id'` is text; compare UUID as string; test coverage |
| Latent staleness on unused patient-update paths | Low | Documented as follow-up non-goal |

## Rollback

Single-PR revert. Removing `cancel_pending/1` and its call site restores prior behavior; no schema/migration/data change.

## Review workload forecast

~40–70 authored lines (one small fn + one call site + 2 focused tests). **400-line budget risk: Low.** Single PR, no chaining, no pre-apply decision.
