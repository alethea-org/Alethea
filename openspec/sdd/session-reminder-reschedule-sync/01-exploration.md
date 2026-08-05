# Exploration — session-reminder-reschedule-sync (#102)

**Change:** cancel a stale Telegram session reminder when a patient's schedule changes.
**Issue:** alethea-org/Alethea#102 (follow-up of #97).
**Branch:** `feat/session-reminder-reschedule-sync` off `main` (7519e51).
**Status:** Explore complete — buildable, no security fork.

## Core finding — the fix is CANCEL-ONLY, not reschedule-in-place

At schedule-change time the actor is the **professional** in `AletheaWeb.DashboardLive` — the plaintext Telegram `chat_id` is **not** in scope (it is never at rest; one-way HMAC only). So a corrected reminder cannot be re-enqueued there. The only viable fix: **cancel the stale pending `SessionReminderWorker` job**; the next inbound Telegram message re-enqueues for the new schedule via the existing, unchanged `schedule_session_reminder/3`. The transient "no reminder until next inbound" gap is the same accepted tradeoff as #97's silent-patient case.

## Answers (file:line evidence)

1. **Schedule-change call sites** — one production path: `Alethea.Accounts.update_patient_session_schedule/3` (`accounts.ex:198-202`), sole caller `DashboardLive.handle_event("save_session_schedule")` (`dashboard_live.ex:125-162`, non-mock `:146`). `update_patient/2` and `create_patient/2` also *cast* schedule fields via the shared `Patient.changeset/2`, but no live caller passes them → **latent, out of scope**, follow-up note.
2. **chat_id constraint** — confirmed: the dashboard call stack has no `chat_id` and never touches `TelegramMessageWorker`/`ChatIdHash`. Re-enqueue impossible → cancel-only.
3. **Cancel API** — Oban 2.22.1 (`mix.lock:35`) has `Oban.cancel_all_jobs/1` (Ecto queryable). Query: `worker = "Elixir.AletheaJobs.SessionReminderWorker"`, `state in ["scheduled","available"]`, `fragment("args->>'patient_id' = ?", <id>)`. No existing JSONB-args-query precedent in the repo (new small pattern). LiveView→Oban precedent exists (`ObanDashboardLive:287` `Oban.cancel_job/1`).
4. **Scope of cancel** — cancel ALL pending `SessionReminderWorker` for the `patient_id`; the `unique: [keys: [:patient_id, :session_date]]` dedup guarantees ≤1 pending, so this is safe and simplest (the professional doesn't know the server-computed `session_date`).
5. **Architectural seam** — `Alethea.Accounts` is **Oban-free** (grep: zero Oban in `accounts.ex`); all `Oban.insert` lives in `lib/alethea/jobs/` or `lib/alethea_jobs/`. Do NOT put cancel in Accounts. Put `cancel_pending/1` in the **jobs layer** (on `AletheaJobs.SessionReminderWorker` or a new sibling — design decides; consider a thin mockable wrapper like `Alethea.Telegram.OutboundEnqueue`), called from `DashboardLive` after a successful `update_patient_session_schedule/3`.
6. **Test seam** — Oban `testing: :manual` (`config/test.exs:45`). Enqueue a reminder → change schedule + cancel → assert the pending job is cancelled/gone (`refute_enqueued` or `Oban.Job` state query). Pattern in `telegram_message_worker_reminder_test.exs`.

## Recommendation

**Approach 1**: jobs-layer `cancel_pending/1` invoked from `DashboardLive` after the schedule update succeeds. Buildable on Oban 2.22.1, no schema change, preserves the hexagonal boundary #97 established. Supersedes the archived `03-design.md:117` "acceptable" note.

## Risks / open questions (for propose/design)

- Transient no-reminder gap post-cancel until next inbound (accepted, same as #97).
- `update_patient/2` / `create_patient/2` / `archive_patient/1` cast/leave schedule + pending jobs unguarded — currently unused for schedule, **out of scope**, follow-up.
- UUID `patient_id` must be compared as a string in the JSONB fragment.
- Design decides: exact module/function name + whether to wrap as a mockable boundary.
