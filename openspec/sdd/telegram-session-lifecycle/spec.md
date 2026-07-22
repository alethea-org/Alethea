# Spec: telegram-session-association

**Change:** telegram-session-lifecycle (#85) · New capability · Store: hybrid

## Purpose

Telegram inbound/outbound `Message` rows MUST associate with the patient's current open therapeutic `Session`, mirroring WhatsApp, for clinical continuity across channels. Fixed scope (Option B): single fetch + thread `session_id` into 3 save sites, crisis outbound included, NO automatic inactivity auto-close (deferred to #86).

## Requirements

### Requirement: Inbound Session Association

The system MUST fetch `SessionManager.current_open_session(legacy_patient.id)` exactly once in `process_bound_message`, after `legacy_patient` resolves and before the #84 `Repo.transaction`, and persist the inbound `Message` with that `session.id`.

#### Scenario: Non-crisis inbound opens or renews a session

- GIVEN a patient with no open session
- WHEN a non-crisis Telegram message is processed
- THEN `current_open_session/1` is called once
- AND the inbound `Message` carries the returned `session_id`

### Requirement: Safe-Path Outbound Session Association

The safe-path (elicited) outbound `Message`, persisted in `persist_and_enqueue_outbound` before the #84 `Repo.transaction`, MUST carry the SAME `session_id` from the single inbound fetch — no second `SessionManager` call.

#### Scenario: Safe-path outbound shares the inbound session

- GIVEN a non-crisis inbound message resolved `session.id`
- WHEN the elicited outbound reply is persisted
- THEN outbound `Message.session_id` equals inbound `Message.session_id`
- AND no additional `current_open_session/1` call occurs

### Requirement: Crisis-Path Outbound Session Association

The crisis-path outbound `Message` persisted in `handle_crisis_path` MUST carry the same `session_id` as the triggering inbound message.

#### Scenario: Crisis outbound shares the inbound session

- GIVEN a crisis-classified inbound message resolved `session.id`
- WHEN `handle_crisis_path` persists the crisis outbound reply
- THEN outbound `Message.session_id` equals inbound `Message.session_id`

### Requirement: Session Grouping Within an Open Window

Two or more messages from the same patient MUST share one `session_id` while the session remains open.

#### Scenario: Two messages while session is open

- GIVEN a patient's session (opened by a first message) remains open
- WHEN a second message arrives from the same patient
- THEN both messages' `session_id` values are equal

### Requirement: New Session After Explicit Close

A message arriving after the session is closed MUST open a NEW session with a new `session_id`. Automatic inactivity auto-close is OUT OF SCOPE (deferred to #86); tests simulate an elapsed window via `SessionManager.close_session/1`.

#### Scenario: Message after explicit close starts a new session

- GIVEN a patient's session was closed via `close_session/1`
- WHEN a new message arrives from that patient
- THEN the message carries a NEW `session_id`, different from the closed one

#### Scenario: No auto-close performed by the Telegram path

- GIVEN a patient's session is open past any hypothetical inactivity window
- WHEN a Telegram message is processed with no explicit `close_session/1` call
- THEN the existing open session is reused and no timeout worker is scheduled

### Requirement: Encryption Boundary Preserved

`session_id` MUST remain plaintext row metadata alongside `patient_id`, not inside the encrypted payload; patient-level encryption behavior MUST be unaffected.

#### Scenario: Session threading does not alter encryption

- GIVEN a Telegram message is persisted with a non-nil `session_id`
- WHEN the row is inserted via the existing `save_message` encryption path
- THEN content is encrypted via `PatientVault` as before
- AND `session_id` is stored as unencrypted metadata

### Requirement: No Timeout Worker Scheduled

The Telegram path MUST NOT schedule any `SessionTimeoutWorker` (or equivalent) job as part of this change.

#### Scenario: No timeout job enqueued

- GIVEN any Telegram message (safe or crisis path) is processed
- WHEN the worker completes `perform/1`
- THEN no `SessionTimeoutWorker` job exists in the Oban queue as a result

### Requirement: Session Membership Test Entry Point

Session-membership assertions MUST exercise the worker through its job-perform entry point (`%Oban.Job{args} |> perform()`), not internal helpers directly.

#### Scenario: Test asserts via perform/1

- GIVEN an `%Oban.Job{}` built with valid Telegram webhook args
- WHEN the test calls `TelegramMessageWorker.perform/1` on that job
- THEN inbound/outbound `Message` rows are queried and their `session_id` values asserted
