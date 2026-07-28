# Spec: session-timeout-channel-neutral (#86)

## Purpose

Define channel-neutral session auto-close (WhatsApp + Telegram) via `SessionTimeoutWorker`, and transactional atomicity for the Telegram crisis path. No existing spec file covers this domain; this is a full spec, not a delta.

## Requirements

### Requirement: Channel-Neutral Timeout Dispatch

The generalized `SessionTimeoutWorker` MUST, on fire: close the session (`SessionManager.close_session/1`), generate summary + trends via the existing channel-independent pipeline (RoBERTa analysis + `SessionSummaryChain`), and send the goodbye message via the channel indicated in the job args.

#### Scenario: Telegram session times out

- GIVEN an open session with a scheduled `SessionTimeoutWorker` job carrying `channel: "telegram"`
- WHEN the job fires
- THEN the session is closed, summary + trends are persisted, and the goodbye is sent via the Telegram outbound path

#### Scenario: Session already closed (idempotency)

- GIVEN a session already `status: "closed"`
- WHEN the timeout job fires
- THEN the worker skips the close/summary/goodbye flow without error

### Requirement: WhatsApp Backward Compatibility

`perform/1` MUST accept the existing `%{session_id, patient_id, phone}` args shape unchanged. WHEN `channel` is absent AND `phone` is present, the worker MUST default to `"whatsapp"`.

#### Scenario: Legacy WhatsApp args, no channel key

- GIVEN a job enqueued with `%{session_id:, patient_id:, phone:}` and no `channel` key
- WHEN the job fires
- THEN the worker treats the channel as `"whatsapp"` and sends the goodbye via the WhatsApp client

#### Scenario: Existing WhatsApp tests remain green

- GIVEN the 2 existing tests in `session_timeout_worker_test.exs`
- WHEN they run unmodified against the generalized worker
- THEN both pass without any test-file changes

### Requirement: Telegram Timeout Job Args

WHEN enqueuing a Telegram timeout job, the caller MUST include `channel: "telegram"`, `chat_id`, and `chat_id_hash` in the args, since the raw `chat_id` is never persisted at rest and cannot be reconstructed from stored state.

#### Scenario: Telegram job carries routing identifiers

- GIVEN a Telegram inbound message successfully saved
- WHEN the timeout job is enqueued
- THEN its args include `channel: "telegram"`, `chat_id`, and `chat_id_hash`

### Requirement: Telegram Timeout Enqueue On Inbound Save

`TelegramMessageWorker` MUST enqueue a session-timeout job immediately after a successful inbound save, from one call site covering both the safe and crisis branches. Renewal (Oban unique args + `replace: [:scheduled_at]`) MUST push the close-timer out on each new inbound message.

#### Scenario: Safe-path message renews timeout

- GIVEN an open Telegram session with a previously scheduled timeout job
- WHEN a new safe-path inbound message is saved
- THEN the existing timeout job's `scheduled_at` is replaced/pushed out rather than duplicated

#### Scenario: Crisis-path message also enqueues/renews timeout (replaces #85 refute)

- GIVEN an open Telegram session
- WHEN a crisis-path inbound message is saved successfully
- THEN a session-timeout job is asserted enqueued (replacing the prior `refute_enqueued` assertion at `telegram_message_worker_test.exs:446-458`)

### Requirement: Crisis-Path Transactional Atomicity

The crisis-path patient update, AI diagnosis save, and crisis outbound message save MUST execute inside one `Repo.transaction`. WHEN any of the three steps fails, the entire set MUST roll back with no partial commit.

#### Scenario: All crisis writes succeed

- GIVEN a valid crisis-path inbound message
- WHEN patient update, diagnosis save, and outbound save all succeed
- THEN all three are committed together

#### Scenario: One crisis write fails

- GIVEN a valid crisis-path inbound message
- WHEN the outbound message save fails
- THEN the patient update and diagnosis save are also rolled back (no row persists from any of the three)

### Requirement: Post-Commit Crisis Side Effects

The PubSub crisis broadcast and the crisis outbound enqueue MUST occur only after the transaction commits. WHEN the transaction fails, neither the broadcast nor the enqueue MUST fire.

#### Scenario: Broadcast after commit

- GIVEN the crisis transaction commits successfully
- WHEN post-commit side effects run
- THEN the PubSub `:crisis_detected` broadcast fires and the outbound job is enqueued

#### Scenario: No broadcast on failed commit

- GIVEN the crisis transaction fails
- WHEN the worker returns
- THEN no PubSub broadcast fires and no outbound job is enqueued

### Requirement: Crisis Persistence Failure Safety (R3)

A forced failure on any transacted crisis step MUST result in no partial commit, no PHI in the raised/returned error, and no crisis broadcast, verified through the worker's `perform/1` entry point.

#### Scenario: Forced outbound-save failure via perform/1

- GIVEN a crisis-path job that will fail on the outbound save step
- WHEN `perform/1` is invoked
- THEN no patient-update, diagnosis, or outbound row persists; the error contains no PHI; and no crisis broadcast is observed

## Deferred / Out of Scope

- **R1-W1 staleness race**: documented accepted risk (mirrors pre-existing WhatsApp race in `ProcessMessageWorker`); NOT fixed by this change. No lock/age-check added to `current_open_session/1`.
- No `channel` column or migration on `clinical_sessions` / `Session` schema.
- No change to `SessionManager.current_open_session/1` semantics or locking.
- Pre-existing duplicate `telegram_message_id` `MatchError` is untouched.
