# telegram-patient-pause Specification

## Purpose

A patient controls whether Alethea keeps sending them scheduled proactive messages (Trigger activo). The literal command `/pausa` pauses every active-kind trigger of that patient; Trigger reactivo is never affected. The professional is told durably and can resume each trigger through the existing resume action.

## Definitions

| Term | Meaning |
|------|---------|
| Trigger activo | `Trigger` with `kind == "active"` (scheduled, has `scheduled_at`) |
| Trigger reactivo | `Trigger` with `kind == "reactive"` (condition-matched, no schedule) |
| Pause command | The patient's entire inbound text, trimmed and lowercased, equal to `"/pausa"` |

## Requirements

### Requirement: Pause Command Recognition

The system MUST recognize the pause command before the inbound text is persisted as a `Message`, before `CrisisMonitor` evaluation, and before any journaling/burst-reply routing. Recognition MUST be an exact match (case-insensitive, trimmed of leading/trailing whitespace) of the full message text — not a substring match.

#### Scenario: Exact match
- GIVEN the patient sends `/pausa`
- WHEN `TelegramMessageWorker` processes the inbound
- THEN no `Message` row is created for this text, and the pause executes

#### Scenario: Case-insensitive and trimmed
- GIVEN the patient sends `" /Pausa "`
- WHEN processed
- THEN it is recognized as the pause command

#### Scenario: Not a command
- GIVEN the patient sends `"necesito una pausa"` (contains the word, not an exact match)
- WHEN processed
- THEN it is treated as ordinary journaling content, not the pause command

### Requirement: Active-Only Pause

The system MUST pause only the patient's triggers with `kind == "active" AND status == "active"`. Triggers with `kind == "reactive"` MUST be unaffected regardless of status.

#### Scenario: Reactive untouched
- GIVEN a patient with one active-kind trigger (status `active`) and one reactive-kind trigger (status `active`)
- WHEN the pause command is processed
- THEN the active-kind trigger becomes `paused_by_patient` and the reactive-kind trigger remains `active`

### Requirement: Pause State and Side Effects

Each paused trigger MUST move to status `"paused_by_patient"`, have its scheduled Oban job(s) deleted, and get one content-free `AuditLog` row (action `trigger_paused_by_patient`).

#### Scenario: No further firing
- GIVEN a trigger is `paused_by_patient`
- WHEN its original scheduled time arrives
- THEN `ActiveTriggerWorker` does not send any message for it (no scheduled job exists)

### Requirement: Professional Notification

The system MUST notify the professional in real time (existing `"psychologist:alerts"` PubSub channel / `NotificationCenter`) when a patient's triggers are paused, AND MUST make the pause reason durably visible on the triggers page for each affected trigger, independent of whether the professional was online when the pause happened.

#### Scenario: Durable reason
- GIVEN a trigger is `paused_by_patient`
- WHEN the professional opens that patient's triggers page at any later time
- THEN a badge/reason indicating it was paused by the patient is visible for that trigger

### Requirement: Resume

The system MUST let the professional resume a `paused_by_patient` trigger through the existing resume action. Resume MUST revalidate the schedule (reject an already-expired one-shot/`end_date`) and re-enqueue `ActiveTriggerWorker`.

#### Scenario: Resume
- GIVEN a `paused_by_patient` trigger with a still-valid schedule
- WHEN the professional resumes it
- THEN its status returns to `active` and a new scheduled job is enqueued

#### Scenario: Resume rejected for expired schedule
- GIVEN a `paused_by_patient` trigger whose one-shot date has passed
- WHEN the professional attempts to resume it
- THEN the resume is rejected with an actionable error, unchanged from the existing expired-schedule behavior

### Requirement: Patient Confirmation Reply

After processing the pause command, the system MUST send the patient a short, fixed confirmation reply. The reply MUST NOT be AI-generated and MUST NOT be persisted as a `Message` row (consistent with the command itself never entering the clinical journal).

#### Scenario: Confirmation sent
- GIVEN the patient sends `/pausa`
- WHEN the triggers are paused
- THEN the patient receives a fixed confirmation reply, not a generated one

### Requirement: Onboarding Disclosure

The onboarding welcome text MUST mention that the professional can schedule messages. The disclosure MUST be present whether the welcome text is the system default template or a professional's custom `welcome_message`.

#### Scenario: Disclosure present with custom welcome message
- GIVEN a professional has set a custom `welcome_message`
- WHEN a newly bound patient receives the onboarding message
- THEN the message includes the scheduled-messages disclosure in addition to the custom text

#### Scenario: Disclosure present with default welcome message
- GIVEN a professional has no custom `welcome_message`
- WHEN a newly bound patient receives the onboarding message
- THEN the default message includes the scheduled-messages disclosure

### Requirement: Scope Boundary

The system MUST NOT add a general slash-command parser, MUST NOT change Trigger reactivo eligibility or behavior, and MUST NOT retrofit `pause_active_triggers_for_crisis/1`'s pre-existing lack of a `kind` filter as part of this change.

#### Scenario: Crisis pause unchanged
- GIVEN a crisis-triggered pause
- WHEN processed
- THEN `pause_active_triggers_for_crisis/1` behaves exactly as it did before this change
