# Spec — C-3: Async Message Processing (Oban)

**Capability:** C-3 — Async message processing (Oban)
**Change:** `telegram-paciente-foundation`
**Status:** ADDED (no prior Telegram inbound worker exists)
**Module(s):** `AletheaJobs.TelegramMessageWorker`, Oban queue `telegram_inbound`

---

## Purpose

The system shall process every authenticated Telegram inbound `Update`
asynchronously in an Oban worker that is idempotent by `update_id`, persists the
inbound `Message`, schedules emotion analysis, and enqueues an outbound job —
keeping the webhook hot path off clinical work.

---

## Requirements

## REQ-C3-idempotent-by-update-id

The system shall declare the worker
`use Oban.Worker, queue: :telegram_inbound, max_attempts: 3, unique: [period:
86_400, keys: [:telegram_update_id]]`, so that Telegram retries and Oban
crash-retry within a 24-hour window do not produce duplicate processing.

#### Scenario: a single Update is processed once

- GIVEN a fresh `update_id = 100`
- WHEN the worker job is inserted and runs
- THEN exactly one inbound `Message` row is persisted for that update
- AND a second insert attempt for the same `update_id` is rejected by Oban's
  unique index (no second job)

#### Scenario: a duplicate Update within 24h is a no-op

- GIVEN job J1 for `update_id = 100` is already in the Oban jobs table
- WHEN the controller receives a Telegram retry for the same `update_id`
- AND the controller attempts to insert a second job
- THEN Oban returns the existing job
- AND no second `Message` row is created

#### Scenario: a duplicate Update after 24h is allowed

- GIVEN job J1 for `update_id = 100` was completed > 24h ago
- WHEN the controller receives a delayed Telegram retry for the same `update_id`
- THEN Oban allows a new job (the unique period has expired)
- AND the worker processes it normally (idempotency in this window is
  best-effort, matching Telegram's documented retry budget)

---

## REQ-C3-worker-resolves-patient

The system shall resolve the patient from the inbound hash via
`Alethea.Foundation.Accounts.lookup_patient_by_chat_hash/1` and shall handle the
`:not_found` case without raising.

#### Scenario: known patient is resolved

- GIVEN a patient bound to chat_id_hash `H`
- WHEN the worker runs
- THEN `lookup_patient_by_chat_hash(H)` returns `{:ok, %Patient{}}`
- AND processing continues

#### Scenario: unknown hash sends a one-shot "unregistered" reply

- GIVEN a chat_id_hash `H_unbound` with no bound patient
- WHEN the worker runs
- THEN a single outbound message is enqueued on `telegram_outbound` whose
  body is the localized "unregistered" copy
- AND the worker returns `:ok` (does not raise, does not crash-retry)

---

## REQ-C3-worker-persists-message

The system shall persist the inbound `Message` row with
`telegram_message_id`, `direction: "inbound"`, `source: "spontaneous"`,
`session_id` (nullable), and the `text` body — using the existing
`Alethea.Clinical.save_message/7` API.

#### Scenario: successful persistence

- GIVEN a resolved patient and a non-empty text payload
- WHEN the worker calls `Clinical.save_message/7`
- THEN one new `Message` row is inserted with `telegram_message_id`, the
  patient id, the direction, the source, and the body

#### Scenario: persistence failure crashes the job (retry-eligible)

- GIVEN the database is unreachable when `Clinical.save_message/7` runs
- WHEN the worker raises
- THEN Oban schedules a retry up to `max_attempts: 3`
- AND no outbound message is enqueued (the inbound was not recorded)

---

## REQ-C3-worker-emits-outbound-job

The system shall enqueue a `TelegramOutboundWorker` job with the reply text,
the `chat_id_hash`, and the priority lane, on every successful message
processing branch (safe and crisis).

#### Scenario: safe path emits an outbound job on telegram_outbound

- GIVEN a successful inbound persistence and a safe classification
- WHEN the worker reaches the emit step
- THEN one `TelegramOutboundWorker` job is inserted on queue
  `:telegram_outbound` with the LLM reply text and the chat_id_hash

#### Scenario: crisis path emits an outbound job on telegram_outbound_crisis

- GIVEN a successful inbound persistence and a crisis classification
- WHEN the worker reaches the emit step
- THEN one `TelegramOutboundWorker` job is inserted on queue
  `:telegram_outbound_crisis` with the preconfigured crisis reply text and
  the chat_id_hash

---

## REQ-C3-replay-duplicate-is-noop

The system shall short-circuit any worker invocation whose `update_id` matches a
`Message` already persisted in the last 24 hours, and shall return `:ok` without
firing the LLM or the outbound job.

#### Scenario: Oban-unique-prevented call is still a clean no-op

- GIVEN job J1 has already processed `update_id = 100` and persisted the Message
- WHEN Oban invokes the worker again for the same args (e.g. via test harness)
- THEN the worker returns `:ok`
- AND no second `Message` row is inserted
- AND no outbound job is enqueued
