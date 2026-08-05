# Tasks — telegram-session-reminders (#97)

**Delivery:** single PR. **400-line budget risk: Low.** No chaining. Strict TDD (RED → GREEN → refactor).

> ⚠️ Namespace gotcha: the reminder worker is `AletheaJobs.SessionReminderWorker` (in `lib/alethea_jobs/`), NOT `Alethea.Jobs.*`. `TelegramMessageWorker` and `TelegramOutboundWorker` live in `Alethea.Jobs.*`. Do not confuse the two namespaces.

## Phase 1: SessionSchedule (pure, foundation)

- [x] 1.1 RED — `test/alethea/accounts/session_schedule_test.exs`: `next_datetime/3` same-week future, same-day-time-passed→+7, DOW wrap-around, all with frozen `from`.
- [x] 1.2 GREEN — Create `lib/alethea/accounts/session_schedule.ex`, `next_datetime(dow, time, from \\ DateTime.utc_now())`, `DateTime.new(date, time, "Etc/UTC")` convention.
- [x] 1.3 REFACTOR — `mix test test/alethea/accounts/session_schedule_test.exs` green, no `mix format` diffs.

## Phase 2: SessionReminderWorker (delivery)

- [x] 2.1 RED — `test/alethea_jobs/session_reminder_worker_test.exs`: `perform/1` enqueues `Alethea.Jobs.TelegramOutboundWorker` with `%{chat_id, chat_id_hash, body: @reminder_message, patient_id: nil}`; drain `:telegram_outbound`; assert `Alethea.Telegram.Client.Fake.sends/0` contains `@reminder_message`.
- [x] 2.2 GREEN — Modify `lib/alethea_jobs/session_reminder_worker.ex`: repurpose no-op `perform/1` to `Oban.insert/1` a `TelegramOutboundWorker` job; add `@reminder_message` (static Spanish); add `unique: [keys: [:patient_id, :session_date], period: :infinity]`; keep `queue: :sessions`, `max_attempts: 3`.

## Phase 3: Enqueue trigger (TelegramMessageWorker)

- [x] 3.1 RED — `test/alethea/jobs/telegram_message_worker_reminder_test.exs`: happy path — `assert_enqueued worker: AletheaJobs.SessionReminderWorker, args: %{patient_id:, session_date:}`.
- [x] 3.2 RED — same file: 24h-guard skip — `refute_enqueued` when `reminder_at <= now`.
- [x] 3.3 RED — same file: no-schedule skip — nil `session_day_of_week`/`session_time` → `refute_enqueued`.
- [x] 3.4 RED — same file: idempotency — two inbound messages same window → `all_enqueued(worker: AletheaJobs.SessionReminderWorker)` length == 1.
- [x] 3.5 GREEN — Modify `lib/alethea/jobs/telegram_message_worker.ex`: private `schedule_session_reminder(legacy_patient, chat_id, chat_id_hash)`; call immediately after `schedule_telegram_session_timeout/4` at `:167` inside `process_bound_message/6`; compute `next`/`reminder_at`, guard `reminder_at > now`, `Oban.insert/1` ignoring conflict, reuse loaded `legacy_patient` (no extra query).

## Phase 4: Verification

- [x] 4.1 Confirm `test/alethea_jobs/daily_scheduler_worker_test.exs:61` untouched — `refute_enqueued(worker: AletheaJobs.SessionReminderWorker)` still passes (DailyScheduler never enqueues; only the inbound worker does).
- [x] 4.2 `mix precommit` (compile + format + test) green before PR.

## Review Workload Forecast

- Estimated changed lines: ~120-180 (3 lib: ~15 new + ~60 modified; 3 test: ~90-110 new)
- 400-line budget risk: **Low** · Chained PRs: **No** · Single PR
- Decision needed before apply: **No**

## Rollback boundary

Revert 3 lib files + delete 3 test files; `SessionReminderWorker.perform/1` reverts to inert `:ok`; `daily_scheduler_worker_test.exs:61` stays valid. No migration.
