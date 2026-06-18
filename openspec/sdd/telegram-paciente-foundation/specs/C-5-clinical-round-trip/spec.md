# Spec — C-5: End-to-End Clinical Round-Trip

**Capability:** C-5 — End-to-end clinical round-trip on the Telegram channel
**Change:** `telegram-paciente-foundation`
**Status:** ADDED (this slice introduces the Telegram-specific orchestration;
the underlying emotion + LLM + crisis modules are reused from the WhatsApp
foundation)
**Module(s):** `AletheaJobs.TelegramMessageWorker` (orchestration),
`Alethea.Clinical` (save_message), `AletheaJobs.EmotionAnalysisWorker` (existing),
`Alethea.Alerts.CrisisMonitor.detect/1` (existing), `Alethea.AI.llm().chat/2`
(existing)

---

## Purpose

The system shall, for every bound Telegram chat, perform the same clinical
round-trip as the WhatsApp channel: persist the inbound message, run RoBERTa
emotion analysis, classify safety, and on the safe path call the LLM for a
personality-aware reply, while on the crisis path bypass the LLM and notify the
psychologist — preserving the principle that the patient never sees the system's
clinical interpretation.

---

## Requirements

## REQ-C5-persist-inbound-message

The system shall persist every inbound Telegram message via
`Alethea.Clinical.save_message/7` with the patient id, the body, the direction
`"inbound"`, the source `"spontaneous"`, the `telegram_message_id`, and the
`session_id` (nullable).

#### Scenario: inbound text is recorded

- GIVEN a bound patient and a non-empty text payload
- WHEN the worker reaches the persist step
- THEN one `Message` row is inserted
- AND `direction == "inbound"`, `source == "spontaneous"`,
  `telegram_message_id` matches the inbound update
- AND the `body` is encrypted at rest via Cloak.Ecto (no plaintext at rest)

#### Scenario: empty text payloads are dropped

- GIVEN a parsed Update whose `message.text` is `nil` and whose message has no
  caption (e.g. a sticker-only update)
- WHEN the worker reaches the persist step
- THEN no `Message` row is inserted
- AND no outbound job is enqueued
- AND the worker returns `:ok` (does not crash-retry)

---

## REQ-C5-trigger-emotion-analysis

The system shall enqueue an `AletheaJobs.EmotionAnalysisWorker` job on the
existing `ai_analysis` queue for every persisted inbound message — without
blocking the current job on the analysis result.

#### Scenario: emotion worker is enqueued asynchronously

- GIVEN a freshly persisted inbound `Message`
- WHEN the worker reaches the analysis step
- THEN one `EmotionAnalysisWorker` job is inserted on queue `:ai_analysis`
- AND the Telegram worker does not wait for the analysis to complete
- AND failure of the analysis job does not affect the Telegram reply path

---

## REQ-C5-llm-reply-on-safe

The system shall, when `Alethea.Alerts.CrisisMonitor.detect/1` returns
`:safe`, build a patient context (recent messages, personality, configured
triggers) and call `Alethea.AI.llm().chat/2` to obtain a reply text.

#### Scenario: safe message is answered by the LLM

- GIVEN a `:safe` classification for the inbound text
- WHEN the worker calls the LLM
- THEN the LLM returns a non-empty reply string
- AND the reply is enqueued on the `telegram_outbound` queue
- AND the outbound `Message` row is persisted with `direction: "outbound"`,
  `source: "elicited"`

#### Scenario: safe path does not touch the crisis lane

- GIVEN a `:safe` classification
- WHEN the worker emits the outbound job
- THEN the queue is `:telegram_outbound`
- AND no PubSub broadcast on `psychologist:alerts` is emitted
- AND the patient's `urgent_intervention` flag is not changed

#### Scenario: LLM unavailability crashes the job (retry-eligible)

- GIVEN the configured LLM adapter raises a transient error
- WHEN the worker calls the LLM
- THEN the worker raises
- AND Oban schedules a retry up to `max_attempts: 3`
- AND no outbound message is enqueued (the patient is not silently dropped)

---

## REQ-C5-crisis-bypasses-llm

The system shall, when `Alethea.Alerts.CrisisMonitor.detect/1` returns
`:crisis`, skip the LLM call entirely and use the patient-specific preconfigured
crisis reply configured by the psychologist.

#### Scenario: crisis message uses the preconfigured reply

- GIVEN a `:crisis` classification
- WHEN the worker reaches the response step
- THEN no LLM call is made
- AND the reply text is `patient.crisis_reply_text` (or the system default
  if not customized)
- AND the reply is enqueued on the `:telegram_outbound_crisis` queue (not
  the regular outbound queue)

#### Scenario: crisis message marks urgent_intervention

- GIVEN a `:crisis` classification
- WHEN the worker reaches the response step
- THEN `Accounts.update_patient(patient, urgent_intervention: true)` is called
- AND a `Clinical.save_ai_diagnosis(... model_version: "crisis-bypass" ...)`
  row is inserted for audit

#### Scenario: crisis branch never produces a neutral LLM reply

- GIVEN a `:crisis` classification with a working LLM
- WHEN the worker reaches the response step
- THEN no LLM-derived text is included in the patient-visible reply
- AND the LLM is not invoked at all (zero LLM cost on crisis)

---

## REQ-C5-crisis-broadcasts-alert

The system shall publish a `:crisis_detected` event on
`Alethea.PubSub` topic `"psychologist:alerts"` with the patient id, the
chat_id_hash, and the timestamp of the inbound message.

#### Scenario: PubSub event is published on crisis

- GIVEN a `:crisis` classification
- WHEN the worker reaches the alert step
- THEN `Phoenix.PubSub.broadcast(Alethea.PubSub, "psychologist:alerts",
  {:crisis_detected, %{patient_id: …, chat_id_hash: …, at: …}})` is called
- AND a subscriber on the same topic receives the message

#### Scenario: safe classification emits no crisis event

- GIVEN a `:safe` classification
- WHEN the worker reaches the alert step
- THEN no broadcast on `"psychologist:alerts"` is emitted
- AND no `urgent_intervention` flag is set

---

## REQ-C5-persist-outbound-reply

The system shall persist the outbound reply as a `Message` row with
`direction: "outbound"` and `source: "elicited"` (or `"crisis_bypass"` for
crisis replies), before enqueueing the `TelegramOutboundWorker` job — so that
the clinical record reflects what the patient will see even if the outbound
send later fails.

#### Scenario: LLM reply is persisted before send

- GIVEN a non-empty LLM reply
- WHEN the worker reaches the persist step
- THEN a `Message` row is inserted with `direction: "outbound"`,
  `source: "elicited"`, the LLM reply body, and the patient id
- AND the `TelegramOutboundWorker` job is enqueued with that message id

#### Scenario: crisis reply is persisted with crisis_bypass source

- GIVEN a crisis branch
- WHEN the worker reaches the persist step
- THEN a `Message` row is inserted with `direction: "outbound"`,
  `source: "crisis_bypass"`, the preconfigured text, and the patient id

#### Scenario: persistence failure blocks the send

- GIVEN `Clinical.save_message/7` raises on the outbound step
- WHEN the worker reaches the emit step
- THEN no `TelegramOutboundWorker` job is enqueued
- AND Oban schedules a retry (the clinical record is the source of truth,
  not the network)
