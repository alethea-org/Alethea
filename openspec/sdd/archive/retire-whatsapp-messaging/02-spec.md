# Spec: Retire WhatsApp Messaging Path (#87)

## Purpose

Removal-only change. No new capability. This spec defines the observable
END-STATE guarantees after the WhatsApp message path is retired, plus
non-regression guarantees for the Telegram path, across chained PR-A
(pure removal + reminder disable) and PR-B (client + shared-worker cleanup).

## Requirements

### Requirement: No WhatsApp Inbound Path

The system MUST NOT expose any route, controller, or worker that ingests
WhatsApp patient messages.

#### Scenario: Webhook route removed

- GIVEN the router configuration after PR-A
- WHEN inspecting `AletheaWeb.Router`
- THEN no `/webhooks/whatsapp` route (GET or POST) exists
- AND `WhatsappWebhookController` and `ProcessMessageWorker` no longer exist as modules

#### Scenario: WhatsApp Oban queue absent

- GIVEN the Oban configuration after PR-A
- WHEN inspecting `config/*.exs`
- THEN no `:whatsapp` queue is configured
- AND no `WHATSAPP_*` runtime env vars are referenced

### Requirement: No WhatsApp Patient Messaging Egress

The system MUST NOT send patient messages via WhatsApp on any code path.

#### Scenario: Session reminders disabled

- GIVEN `DailyScheduler` runs its daily job after PR-A
- WHEN a patient has a session tomorrow
- THEN `SessionReminderWorker` is NOT enqueued
- AND no WhatsApp send is attempted for reminders

#### Scenario: Reminder worker inert if invoked directly

- GIVEN `SessionReminderWorker.perform/1` is called directly (e.g. stale job)
- WHEN it executes after PR-A
- THEN it performs no WhatsApp send and completes without error
- AND this is out of scope for a Telegram-equivalent (tracked in #97)

### Requirement: App Boots Clean Without WhatsApp Supervision

The application supervision tree MUST NOT reference deleted WhatsApp modules.

#### Scenario: Supervision tree lockstep

- GIVEN `Alethea.Application.start/2` after PR-A
- WHEN the app boots
- THEN it starts successfully with no `WhatsApp.ConsentCache` or `RateLimiter` children
- AND the app does not crash from referencing a deleted module

#### Scenario: Compiles warning-free

- GIVEN the codebase after PR-A and after PR-B
- WHEN running `mix compile --warnings-as-errors`
- THEN compilation succeeds with zero warnings at each PR boundary

### Requirement: Telegram Path Non-Regression

Telegram journaling, crisis handling, session lifecycle, session summaries,
and the channel-neutral `SessionTimeoutWorker` Telegram path MUST remain
unchanged and green.

#### Scenario: Telegram journaling and crisis unaffected

- GIVEN the WhatsApp path is removed (PR-A) or fully retired (PR-B)
- WHEN a Telegram patient sends a message, including a crisis-flagged message
- THEN journaling, crisis handling, and session lifecycle behave identically to before the change

#### Scenario: SessionTimeoutWorker Telegram branch intact

- GIVEN `SessionTimeoutWorker` after PR-B
- WHEN a Telegram session times out
- THEN the Telegram goodbye-message branch executes exactly as before
- AND no `whatsapp` branch remains in `perform/1` or `send_goodbye/2`

### Requirement: Full Test Suite Green at Each PR Boundary

`mix test` MUST pass with WhatsApp seams removed, independently at PR-A and PR-B.

#### Scenario: PR-A boundary green

- GIVEN PR-A is applied in isolation (PR-B not yet merged)
- WHEN running `mix test`
- THEN the full suite passes
- AND `config/test.exs :whatsapp_client` and the `test_helper.exs` `WhatsApp.ClientMock` defmock still exist (still used by `session_timeout_worker_test` and `session_reminder_worker_test`/removal)

#### Scenario: PR-B boundary green

- GIVEN PR-B is applied on top of PR-A
- WHEN running `mix test`
- THEN the full suite passes
- AND no test references `Alethea.WhatsApp.Client`, `ClientBehaviour`, or `ClientMock`

### Requirement: PR-B End State Has No WhatsApp Client References

By the end of PR-B, no code or test MUST reference the WhatsApp client stack.

#### Scenario: Client modules deleted

- GIVEN PR-B is merged
- WHEN searching the codebase for `Alethea.WhatsApp.Client` or `ClientBehaviour`
- THEN no references exist in `lib/`, `test/`, or `config/`

#### Scenario: SessionTimeoutWorker has no whatsapp branch

- GIVEN PR-B is merged
- WHEN inspecting `SessionTimeoutWorker.perform/1` and `send_goodbye/2`
- THEN only the Telegram (and any other live channel) branch remains
- AND `whatsapp_client/0` no longer exists

## Out of Scope (explicit non-requirements)

- Schema strip: `messages.whatsapp_message_id`, `patients.whatsapp_number_hash`,
  `patients.encrypted_whatsapp_number` remain dead-but-harmless. `NOT NULL`
  removal, `create_patient/2` rule change, and `PatientLive.Index` UI change
  are NOT part of this spec.
- Telegram reminder equivalent: tracked separately in #97. Reminders remain
  OFF (not migrated) as an accepted end state of this change.
