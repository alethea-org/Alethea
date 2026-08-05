# Design — telegram-session-reminders (#97)

## Technical approach

Approach A "enqueue-at-interaction" (LOCKED). During a live inbound Telegram message — the only moment the plaintext `chat_id` exists in-process — the inbound worker computes the patient's next weekly session and, if it is more than 24h away, enqueues a `SessionReminderWorker` scheduled for `next_session - 24h`. The reminder worker later enqueues a `TelegramOutboundWorker` job carrying the plaintext `chat_id` (same bounded PHI-at-rest surface in `oban_jobs.args` already accepted for the goodbye path, `session_timeout_worker.ex:47-105`). No cron, no stored/decryptable chat_id, no new DB column. The inert `SessionReminderWorker` (#87) is repurposed.

## Architecture decisions

### Enqueue trigger site
Add a private `schedule_session_reminder(legacy_patient, chat_id, chat_id_hash)` call in `Alethea.Jobs.TelegramMessageWorker` immediately after `schedule_telegram_session_timeout/4` (`telegram_message_worker.ex:167`), inside `process_bound_message/6`. Line 167 is the single post-inbound-save point shared by both the safe and crisis branches, where `session`, the schedule-bearing `legacy_patient` (loaded at :131), `chat_id`, and `chat_id_hash` are all in scope. Mirrors the exact seam the session-timeout enqueue already uses — least-invasive, both branches covered by one call.

### Next-session computation (extract vs reuse)
Add a pure helper `Alethea.Accounts.SessionSchedule.next_datetime(dow, time, from \\ DateTime.utc_now())` in the domain core; do NOT refactor `DailySchedulerWorker` (it computes a *different* thing — "tomorrow's fixed slot" filtered by `session_day_of_week == tomorrow_dow`, not a general next-occurrence). Reuse only the UTC convention `DateTime.new(date, time, "Etc/UTC")` (`daily_scheduler_worker.ex:22`) to stay timezone-consistent. The weekly-slot math (wrap-around, same-day-time-passed) warrants isolated unit tests, so it earns a pure module.

```elixir
def next_datetime(dow, time, from) do
  today = DateTime.to_date(from)
  days = Integer.mod(dow - Date.day_of_week(today) + 7, 7)
  {:ok, dt} = DateTime.new(Date.add(today, days), time, "Etc/UTC")
  if DateTime.compare(dt, from) == :gt, do: dt,
    else: (Date.add(today, days + 7) |> DateTime.new(time, "Etc/UTC") |> elem(1))
end
```

### 24h guard location
In the worker-side `schedule_session_reminder/3` helper: compute `reminder_at = DateTime.add(next_session, -24, :hour)`; enqueue only when `DateTime.compare(reminder_at, now) == :gt`, else silent skip. Keeps enqueue orchestration local to the trigger site (consistent with the timeout's local philosophy).

### Idempotency key
Module-level `unique: [keys: [:patient_id, :session_date], period: :infinity]` on `SessionReminderWorker`. Concrete args:

```elixir
%{patient_id: legacy_patient.id,
  session_date: Date.to_iso8601(DateTime.to_date(next_session)),
  chat_id: chat_id, chat_id_hash: chat_id_hash}
```

Repeated inbound messages during the pre-session window resolve to the same `(patient_id, session_date)` tuple, so Oban drops the duplicate insert. `chat_id`/`chat_id_hash` ride in args for delivery but are excluded from the uniqueness key. `:infinity` holds dedup across the whole pre-session window; next week's session yields a new `session_date`, so a fresh reminder is allowed. Use `Oban.insert/1` and ignore the conflict result.

### Worker shape (deliver vs send)
`SessionReminderWorker.perform/1` ENQUEUES a `TelegramOutboundWorker` job (goodbye pattern, `session_timeout_worker.ex:253-259`); it does not call `Telegram.Client` directly (direct send would bypass `Pacer` rate-limiting + dead-letter/retry). Keep queue `:sessions`, `max_attempts: 3`. Outbound args: `%{chat_id, chat_id_hash, body: @reminder_message, patient_id: nil}` (`patient_id: nil` matches the goodbye — non-clinical logistics).

### Static message
```elixir
@reminder_message """
Recordatorio: tienes una sesión programada para mañana. Si no puedes asistir, avisa a tu terapeuta con anticipación.
"""
```
Neutral clinical Spanish, logistics only. Does not validate cognitive distortions, does not adopt a warm/validating tone (persona rules). "mañana" is accurate because the reminder fires exactly 24h before the slot.

### Skip semantics
- **No schedule** (`session_day_of_week`/`session_time` nil) → silent skip, no log.
- **Past/inside-window** (`reminder_at <= now`) → silent skip, no log (fires on nearly every inbound within 24h; logging would be noise).
- **No Telegram binding** → not reachable here: this seam runs only inside `process_bound_message/6`, where the patient was already resolved by `chat_id_hash`.

### Identity resolution
The inbound path is Telegram-native → `Foundation.Accounts.Patient`. Schedule fields live only on legacy `Alethea.Accounts.Patient` (`patient.ex:15-16`). The bridge is already walked at `telegram_message_worker.ex:130-131`: `FoundationAccounts.legacy_patient(foundation_patient)` → `Accounts.get_patient_with_professional(id)`. The reminder helper consumes that already-loaded `legacy_patient` — no extra query.

## Data flow

```
Inbound Telegram msg
  └─ TelegramMessageWorker.process_bound_message/6   (chat_id, chat_id_hash, legacy_patient, session in scope)
        ├─ schedule_telegram_session_timeout/4        (existing, :167)
        └─ schedule_session_reminder/3                 (NEW, after :167)
              │ next = SessionSchedule.next_datetime(dow, time, now)
              │ reminder_at = next - 24h
              │ guard: reminder_at > now ? enqueue : skip
              ▼
        SessionReminderWorker (queue :sessions, unique patient_id+session_date, scheduled_at: reminder_at)
              │ perform/1 → enqueue TelegramOutboundWorker
              ▼
        TelegramOutboundWorker (:telegram_outbound) → Pacer → Client.send_message → patient
```

## File changes

| File | Action | Description |
|------|--------|-------------|
| `lib/alethea/accounts/session_schedule.ex` | Create | Pure `next_datetime/3` next-weekly-occurrence helper (UTC, wrap-around) |
| `lib/alethea_jobs/session_reminder_worker.ex` | Modify | Repurpose no-op → enqueue `TelegramOutboundWorker`; add `@reminder_message`; `unique: [keys: [:patient_id, :session_date], period: :infinity]` |
| `lib/alethea/jobs/telegram_message_worker.ex` | Modify | Add `schedule_session_reminder/3` + call after :167 (24h guard, skip semantics) |
| `test/.../session_schedule_test.exs` | Create | Pure unit tests for next-occurrence + wrap-around |
| `test/.../telegram_message_worker_reminder_test.exs` | Create | Enqueue / guard / skip / idempotency integration tests |
| `test/.../session_reminder_worker_test.exs` | Create | perform → outbound enqueue + message body |

## Interfaces

```elixir
Alethea.Accounts.SessionSchedule.next_datetime(dow :: 1..7, time :: Time.t(), from :: DateTime.t()) :: DateTime.t()

# SessionReminderWorker args (enqueued by TelegramMessageWorker)
%{patient_id: binary_id, session_date: iso8601_string, chat_id: integer, chat_id_hash: string}

# TelegramOutboundWorker args (enqueued by SessionReminderWorker.perform/1) — existing contract
%{chat_id: integer, chat_id_hash: string, body: string, patient_id: nil}
```

## Testing strategy

| Layer | What | Approach |
|-------|------|----------|
| Unit | `next_datetime/3`: same-week future, same-day-time-passed → +7, DOW wrap-around | Pure, frozen `from` |
| Integration | Reminder enqueued when next session > 24h | `testing: :manual`; `assert_enqueued worker: SessionReminderWorker, args: %{patient_id:, session_date:}` |
| Integration | 24h guard skip (session within 24h) | `refute_enqueued worker: SessionReminderWorker` |
| Integration | No-schedule skip (nil dow/time) | `refute_enqueued` |
| Integration | Idempotency: two inbound msgs, same session_date | `all_enqueued(worker: SessionReminderWorker)` length == 1 |
| Integration | Delivery: drain `:sessions` → outbound enqueued → drain `:telegram_outbound` → `Fake.sends()` contains `@reminder_message` | `Oban.drain_queue/2` + `Fake.sends/0` |

## ADR — enqueue-at-interaction vs cron+stored-chat_id (decided)

Chosen: enqueue-at-interaction. The rejected cron alternative would require a scheduled scan that reaches Telegram, but the plaintext `chat_id` exists nowhere at rest in decryptable form (`ChatIdHash` is one-way HMAC, no encrypted column). A cron path would force either storing a reversible chat_id (new PHI-at-rest surface, violates the one-way-hash posture) or being unable to address Telegram at all. Enqueue-at-interaction reuses the exact bounded surface already accepted for the goodbye dispatch, adds zero new persistent PHI, needs no schema change. Trade-off accepted: a silent patient (never messages in the pre-session window) receives no reminder.

## Open questions / risks

- **Timezone**: `session_time` is stored tz-naive and interpreted as UTC by the existing `DailySchedulerWorker`. If slots are actually local time, "mañana" and the 24h offset drift by the UTC offset. Design follows the existing UTC convention; a real timezone field is a separate follow-up.
- **`daily_scheduler_worker_test.exs:61`**: its `refute_enqueued(worker: SessionReminderWorker)` stays VALID under Approach A (DailyScheduler still never enqueues the reminder — the inbound worker does), so it does NOT need updating. (Corrects the proposal's Affected-areas note.)
- **Schedule change mid-window**: a patient who changes `session_day_of_week` mid-window could get an old-target and new-target reminder (different `session_date` keys) — acceptable, at most one extra logistics message.
- **PHI-at-rest**: `chat_id` in `oban_jobs.args` reused, not expanded; no `Oban.Plugins.Pruner` configured, so args accumulate like existing jobs (pre-existing gap, not introduced here).
