# One-Shot Active Triggers Architecture (Issue #440)

This document describes the architecture, security guarantees, and execution lifecycle for one-shot active triggers implemented under Issue #440.

## Overview

A one-shot active trigger allows an owning professional to schedule a proactive, clinically neutral message to be delivered to a patient via Telegram at a specific local date and time in the patient's timezone.

The tracer bullet covers the full path end-to-end:
1. Entry point from the patient dashboard (`/dashboard/patients/:id`).
2. Professional authoring of a clinical instruction and local date/time.
3. Boundary-sanitized LLM generation of a candidate message in Spanish, clinically neutral voice (`Alethea.AI.Chains.TriggerPreviewChain`).
4. Server-owned freeze of approved preview text.
5. Patient-DEK encryption of instruction, draft, and approved text (`Alethea.Encryption.PatientVault`).
6. Content-free audit logging (`AuditLog` records for `trigger_created`, `trigger_approved`, and `trigger_fired`).
7. Single-send Oban scheduling via `AletheaJobs.ActiveTriggerWorker` on the `:schedulers` queue.
8. Execution at scheduled UTC instant: message recording with `trigger_id`, atomic status update to `fired`, `TriggerFiring` creation, and enqueuing of `Alethea.Jobs.TelegramOutboundWorker`.
9. Lazy payload resolution in `TelegramOutboundWorker`: arguments carry only identifiers (`trigger_id`, `message_id`, `lane: "trigger"`), avoiding plaintext patient content in job queues or logs.
10. Proactive delivery claim via `Clinical.claim_trigger_delivery/1` preventing supersession by subsequent conversational inbounds.
11. Professional history inspection and owner-scoped produced message view (`/patients/:patient_id/triggers/messages/:message_id`).

## Key Guarantees and Constraints

### 1. Owner Scoping, Authorization, and Boundary Validation
- All context APIs (`Alethea.Triggers`) and Web interfaces (`AletheaWeb.TriggersLive.Index`, `AletheaWeb.TriggersLive.MessageView`) enforce ownership via `Accounts.get_patient_for_professional/2`.
- All UUID parameters (`patient_id`, `trigger_id`, `message_id`) are validated using `Ecto.UUID.cast/1` at public context boundaries and LiveView mounts, avoiding database cast errors and guaranteeing safe rejection (`:unauthorized` / `:not_found` / safe redirect) without clinical state mutation.
- Foreign or unauthenticated professionals are rejected with redirection and error flashes; no text, trigger metadata, or message records are exposed across patient boundaries.

### 2. Encryption, Provenance, and Audit Discipline
- Sensitive therapist instructions, LLM drafts, and approved patient texts are encrypted using the patient's DEK (`PatientVault`).
- Message association (`trigger_id`) is set programmatically at trusted scheduled firing construction, deliberately excluded from untrusted changeset casting (`Message.changeset`).
- Scheduled and outbound Oban job arguments never store plaintext clinical content, chat IDs, or DEKs.
- Audit logs (`AuditLog`) are content-free: `details` is empty (`%{}`), recording only action names and resource IDs.

### 3. Timezone, Timing, and Due-Time Guard
- Timezone conversion relies on `Alethea.Accounts.PatientTimezone.convert_to_utc/3`.
- Ambiguous or nonexistent local times (due to Daylight Saving Time transitions) are explicitly rejected with clear Spanish feedback (`{:gap, msg}` or `{:ambiguous, msg}`), avoiding silent clock drift.
- Past scheduled instants are rejected with `:past_schedule`.
- `ActiveTriggerWorker` verifies the persisted `scheduled_at` against the actual system clock before any mutation. Early invocation returns `{:snooze, delay}` with a strictly positive delay, preserving the job without altering message, firing, audit, or outbound state.

### 4. Idempotency, Concurrency, and Truthful Firing History
- `ActiveTriggerWorker` acquires a row-level lock `FOR UPDATE` on the trigger inside the transaction and relies on `unique_index(:trigger_firings, [:trigger_id])` for defense-in-depth against race conditions.
- Replaying or concurrent execution of `ActiveTriggerWorker` is completely idempotent: exactly one `Message`, `TriggerFiring`, and outbound job are produced.
- Truthful history: `TriggerFiring` status is recorded as `"fired"`. In the clinical interface, the history status truthfully indicates `"En cola"` while the message remains pending/sending, and only indicates `"Enviado"` after delivery is acknowledged by Telegram (via `Message.delivery_state == "sent"`).

### 5. Instruction-Bound Preview and Approval Lifecycle
- In `TriggersLive.Index`, generated previews are server-owned and bound to the instruction that generated them.
- Any edit to the instruction input invalidates the draft preview immediately, requiring a fresh preview before approval can occur.
- Approval never accepts client-supplied text replacements or re-calls the model; it commits the server-bound frozen preview.
- Duplicate approval clicks are guarded to prevent double-scheduling.

### 5. Outbound Delivery Lane
- Triggers use an explicit `:trigger` lane in `TelegramOutboundWorker`.
- Unlike conversational replies, proactive triggers do not use conversational journaling supersession; `Clinical.claim_trigger_delivery/1` atomically transitions `delivery_state` from `"pending"` to `"sending"`.
- Existing `:safe`, `:crisis`, and default/goodbye behaviors remain unmodified.

### 6. Recurrent Schedules and Firing Lifecycle (Issue #441)
- Active triggers support `once`, `daily`, and `weekly` schedules with an optional `end_date`.
- Initial occurrence and subsequent firings are calculated in the patient's configured timezone across Daylight Saving Time (DST) changes using `Alethea.Triggers.Schedule`.
- After each firing, `ActiveTriggerWorker` calculates the next occurrence instant. If the next occurrence is on or before `end_date` (or `end_date` is omitted), `trigger.scheduled_at` advances and a new Oban job is enqueued on `:schedulers`.
- When `end_date` is reached (no further occurrences possible), `trigger.status` transitions to `"fired"` and scheduling ceases.
- Concurrency defense: `trigger_firings` unique index on `[:trigger_id, :scheduled_at]` ensures each scheduled occurrence fires at most once, and row-level locking `FOR UPDATE` prevents race conditions.

### 7. Session Deferral (Issue #444)
- A due active trigger waits while a session is open, inbound burst messages lack reply coverage, or an ordinary burst reply is pending delivery.
- Session closure remains owned by `SessionTimeoutWorker`; the trigger worker does not run a separate inactivity timer.
- The same job snoozes for up to 60 seconds at a time, capped at the original `scheduled_at` plus one hour. Closing the session and resolving pending replies releases it on the next poll.
- At the one-hour boundary the trigger may fire even if journaling is still open. Crisis and approval guards continue to apply.
- Deferral creates no message, firing, audit event, or outbound job and never advances the occurrence or resets its deadline.

### 8. Daily Send Cap and Skipped History (Issue #444 — S2, S4)
- Active sends are capped at a globally configured 5 sends per patient per calendar day in the patient's configured timezone (`patient.timezone`), defaulting to 5 via `:alethea, :active_trigger_daily_cap`.
- Day boundaries and DST transitions: `Triggers.local_day_utc_range/2` calculates contiguous `[start_utc, end_utc)` bounds in the patient's timezone. During DST midnight spring-forward gaps (e.g. 00:00 jumping to 01:00 in America/Santiago), the boundary resolves to the first valid instant of the new day (e.g. 01:00 local / 04:00 UTC) for both the end of the preceding day and the start of the next day, avoiding dropped last-second firings or gap omissions. During midnight fall-back ambiguities, the earlier midnight instant is consistently selected on both adjacent boundaries to prevent day overlap.
- Concurrency and lock order: `ActiveTriggerWorker` locks the patient conversation first via `Clinical.lock_patient_conversation!/1` before acquiring the row-level `FOR UPDATE` lock on the trigger, preserving the global lock hierarchy (Patient -> Trigger -> Message) and serializing concurrent trigger evaluations for the same patient without deadlock.
- The 6th send of the day (and subsequent attempts exceeding the cap) is suppressed: no `Message` record is created, and no `TelegramOutboundWorker` job is enqueued.
- Truthful skipped history: `TriggerFiring` records `status: "skipped"` with `message_id: nil`. In the clinical history LiveView, it renders an `"Omitido"` badge without a broken message link.
- Recurrence handling: skipped occurrences advance via `Triggers.next_occurrence/2`. One-shot triggers are consumed (`trigger.status = "fired"`), and recurring triggers advance to their next occurrence.
- Content-free audit: `Triggers.insert_content_free_audit!(trigger.professional_id, trigger.id, "trigger_skipped")` logs the event without PHI.

### 9. Elicited Reply Tagging (Issue #447)
- A patient reply whose timestamp falls within 2 hours of the patient's newest delivered Trigger activo message is persisted with `behavior_type: "elicited"`; otherwise it stays `"spontaneous"`. The clinical record can thus distinguish prompted from spontaneous behavior.
- Only acknowledged deliveries open the window: the anchor query in `Triggers.elicited_window_open?/2` considers outbound trigger messages with `delivery_state: "sent"` exclusively — pending, ambiguous, or failed firings never tag a reply as elicited.
- When several delivered trigger messages exist, the newest one anchors the window. A reply timestamped before that delivery is never inside it, and the check is per-patient, so other patients' triggers never cross.
- The gate runs only on first insert inside `Clinical.find_or_save_telegram_inbound/4`; a resumed or replayed inbound keeps its persisted tag, so history is never rewritten.

## Scope Exclusions (Deferred to Issues #445–#448, #452)
- Editing, status toggles, dashboard trigger counts (#442)
- Crisis pause and resumption (#443)
- Delivery failure counters and retry history handling (#445)
- Patient-initiated pause/opt-out notices (#446)
- Reactive matching (#448 — tracer bullet landed; see `docs/features/trigger-management.md`, "Reactive Triggers")
- RAG context injection into triggers (#452)
