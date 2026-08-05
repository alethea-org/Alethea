# Spec — telegram-session-reminders (#97)

## Purpose

Patients scheduled for a therapy session receive a Telegram reminder ~24h in advance, enqueued opportunistically during a live inbound Telegram message (no raw `chat_id` at rest beyond the existing `oban_jobs.args` PHI surface). New capability — no prior spec exists for this domain.

## Requirements

### Requirement: Reminder Enqueue at Inbound-Message Processing

The system MUST enqueue exactly one `AletheaJobs.SessionReminderWorker` job, scheduled for `next_session - 24h`, when a live inbound Telegram message is processed for a patient who has BOTH a session schedule (`session_day_of_week` + `session_time`) AND a Telegram binding, AND `next_session - 24h` is still in the future at processing time.

#### Scenario: Patient has schedule and Telegram binding, window still open
- GIVEN a patient with `session_day_of_week`/`session_time` set and a Telegram binding
- AND `next_session - 24h` is in the future
- WHEN an inbound Telegram message from this patient is processed
- THEN a `SessionReminderWorker` job is enqueued with `scheduled_at` equal to `next_session - 24h`
- AND the job args carry the plaintext `chat_id` and `chat_id_hash`

#### Scenario: No schedule configured
- GIVEN a patient with a Telegram binding but no `session_day_of_week`/`session_time`
- WHEN an inbound Telegram message is processed
- THEN no `SessionReminderWorker` job is enqueued

#### Scenario: No Telegram binding
- GIVEN a patient with a schedule but no Telegram binding
- WHEN an inbound Telegram message is processed
- THEN no `SessionReminderWorker` job is enqueued

#### Scenario: Reminder window already past
- GIVEN a patient with a schedule and Telegram binding
- AND the patient interacts within 24h of their next session (`next_session - 24h` is already in the past)
- WHEN the inbound Telegram message is processed
- THEN no `SessionReminderWorker` job is enqueued for that session

### Requirement: Reminder Delivery via TelegramOutboundWorker

The system MUST deliver the reminder through the existing `Alethea.Jobs.TelegramOutboundWorker`, using the `chat_id`/`chat_id_hash` carried in the reminder job's args, with a static Spanish message body (no Phi-generated content).

#### Scenario: Reminder fires and delivers
- GIVEN an enqueued `SessionReminderWorker` job with `chat_id` and `chat_id_hash` args
- WHEN the job executes at its `scheduled_at` time
- THEN a `TelegramOutboundWorker` job is enqueued/executed with the same `chat_id` and `chat_id_hash`
- AND `Alethea.Telegram.Client.Fake.sends/0` records exactly one message to that `chat_id` with the static Spanish reminder body

### Requirement: Idempotent Reminder Dedup

The system MUST NOT enqueue more than one reminder job per (patient, session target date). Repeated inbound messages from the same patient within the same reminder window MUST produce exactly one scheduled job (Oban `unique` keyed on patient + target date).

#### Scenario: Repeated inbound messages within the same window
- GIVEN a patient with a schedule and Telegram binding, reminder window still open
- WHEN the patient sends multiple inbound Telegram messages before `next_session - 24h` elapses
- THEN exactly one `SessionReminderWorker` job exists for that (patient, session target date)
- AND no duplicate reminder is ever delivered

### Requirement: No WhatsApp Delivery Path

The system MUST NOT reintroduce any WhatsApp messaging dependency for reminder enqueue or delivery. Reminders MUST use only the Telegram delivery pipeline and the existing one-way `chat_id_hash` scheme; no new plaintext-`chat_id`-at-rest surface beyond the existing `oban_jobs.args` pattern is introduced.

#### Scenario: Reminder pipeline has no WhatsApp code path
- GIVEN the reminder feature is enabled
- WHEN a reminder is enqueued and delivered
- THEN no WhatsApp client, worker, or WhatsApp-specific job args are invoked at any point in the flow

### Requirement: Silent-Patient Gap (documented non-requirement)

The system is NOT required to remind a patient who sends no inbound Telegram message between their previous session and `next_session - 24h`. This is an accepted, documented limitation of the enqueue-at-interaction approach — not a defect to be fixed by this change.

#### Scenario: Patient does not interact before the reminder window
- GIVEN a patient with a schedule and Telegram binding
- AND the patient sends no inbound Telegram message between their previous session and `next_session - 24h`
- WHEN `next_session - 24h` arrives
- THEN no reminder job exists for that patient/session and none is expected — out-of-scope behavior, not a regression
