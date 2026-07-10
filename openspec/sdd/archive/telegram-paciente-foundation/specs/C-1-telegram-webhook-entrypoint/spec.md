# Spec — C-1: Telegram Webhook Entrypoint

**Capability:** C-1 — Telegram webhook entrypoint
**Change:** `telegram-paciente-foundation`
**Status:** ADDED (no prior behavior to reference; this slice introduces the entrypoint)
**Module(s):** `AletheaWeb.TelegramWebhookController`, `AletheaWeb.Plugs.TelegramSecretToken`
**Route:** `POST /webhooks/telegram`

---

## Purpose

The system shall expose a single Telegram webhook endpoint that authenticates the
sender via the `X-Telegram-Bot-Api-Secret-Token` header, fast-acks within Telegram's
delivery window, and enqueues an Oban job for asynchronous processing — keeping the
hot path free of clinical work and resistant to spoofing.

---

## Requirements

## REQ-C1-secret-token-validates-header

The system shall reject every `POST /webhooks/telegram` request whose
`X-Telegram-Bot-Api-Secret-Token` header does not equal the value loaded from
`Alethea.Telegram.BotToken.secret_token/0`.

The system shall perform the check before reading the request body, shall return
HTTP 401 with no response body, and shall emit no `Logger` line for the rejected
request (no chat_id, no payload, no IP).

#### Scenario: matching secret token passes the plug

- GIVEN the configured `secret_token` value is `"abc123"`
- WHEN `POST /webhooks/telegram` arrives with header `X-Telegram-Bot-Api-Secret-Token: abc123`
- THEN the plug forwards the conn to the controller
- AND the controller is allowed to parse the body

#### Scenario: missing header returns 401 with no body

- GIVEN the request has no `X-Telegram-Bot-Api-Secret-Token` header
- WHEN the plug runs
- THEN the response is HTTP 401
- AND the response body is empty
- AND no `Logger` line is emitted for the rejected request

#### Scenario: wrong header value returns 401 with no body

- GIVEN the configured `secret_token` value is `"abc123"`
- WHEN a request arrives with header `X-Telegram-Bot-Api-Secret-Token: wrong-value`
- THEN the response is HTTP 401
- AND the response body is empty
- AND no `Logger` line is emitted for the rejected request

---

## REQ-C1-webhook-fast-acks

The system shall return HTTP 200 to Telegram within the platform's delivery
window (under 2 seconds) for every successfully authenticated request, regardless
of whether the enqueued job has been processed.

#### Scenario: authenticated request returns 200 immediately

- GIVEN the secret-token plug has passed
- AND the Oban insert is synchronous and returns `{:ok, _job}` in < 50 ms
- WHEN the controller returns
- THEN the HTTP response is 200
- AND the response time is well under 2 seconds

#### Scenario: 200 is returned even when downstream worker is slow

- GIVEN the secret-token plug has passed
- AND the Oban insert succeeds
- WHEN the controller returns before any worker has run
- THEN the HTTP response is 200
- AND the worker is processed asynchronously

---

## REQ-C1-webhook-enqueues-inbound-worker

The system shall enqueue exactly one `AletheaJobs.TelegramMessageWorker` job per
inbound text `Update`, carrying the `update_id`, the `chat_id`, the
`telegram_message_id`, and the message text — and shall set Oban `unique: [period:
86_400, keys: [:telegram_update_id]]` so that Telegram retries within 24 hours are
deduplicated.

#### Scenario: valid text Update enqueues one job

- GIVEN a parsed `Update` with `update_id = 42`, `message.chat.id = 9001`,
  `message.message_id = 7`, and `message.text = "hola"`
- WHEN the controller calls `Oban.insert/1`
- THEN exactly one `TelegramMessageWorker` job is inserted
- AND the job args contain `update_id: 42`, `chat_id: 9001`,
  `telegram_message_id: 7`, and `text: "hola"`

#### Scenario: duplicate Update is deduplicated by Oban

- GIVEN a job for `update_id = 42` already exists in the Oban jobs table
- WHEN the controller inserts another job for the same `update_id`
- THEN Oban returns the existing job (no second insert)
- AND no second `TelegramMessageWorker` is queued

---

## REQ-C1-webhook-routes-start-to-onboarding

The system shall detect inbound `/start <token>` commands and route them to
`AletheaJobs.TelegramOnboardingWorker` instead of `TelegramMessageWorker`, while
still returning 200 within the delivery window.

#### Scenario: /start command enqueues onboarding worker

- GIVEN a parsed `Update` with `message.text = "/start deepLinkTokenXYZ"`
- WHEN the controller processes the update
- THEN one `TelegramOnboardingWorker` job is enqueued
- AND no `TelegramMessageWorker` is enqueued
- AND the HTTP response is 200

#### Scenario: bare /start (no token) is still acknowledged

- GIVEN a parsed `Update` with `message.text = "/start"`
- WHEN the controller processes the update
- THEN the HTTP response is 200
- AND the controller does not enqueue an onboarding job (no token to verify)
- AND the controller does not enqueue a message worker (no inbound text body)
