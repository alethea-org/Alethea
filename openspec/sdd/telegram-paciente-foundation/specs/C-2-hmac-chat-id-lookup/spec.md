# Spec — C-2: HMAC-Hashed `telegram_chat_id` Lookup

**Capability:** C-2 — HMAC-hashed `telegram_chat_id` lookup
**Change:** `telegram-paciente-foundation`
**Status:** MODIFIED (replaces the un-encrypted `foundation_patients.telegram_chat_id`
column with a hashed variant; the old column is removed by migration, not aliased)
**Module(s):** `Alethea.Foundation.Accounts.Patient` (column rename), `Alethea.Foundation.Accounts`
(new `lookup_patient_by_chat_hash/1`), `Alethea.Telegram.ChatIdHash` (pure HMAC helper)

---

## Purpose

The system shall never store, query, or log a raw Telegram `chat_id`; the value
used as a lookup key SHALL be `HMAC-SHA256(chat_id, telegram_chat_id_pepper)`
encoded as lowercase hex, and the column name SHALL be `telegram_chat_id_hash`
with a partial unique index to prevent duplicate bindings while allowing the
column to remain nullable pre-onboarding.

---

## Requirements

## REQ-C2-chat-id-stored-as-hmac

The system shall store the Telegram `chat_id` only as
`HMAC-SHA256(chat_id, telegram_chat_id_pepper)` (lowercase hex, 64 chars) in the
column `foundation_patients.telegram_chat_id_hash`. The raw integer chat_id
shall not be present in any `INSERT`, `UPDATE`, or `SELECT` statement.

#### Scenario: onboarding persists the hash, not the raw id

- GIVEN a patient record with no `telegram_chat_id_hash` and a patient `id`
- AND a Telegram chat_id of `123456789` and a configured pepper `"pepper-v1"`
- WHEN the onboarding flow stores the binding
- THEN the persisted value in `telegram_chat_id_hash` is the lowercase hex of
  `HMAC-SHA256("123456789", "pepper-v1")`
- AND no row, log line, or telemetry event contains the literal `123456789`

#### Scenario: same chat_id + same pepper yields the same hash

- GIVEN the pepper `"pepper-v1"`
- WHEN the hash function is called twice with chat_id `"123456789"`
- THEN both calls return the identical 64-char lowercase hex string

#### Scenario: different pepper yields a different hash

- GIVEN two peppers `"pepper-v1"` and `"pepper-v2"`
- WHEN the hash function is called with chat_id `"123456789"` for each pepper
- THEN the two resulting hashes are not equal
- AND the hash function exposes no way to recover the raw chat_id from the
  hash alone (pure one-way HMAC, no decoding helper)

---

## REQ-C2-lookup-by-hash

The system shall provide `Alethea.Foundation.Accounts.lookup_patient_by_chat_hash/1`
that, given a 64-char hex hash, returns `{:ok, %Patient{}}` or `:not_found` —
and shall accept only the hash form as input.

#### Scenario: known hash returns the bound patient

- GIVEN a patient bound to hash `H`
- WHEN `lookup_patient_by_chat_hash(H)` is called
- THEN the result is `{:ok, %Patient{id: <that patient>}}`

#### Scenario: unknown hash returns :not_found

- GIVEN no patient is bound to hash `H_unknown`
- WHEN `lookup_patient_by_chat_hash(H_unknown)` is called
- THEN the result is `:not_found`
- AND no log line is emitted that contains the hash value (PHI hygiene)

#### Scenario: a raw chat_id is rejected at the API boundary

- GIVEN a chat_id integer `"123456789"` (not 64-char hex)
- WHEN `lookup_patient_by_chat_hash("123456789")` is called
- THEN the function returns `:not_found` (no false positive)
- AND the function shall not contain a code path that hashes the input on
  the caller side (callers must hash first, then look up)

---

## REQ-C2-partial-unique-index

The system shall enforce that at most one patient row is bound to a given hash
via a PostgreSQL partial unique index
`CREATE UNIQUE INDEX … ON foundation_patients (telegram_chat_id_hash) WHERE
telegram_chat_id_hash IS NOT NULL`, while allowing the column to be `NULL` for
patients who have not yet onboarded.

#### Scenario: second binding to the same hash fails at the DB layer

- GIVEN patient A is bound to hash `H`
- WHEN a transaction attempts to bind patient B to the same hash `H`
- THEN the transaction raises a unique-violation error
- AND no rollback compensation is required at the application layer (DB is
  the source of truth)

#### Scenario: multiple patients with NULL hash coexist

- GIVEN two patients with `telegram_chat_id_hash = NULL`
- WHEN both rows are inserted
- THEN both inserts succeed
- AND the unique index does not constrain the NULL case

#### Scenario: column is nullable, no placeholder

- GIVEN a patient who has not onboarded
- WHEN the patient row is read
- THEN `telegram_chat_id_hash` is `nil` (not a fixed sentinel string)

---

## REQ-C2-no-plaintext-in-logs

The system shall not emit a raw `chat_id` integer, nor a full hash, into any
log line, telemetry event, or exception message in the request lifecycle from
webhook receipt through worker completion.

#### Scenario: rejected webhook logs neither header nor body

- GIVEN the secret-token plug returns 401
- WHEN the request lifecycle emits logs
- THEN no `Logger` line contains the value of `X-Telegram-Bot-Api-Secret-Token`
- AND no `Logger` line contains a chat_id, a hash, or the raw payload

#### Scenario: worker logs the hash prefix only

- GIVEN a worker processes an inbound message
- WHEN the worker emits a progress `Logger.info` line
- THEN the line may include the first 8 chars of the hash (correlation token)
  and SHALL NOT include the full hash, the chat_id, or the message body

#### Scenario: error telemetry redacts chat_id

- GIVEN an exception occurs in the worker
- WHEN telemetry is reported
- THEN the `chat_id` field is absent
- AND the `telegram_chat_id_hash` field is present only as a 8-char prefix
