# Spec — session-reminder-reschedule-sync (#102)

Delta for the session-reminders capability (jobs layer).

## ADDED Requirements

### Requirement: Cancel pending session reminders on schedule change

When a professional changes a patient's session schedule (`session_day_of_week` / `session_time`) via `Alethea.Accounts.update_patient_session_schedule/3`, the system MUST cancel any pending (`scheduled` or `available` state) `AletheaJobs.SessionReminderWorker` job for that `patient_id` before returning success to the caller. A jobs-layer `cancel_pending/1` function MUST perform the cancellation; `Alethea.Accounts` MUST remain free of any Oban dependency. The call site is `AletheaWeb.DashboardLive`, invoked only after `update_patient_session_schedule/3` returns `{:ok, patient}`.

#### Scenario: Pending reminder exists and schedule changes
- GIVEN a patient has exactly one `scheduled` `SessionReminderWorker` job enqueued for the current session schedule
- WHEN the professional updates the patient's `session_day_of_week` or `session_time` and the update succeeds
- THEN the previously pending job is no longer `scheduled` or `available` for that patient
- AND no error is raised to the caller

#### Scenario: No pending reminder exists
- GIVEN a patient has no `SessionReminderWorker` job in `scheduled` or `available` state
- WHEN the professional updates the patient's session schedule and the update succeeds
- THEN `cancel_pending/1` completes without error
- AND no job state changes for any patient

#### Scenario: Cancellation targets only the changed patient
- GIVEN patient A and patient B each have one pending `SessionReminderWorker` job
- WHEN patient A's session schedule is changed
- THEN patient A's pending job is cancelled
- AND patient B's pending job remains `scheduled` or `available`, unchanged

#### Scenario: Fresh reminder enqueues for the new schedule on next inbound message
- GIVEN a patient's session schedule was just changed and the prior pending reminder was cancelled
- WHEN the patient sends a new inbound Telegram message and the existing 24h-window enqueue logic runs (unchanged by this change)
- THEN a new `SessionReminderWorker` job is enqueued with `session_date` matching the new schedule's next occurrence

#### Scenario: No stale or duplicate reminder survives a schedule change
- GIVEN a patient has a pending reminder for the old schedule
- WHEN the schedule changes and cancellation runs, followed by a subsequent inbound message that re-enqueues for the new schedule
- THEN at most one `SessionReminderWorker` job is `scheduled` or `available` for that patient at any point after the change
- AND no reminder referencing the old `session_date` ever fires

### Requirement: Schedule-change paths outside DashboardLive are out of scope

`Alethea.Accounts.update_patient/2`, `create_patient/2`, and `archive_patient/1` are NOT required to trigger reminder cancellation in this change, even where they could indirectly affect a patient's session schedule. This is a documented non-goal, not an omission.

#### Scenario: Calling update_patient/2 directly does not cancel reminders
- GIVEN a patient has a pending `SessionReminderWorker` job
- WHEN `Alethea.Accounts.update_patient/2` is called directly (bypassing `DashboardLive`) and happens to change schedule-related fields
- THEN the pending job MAY remain scheduled/available
- AND this is not treated as a defect for this change (tracked as a follow-up)
