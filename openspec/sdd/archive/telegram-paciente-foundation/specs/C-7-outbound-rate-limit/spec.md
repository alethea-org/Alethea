# Spec — C-7: Outbound Rate-Limit & 429 Handling

**Capability:** C-7 — Outbound rate-limit and 429 handling
**Change:** `telegram-paciente-foundation`
**Status:** ADDED (this slice introduces the Pacer GenServer, the outbound
worker, the crisis priority lane, and the dead-letter path)
**Module(s):** `Alethea.Telegram.Pacer`, `AletheaJobs.TelegramOutboundWorker`,
`Alethea.Telegram.OutboundDeadLetter`, Oban queues `telegram_outbound` and
`telegram_outbound_crisis`

---

## Purpose

The system shall pace every outbound Telegram send through a TokenBucket Pacer
that enforces 1 message per second per chat and 30 messages per second globally,
retry 429 responses with jittered exponential backoff, dead-letter on
exhaustion, and reserve a small priority lane for crisis replies that escalates
to a direct send if the lane is full — while never bypassing the rate-limit
itself.

---

## Requirements

## REQ-C7-pacer-per-chat-limit

The system shall enforce that no more than one outbound message is sent per
chat per second, via a per-chat TokenBucket in `Alethea.Telegram.Pacer`.

#### Scenario: first message to a chat goes through immediately

- GIVEN a chat_id_hash `C` with a full per-chat bucket
- WHEN `Pacer.acquire(C)` is called for the first time
- THEN the call returns `:ok` without blocking

#### Scenario: second message in the same second blocks until refill

- GIVEN a chat_id_hash `C` whose bucket was just consumed
- WHEN `Pacer.acquire(C)` is called again within the same second
- THEN the call blocks until the bucket refills (1 Hz)
- AND only then returns `:ok`

#### Scenario: different chats are paced independently

- GIVEN chat_id_hashes `C1` and `C2`
- WHEN `Pacer.acquire(C1)` and `Pacer.acquire(C2)` are called back-to-back
- THEN both calls return `:ok` (per-chat buckets are independent)

---

## REQ-C7-pacer-global-limit

The system shall enforce that no more than 30 outbound messages are sent per
second globally, via a global TokenBucket in `Alethea.Telegram.Pacer` with
refill 30 Hz.

#### Scenario: 30 messages in 1s are all allowed

- GIVEN 30 distinct chat_id_hashes
- WHEN `Pacer.acquire/1` is called for each in the same second
- THEN all 30 calls return `:ok`

#### Scenario: 31st message in the same second blocks until refill

- GIVEN the global bucket was just exhausted by 30 messages in < 1s
- WHEN a 31st `Pacer.acquire/1` is called
- THEN the call blocks until the global bucket refills
- AND only then returns `:ok`

#### Scenario: global limit is independent of per-chat limit

- GIVEN the per-chat bucket is full for chat `C`
- AND the global bucket has tokens available
- WHEN `Pacer.acquire(C)` is called
- THEN the per-chat bucket is the dominant constraint
- AND the message is paced at 1 Hz regardless of global availability

---

## REQ-C7-429-retry-with-jitter

The system shall, on a 429 response from Telegram with a `Retry-After` header,
reschedule the `TelegramOutboundWorker` job with exponential backoff plus
random jitter, capped at `max_attempts: 5`, and shall re-enter the Pacer queue
on retry.

#### Scenario: 429 with Retry-After is rescheduled

- GIVEN a 429 response with `Retry-After: 2`
- WHEN the worker handles the response
- THEN the job is rescheduled with backoff = 2 s ± 250 ms (jitter)
- AND `attempt` is incremented
- AND no dead-letter is recorded yet

#### Scenario: 429 retries up to 5 attempts

- GIVEN the worker has already retried 4 times
- WHEN a 5th 429 is received
- THEN the job is rescheduled (final attempt)
- AND a 6th 429 triggers `REQ-C7-dead-letter-on-exhaustion`

#### Scenario: non-429 transport errors retry identically

- GIVEN a 5xx response or a network error
- WHEN the worker handles the error
- THEN the job is rescheduled with the same backoff + jitter rules
- AND the retry budget (5) is shared across 429 and 5xx/network

---

## REQ-C7-dead-letter-on-exhaustion

The system shall, after `max_attempts: 5` retries on the same outbound job,
move the payload to a dead-letter table (`outbound_dead_letters`) and publish
`:outbound_dead_letter` on `Alethea.PubSub` — so that no message is silently
dropped.

#### Scenario: dead-letter row is written

- GIVEN the 5th retry attempt has failed
- WHEN the worker reaches the exhaustion step
- THEN one `outbound_dead_letters` row is inserted with the chat_id_hash, the
  text, the last error, and the timestamp
- AND the Oban job is marked as discarded (no further retries)

#### Scenario: PubSub event is published

- GIVEN a dead-letter write
- WHEN the worker reaches the publish step
- THEN `Phoenix.PubSub.broadcast(Alethea.PubSub, "ops:alerts",
  {:outbound_dead_letter, %{chat_id_hash: …, text: …, error: …}})` is called
- AND a subscriber on the same topic receives the message

---

## REQ-C7-crisis-priority-lane

The system shall enqueue crisis replies on a dedicated
`telegram_outbound_crisis` Oban queue with `max_demand: 2`, so that crisis
messages are processed independently of normal outbound traffic and cannot be
starved by a full `telegram_outbound` queue.

#### Scenario: crisis reply goes to the crisis queue

- GIVEN the `TelegramMessageWorker` emits a crisis reply
- WHEN the outbound job is inserted
- THEN the queue is `:telegram_outbound_crisis`
- AND the job args carry a `:crisis` flag the worker can inspect

#### Scenario: normal reply does not enter the crisis queue

- GIVEN the `TelegramMessageWorker` emits a safe-path reply
- WHEN the outbound job is inserted
- THEN the queue is `:telegram_outbound`
- AND the `:crisis` flag is `false`

#### Scenario: crisis queue is independent from normal queue

- GIVEN `telegram_outbound` is at max demand
- WHEN a new crisis job is enqueued
- THEN the crisis job runs immediately (the crisis queue is not blocked by
  the normal queue's saturation)

---

## REQ-C7-crisis-queue-full-escalation

The system shall, on an `Oban.InsertError` with `reason: :queue_full` from
`telegram_outbound_crisis`, bypass the queue and run the worker body directly
(via `perform_now/1`) — while still passing the send through the Pacer, so the
rate-limit is preserved — and shall publish a `:crisis_queue_full` event on
`ops:alerts` for operator visibility.

#### Scenario: queue full escalates to direct send

- GIVEN the crisis queue reports `:queue_full` on insert
- WHEN the `TelegramMessageWorker` catches the error
- THEN a `perform_now/1` invocation of the outbound worker is spawned
- AND the spawned process still calls `Pacer.acquire(chat_id_hash)` before
  sending (rate-limit is not skipped, only the queue is)
- AND a `Logger.error` line is emitted with the chat_id_hash prefix only

#### Scenario: escalation broadcasts operator alert

- GIVEN a `:queue_full` escalation has been triggered
- WHEN the broadcast step runs
- THEN `Phoenix.PubSub.broadcast(Alethea.PubSub, "ops:alerts",
  {:crisis_queue_full, chat_id_hash})` is called
- AND a subscriber on the same topic receives the message

#### Scenario: rate-limit is never bypassed

- GIVEN any escalation or normal send path
- WHEN the worker reaches the send step
- THEN `Pacer.acquire(chat_id_hash)` is always called
- AND a direct call to `Client.send_message/2` without Pacer is a violation
  (regression-tested)
