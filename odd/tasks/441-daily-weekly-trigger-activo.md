# Daily and weekly Trigger activo with end date — issue #441
Extend Trigger activo schedules with daily and weekly recurrences and optional end date in patient timezone.
Integrator branch: `feat/441-daily-weekly-trigger-activo`; base: `main` (`81bbc99`).
Delivery: single-pr (requested by user "hagamos PR y revisemos con jorge el curioso"); slice boundaries: `b3dfdd8` (domain/schedule/migration), `1197aaf` (worker recurrence lifecycle), and UI + tracking commit.

## Specs
S1. "Extend Trigger activo schedules with daily (time) and weekly (weekdays + time), both with an optional end date, computed in the patient's timezone. After each firing, the next one is scheduled until the end date."
S2. "Daily and weekly triggers fire on the expected local dates and times, across DST changes."
S3. "No firing happens after the end date."
S4. "The UI lets the professional choose the recurrence and end date."

## Tasks
T1 | S1, S4 | inline parent | done | Database migration and schemas: add schedule_type, time, weekdays, end_date to triggers; update trigger_firings with scheduled_at and unique constraint [:trigger_id, :scheduled_at] | commit: b3dfdd8.
T2 | S1, S2, S3 | inline parent | done | Pure schedule domain service (`Alethea.Triggers.Schedule`) and context integration: compute next occurrence in patient timezone across DST changes, enforce end date boundary | commit: b3dfdd8.
T3 | S1, S2, S3 | inline parent | done | ActiveTriggerWorker recurrence lifecycle: record occurrence firing, schedule next Oban job until end date, transition to fired on terminal firing | commit: 1197aaf.
T4 | S4 | inline parent | done | Web LiveView & UI: recurrence selection (una sola vez, diario, semanal), weekday selection, end date input, and active triggers list badges | commit: UI slice.
T5 | S1, S2, S3, S4 | inline parent | done | Comprehensive test suite and precommit checks: 54 focused trigger tests, 2541 tests in `mix precommit`, 10 changed paths clean in LSP | commits: b3dfdd8, 1197aaf, UI slice.

## Log
L1. User request verbatim: "hagamos la issue [Feature]: Daily and weekly Trigger activo with end date #441"
L2. Issue source: https://github.com/alethea-org/Alethea/issues/441; parent #435; dependency #440 CLOSED and merged into main.
L3. Scope: daily (time) and weekly (weekdays + time) active triggers with optional end date, calculated in patient timezone across DST changes. After each firing, the next firing is enqueued until end date. UI controls for recurrence and end date.
L4. T1 implemented via migration `20261102233235_add_recurrence_to_triggers.exs` adding `schedule_type`, `time`, `weekdays`, `end_date` to `triggers`, and adding `scheduled_at` to `trigger_firings` with unique index `[:trigger_id, :scheduled_at]`. Schemas `Trigger` and `TriggerFiring` updated.
L5. T2 implemented pure domain service `Alethea.Triggers.Schedule` and test suite `schedule_test.exs` (14 tests). Handles DST spring-forward gaps, fall-back ambiguities, weekday wrap-around, and end_date boundary enforcement in patient timezone.
L6. T3 updated `ActiveTriggerWorker` to record `scheduled_at` in firings, compute `next_occurrence`, reschedule via Oban for recurrent triggers, and transition to `"fired"` on terminal execution at `end_date`.
L7. T4 updated `TriggersLive.Index` LiveView to provide recurrence frequency selection, weekday checkboxes, optional end date, and recurrence badges in the active triggers list. 16 LiveView tests passing.
L8. T5 executed `mix precommit`: 2541 passed, 5 skipped, 0 failures. `git diff --check` and `mix format --check-formatted` clean. LSP clean across 10 files.
L9. User request verbatim: "hagamos PR y revisemos con jorge el curioso". Sliced into 3 cohesive work-unit commits (`b3dfdd8` domain/schedule/migration, `1197aaf` worker recurrence lifecycle, and UI/tracking) for PR creation and Jorge el Curioso review.
