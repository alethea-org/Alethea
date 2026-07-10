# Spec — C-4: Deep-Link Onboarding with Ephemeral Token

**Capability:** C-4 — Deep-link onboarding with ephemeral token
**Change:** `telegram-paciente-foundation`
**Status:** ADDED (this slice introduces the `foundation_patient_auth_codes` table,
the `TelegramOnboardingWorker`, and the auth controller)
**Module(s):** `Alethea.Telegram.DeepLinkToken`, `Alethea.Foundation.Accounts.PatientAuthCode`,
`AletheaJobs.TelegramOnboardingWorker`, `AletheaWeb.TelegramAuthController`

---

## Purpose

The system shall onboard a Telegram chat to a patient row using a short-lived
URL-safe token delivered via `t.me/<bot>?start=<token>`, with a six-digit code
retained as a manual fallback that shares the same
`foundation_patient_auth_codes` table; the token is single-use, time-boxed to 10
minutes, and rate-limited to 5 attempts per hour per IP.

---

## Requirements

## REQ-C4-mint-deep-link-token

The system shall provide `Alethea.Telegram.DeepLinkToken.mint/1` that, given a
`patient_id`, creates a `foundation_patient_auth_codes` row with
`kind: "deep_link"`, a 32-byte URL-safe token, `expires_at = now + 10 min`,
`used_at: nil`, `attempt_count: 0`, and `last_attempt_ip: nil`.

#### Scenario: fresh token is mintable

- GIVEN a patient `id`
- WHEN `create_patient_auth_code(patient_id, kind: "deep_link")` is called
- THEN one row is inserted
- AND `kind == "deep_link"`
- AND `expires_at` is exactly 600 seconds after `inserted_at`
- AND the code is a 43–44 char URL-safe base64 string (32 raw bytes)
- AND `used_at` is `nil` and `attempt_count` is 0

#### Scenario: two mints for the same patient are independently unique

- GIVEN a patient `id`
- WHEN `create_patient_auth_code(patient_id, kind: "deep_link")` is called twice
- THEN two rows are inserted
- AND the two `code` values are not equal (collision probability ≈ 2^-192)

---

## REQ-C4-bind-chat-on-success

The system shall, on successful token verification, set
`patient.telegram_chat_id_hash` to the HMAC-SHA256 of the chat_id with the
configured pepper, mark the auth code's `used_at` to the current UTC time, and
enqueue a welcome message on the outbound queue.

#### Scenario: valid + unexpired + unused token binds the chat

- GIVEN a valid `code`, an unexpired row, `used_at = nil`, and a chat_id `C`
- WHEN `verify_patient_auth_code(code, ip, kind: "deep_link")` returns `:ok`
- AND the onboarding worker calls `consume_patient_auth_code(code)`
- THEN the patient row's `telegram_chat_id_hash` equals
  `HMAC-SHA256(C, pepper)`
- AND the auth code's `used_at` equals the current UTC time
- AND one `TelegramOutboundWorker` job is enqueued on `:telegram_outbound`
  with the personality-aware welcome text

#### Scenario: token is single-use

- GIVEN the auth code was just consumed (`used_at` set)
- WHEN `verify_patient_auth_code(code, ip, kind: "deep_link")` is called again
- THEN the result is `:already_used`
- AND the patient row's `telegram_chat_id_hash` is not overwritten
- AND no second welcome message is enqueued

---

## REQ-C4-reject-expired-token

The system shall reject any token whose `expires_at` is in the past, returning
`:expired` from `verify_patient_auth_code/3`, and shall send the patient a
localized "tu link venció" message via the outbound queue.

#### Scenario: token past its TTL is expired

- GIVEN an auth code row with `expires_at = now - 1s`
- WHEN `verify_patient_auth_code(code, ip, kind: "deep_link")` is called
- THEN the result is `:expired`
- AND a localized "expired" message is enqueued on `:telegram_outbound`
- AND the auth code row is not mutated (no `used_at`, no `attempt_count++`)

#### Scenario: token at the boundary is still valid

- GIVEN an auth code row with `expires_at = now + 1s`
- WHEN `verify_patient_auth_code(code, ip, kind: "deep_link")` is called
- THEN the result is `:ok` (TTL is exclusive of the boundary)
- AND the chat is bound as in the success case

---

## REQ-C4-reject-already-used-token

The system shall reject any token whose `used_at` is set, returning
`:already_used`, and shall send a localized "este link ya fue usado" message via
the outbound queue.

#### Scenario: consumed token is rejected on re-use

- GIVEN an auth code with `used_at` set
- WHEN `verify_patient_auth_code(code, ip, kind: "deep_link")` is called
- THEN the result is `:already_used`
- AND a localized "already used" message is enqueued on `:telegram_outbound`

---

## REQ-C4-reject-rate-limited

The system shall track attempts per `last_attempt_ip` within a rolling
1-hour window and shall return `:rate_limited` once the 5th attempt is reached
for the same IP, sending a localized "demasiados intentos" message via the
outbound queue.

#### Scenario: 5th attempt in the window returns :rate_limited

- GIVEN 4 prior verification calls from the same IP within the last hour
- WHEN a 5th call from the same IP is made
- THEN the result is `:rate_limited`
- AND a localized "rate limited" message is enqueued on `:telegram_outbound`
- AND `attempt_count` is incremented on a 6th attempt's earlier rows (so the
  audit trail reflects the cap being hit)

#### Scenario: 5th attempt across a different IP is allowed

- GIVEN 4 prior verification calls from IP A within the last hour
- WHEN a 5th call from IP B is made
- THEN the result is `:ok` (rate-limit is per-IP, not global)
- AND the chat is bound as in the success case

#### Scenario: attempts older than 1h do not count

- GIVEN 4 verification calls from IP A 2 hours ago
- WHEN a 5th call from IP A is made
- THEN the result is `:ok` (the rolling window has rolled off)
- AND the chat is bound as in the success case

---

## REQ-C4-six-digit-fallback

The system shall accept a 6-digit code through the same `TelegramAuthController`
`consume/2` action under the `?code=<6digit>` query parameter, treating the
value as a `kind: "six_digit"` row in `foundation_patient_auth_codes` with the
same TTL, single-use, and rate-limit semantics as the deep-link path.

#### Scenario: 6-digit code from the web invite page binds the chat

- GIVEN an auth code row with `kind: "six_digit"`, `code = "482915"`,
  `used_at = nil`, and `expires_at = now + 10 min`
- WHEN the patient visits `/webhooks/telegram/auth?code=482915&chat_id=9001`
- THEN the patient is bound to `HMAC-SHA256("9001", pepper)`
- AND `used_at` is set to the current UTC time
- AND a welcome message is enqueued

#### Scenario: 6-digit code is rate-limited identically

- GIVEN 4 prior failed attempts from the same IP for `kind: "six_digit"`
- WHEN a 5th attempt is made from the same IP
- THEN the result is `:rate_limited`
- AND the rate-limit window is independent from the deep-link kind
  (deep-link attempts and six-digit attempts do not share a counter)

#### Scenario: six_digit code cannot be redeemed via /start

- GIVEN an auth code with `kind: "six_digit"`, `code = "482915"`
- WHEN the patient sends `/start 482915` to the bot
- THEN the system rejects the attempt
- AND no chat binding occurs
- AND the six_digit code's `used_at` is not mutated

---

## REQ-C4-send-welcome-reply

The system shall enqueue exactly one welcome message per successful binding,
routed to `telegram_outbound` (not the crisis lane), with the personality-aware
text configured for that patient.

#### Scenario: welcome message is enqueued once per binding

- GIVEN a successful binding
- WHEN the onboarding worker emits the welcome
- THEN exactly one `TelegramOutboundWorker` job is inserted
- AND the queue is `:telegram_outbound`
- AND the body is the localized welcome text with the patient's first name

#### Scenario: no welcome is sent on failure branches

- GIVEN an expired, already-used, or rate-limited attempt
- WHEN the onboarding worker reaches the emit step
- THEN only the localized error message is enqueued
- AND the patient is NOT bound
- AND no welcome message is enqueued

---

## REQ-C4-reject-chat-bound-to-other-patient

The system shall, when a valid (unexpired, unused, not rate-limited) auth
code's `telegram_chat_id_hash` collision resolves to a patient row other than
the auth code's own `patient_id`, reject the bind, leave both patient rows
unmodified, NOT mark the auth code as used, and send a localized "este
Telegram ya está vinculado a otro paciente, contactá a tu psicólogo" message
via the outbound queue. The bind relies on the existing
`foundation_patients_telegram_chat_id_hash_unique` partial index
(`Alethea.Foundation.Accounts.Patient.changeset/2`); this requirement defines
the application-level handling of that constraint violation, not a new DB
constraint.

A patient rebinding their own prior `telegram_chat_id_hash` (e.g. a new phone)
is not this scenario — that update targets the same patient row and never
hits the unique index, so it is unaffected by this requirement.

#### Scenario: chat_id_hash already bound to a different patient is rejected

- GIVEN patient A is already bound to `telegram_chat_id_hash = H`
- AND patient B has a valid, unexpired, unused auth code
- WHEN patient B's chat sends `/start <token>` from the chat that hashes to `H`
- THEN the bind attempt returns `{:error, :chat_bound_to_other_patient}`
- AND patient A's row is unchanged
- AND patient B's row is NOT bound
- AND patient B's auth code `used_at` remains `nil` (not consumed — the
  professional can issue a fresh token once the collision is resolved)
- AND a localized "already bound to another patient" message is enqueued on
  `:telegram_outbound`

#### Scenario: same patient rebinding their own chat is allowed

- GIVEN patient A is already bound to `telegram_chat_id_hash = H1`
- AND patient A has a valid, unexpired, unused auth code minted for a new chat
- WHEN patient A's new chat (hash `H2`) consumes the auth code
- THEN patient A's row is updated to `telegram_chat_id_hash = H2`
- AND the auth code's `used_at` is set
- AND a welcome message is enqueued as in the standard success case
