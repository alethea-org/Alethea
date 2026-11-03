# Trigger Management Lifecycle Architecture (Issue #442 — T1)

This document describes the lifecycle state transitions, database schema changes, execution guards, and context APIs implemented under Task T1 of Issue #442.

## Overview

Issue #442 introduces lifecycle management for active triggers without deleting them:
- Professionals can **deactivate** an active trigger and **activate** (resume) an inactive trigger (S1).
- Editing an active trigger's clinical instruction clears the approved text and stale draft persistently, requiring re-approval before sending (S2).
- All lifecycle mutations write content-free audit logs (`AuditLog`) and enforce therapist-patient ownership authorization (S3, S5).
- Resuming expired one-shot triggers returns an actionable error rather than firing immediately (S6).
- Resuming recurring triggers (daily / weekly) recomputes the next future occurrence in the patient's timezone without missed-send catch-up (S6).
- Pending and retrying outbound messages are gated at claim/send-start time so that deactivated, unapproved, or stale-revision triggers do not initiate new sends to Telegram. Note: an outbound HTTP request already in flight to Telegram cannot be recalled; the safety gate is enforced at the local delivery claim and send-start decision before dispatching the request.

## Lifecycle States and Schema

### Trigger Statuses
The `status` field on `Alethea.Triggers.Trigger` supports:
- `"active"`: Scheduled to fire at `scheduled_at`.
- `"inactive"`: Suspended by the therapist; will not fire while inactive.
- `"fired"`: Has executed its scheduled occurrence (or final occurrence for recurring schedules with `end_date`).

### Approval Revision and Nullable Approved Text
1. **Migration `allow_unapproved_triggers`**: `approved_text` and `draft_message` columns on `triggers` table are now nullable (`null: true`).
2. **Migration `add_trigger_approval_revision`**: Adds `approval_revision :integer, null: false, default: 1` to track server-owned instruction revisions.
3. When a trigger's instruction is edited to a new non-empty value:
   - `instruction` is encrypted with the patient's DEK.
   - `approved_text` and `draft_message` are set to `nil`.
   - `approval_revision` is incremented.
   - Any pending scheduled `ActiveTriggerWorker` jobs are pruned.
4. Exact unchanged instruction edits preserve existing approved text, draft, and revision without requiring reapproval.

## Public Context APIs (`Alethea.Triggers`)

### 1. `deactivate_trigger/3`
- **Signature**: `deactivate_trigger(professional, patient_id, trigger_id) :: {:ok, Trigger.t()} | {:error, term()}`
- **Behavior**:
  - Validates ownership and UUIDs.
  - Acquires row-level `FOR UPDATE` lock.
  - Moves `status` to `"inactive"`.
  - Removes pending `ActiveTriggerWorker` Oban jobs (`state in ["scheduled", "available", "retryable"]`).
  - Records `"trigger_deactivated"` audit log.
- **Errors**: `{:error, :unauthorized}`, `{:error, :not_found}`, `{:error, :already_fired}`.

### 2. `activate_trigger/3`
- **Signature**: `activate_trigger(professional, patient_id, trigger_id) :: {:ok, Trigger.t()} | {:error, term()}`
- **Behavior**:
  - Validates ownership and UUIDs.
  - Acquires row-level `FOR UPDATE` lock.
  - Rejects unapproved triggers with `{:error, :unapproved}`.
  - For `once` schedules: checks `DateTime.compare(trigger.scheduled_at, now) == :gt`. If past, returns `{:error, {:expired_schedule, message}}`. If future, enqueues `ActiveTriggerWorker`.
  - For `daily` and `weekly` schedules: invokes `Schedule.initial_occurrence/4` with stored timezone, time, weekdays, and end_date to compute the next future occurrence without catch-up. Enqueues new `ActiveTriggerWorker`. If end_date passed, returns `{:error, {:end_date_passed, message}}`.
  - Moves `status` to `"active"`.
  - Records `"trigger_activated"` audit log.
- **Errors**: `{:error, :unauthorized}`, `{:error, :not_found}`, `{:error, :already_fired}`, `{:error, :unapproved}`, `{:error, {:expired_schedule, String.t()}}`, `{:error, {:end_date_passed, String.t()}}`.

### 3. `update_trigger_instruction/4`
- **Signature**: `update_trigger_instruction(professional, patient_id, trigger_id, new_instruction) :: {:ok, Trigger.t()} | {:error, term()}`
- **Behavior**:
  - Trims `new_instruction`. If empty, returns `{:error, :empty_instruction}`.
  - Acquires row-level `FOR UPDATE` lock.
  - Compares trimmed instruction with decrypted current instruction:
    - If equal: returns trigger unchanged (preserves approved text and revision).
    - If changed: encrypts new instruction, sets `approved_text = nil`, `draft_message = nil`, increments `approval_revision`, removes scheduled jobs, records `"trigger_updated"` audit log.
- **Errors**: `{:error, :empty_instruction}`, `{:error, :unauthorized}`, `{:error, :not_found}`, `{:error, :already_fired}`.

### 4. `reapprove_trigger/4`
- **Signature**: `reapprove_trigger(professional, patient_id, trigger_id, attrs) :: {:ok, Trigger.t()} | {:error, term()}`
- **Parameters**: `attrs` map containing:
  - `:expected_revision` / `"expected_revision"` (required positive integer snapshot revision)
  - `:approved_text` / `"approved_text"` (required non-empty string)
  - `:draft_message` / `"draft_message"` (optional string, defaults to approved text)
  - `:expected_instruction` / `"expected_instruction"` (optional string snapshot instruction)
- **Behavior**:
  - Validates positive integer `expected_revision` up front; if missing or invalid, immediately returns `{:error, :missing_expected_revision}` without performing database queries, transactions, or mutations.
  - Validates ownership, UUIDs, and non-empty approved text.
  - Acquires row-level `FOR UPDATE` lock.
  - Snapshot revision check: if `trigger.approval_revision != expected_rev`, returns `{:error, :stale_revision}`.
  - Snapshot instruction check: if `expected_instruction` supplied and does not match current decrypted instruction, returns `{:error, :stale_instruction}`.
  - If trigger is active, validates future occurrence and updates `scheduled_at` / enqueues `ActiveTriggerWorker`. If recurring `end_date` has passed, returns `{:error, {:end_date_passed, message}}`.
  - Encrypts approved text and draft, persists updates, records `"trigger_approved"` audit log.
- **Errors**: `{:error, :missing_expected_revision}`, `{:error, :empty_approved_text}`, `{:error, :stale_revision}`, `{:error, :stale_instruction}`, `{:error, :unauthorized}`, `{:error, :not_found}`, `{:error, :already_fired}`, `{:error, {:expired_schedule, String.t()}}`, `{:error, {:end_date_passed, String.t()}}`.

### 5. `list_triggers/2`
- **Signature**: `list_triggers(professional, patient_id) :: {:ok, [Trigger.t()]} | {:error, :unauthorized}`
- **Behavior**: Lists all triggers for the given patient (active, inactive, unapproved, fired), sorted by `scheduled_at ASC`, with decrypted fields.

### 6. `list_active_triggers/2`
- **Signature**: `list_active_triggers(professional, patient_id) :: {:ok, [Trigger.t()]} | {:error, :unauthorized}`
- **Behavior**: Preserves existing contract, returning only triggers where `status == "active" and not is_nil(approved_text)`.

## Execution and Worker Guards

### `ActiveTriggerWorker`
- Runs under row-level `FOR UPDATE` lock on the trigger record.
- Pattern matches on `%Trigger{status: "active", approved_text: app} when not is_nil(app)`.
- If the trigger is `"inactive"`, `"fired"`, or unapproved (`approved_text: nil`), the worker performs a clean no-op (`:ok`) without firing, creating messages, or enqueuing outbound jobs.
- Passes `"approval_revision" => trigger.approval_revision` in Oban job arguments when enqueuing `TelegramOutboundWorker`.

### `TelegramOutboundWorker`
- In `begin_trigger_delivery`, the worker evaluates the current database state of the associated trigger before claiming delivery or invoking the Telegram client:
  1. If `trigger.status == "inactive"`: skips send with `{:skip, "trigger_inactive"}`.
  2. If `is_nil(trigger.approved_text)`: skips send with `{:skip, "trigger_unapproved"}`.
  3. If job revision (defaulting to legacy revision 1 when missing) does not match `trigger.approval_revision`: skips send with `{:skip, "trigger_stale_revision"}`. This preserves legitimate legacy revision 1 sends while suppressing stale revision 1 sends once a trigger has been updated and reapproved (revision > 1).
  4. If all checks pass: invokes `Clinical.claim_trigger_delivery/1`.
- Any skipped delivery exits `:ok` without calling `Client.send_message/2`, ensuring previously enqueued or retrying jobs do not emit messages after deactivation, instruction edits, or concurrent re-approval.
- Boundary note: Once an outbound request has passed this gate and has been issued to the Telegram client API, it is in flight and cannot be retracted by the local system.

## User-Facing LiveView Workflow (Issue #442 — T2)

The triggers management LiveView (`AletheaWeb.TriggersLive.Index`) provides therapists with direct controls to manage trigger lifecycles and edit therapeutic instructions safely.

### 1. Trigger Statuses and Visibility
- **Triggers List**: Lists all patient triggers (active, inactive, unapproved, and completed/fired) using `Triggers.list_triggers/2`.
- **Status Badges**:
  - `Activo` (`pt-pill pt-pill--active`): Active trigger with scheduled future occurrence.
  - `Inactivo` (`pt-pill pt-pill--inactive`): Suspended trigger; will not fire while inactive.
  - `Finalizado` (`pt-pill`): Trigger has already fired or completed its recurring schedule; rendered read-only without edit or toggle buttons.
  - `Requiere aprobación` (`pt-pill pt-pill--warning`): Trigger's instruction was modified or lacks an approved message. No sends can occur while unapproved.

### 2. Activation and Deactivation Controls
- **Deactivating (`Desactivar`)**: Clicking `Desactivar` suspends the trigger, transitions its status to `inactive`, prunes pending scheduled Oban jobs, and writes an audit log entry.
- **Activating (`Activar`)**: Clicking `Activar` transitions an inactive trigger back to `active`.
  - For `once` schedules: verifies the scheduled time is in the future. If expired, displays an actionable error asking the therapist to create a new trigger with a future time.
  - For `daily`/`weekly` recurring schedules: recomputes the next future occurrence in the patient's timezone without missed-send catchup. If the end date has expired, returns an actionable error.
  - For unapproved triggers: activation is blocked with an error requiring the therapist to generate and approve a preview first.

### 3. Instruction Editing and Re-Approval Lifecycle
- **Inline Edit (`Editar`)**: Opens the instruction edit form for any non-fired trigger.
- **Persist-First Guarantee**: Submitting an edited instruction or generating a preview persists the new instruction in the database **first**, clearing `approved_text` and `draft_message`, incrementing `approval_revision`, and pruning scheduled jobs. Even if preview draft generation fails or the therapist leaves the page, the trigger cannot fire with outdated content.
- **Server-Owned Preview Snapshot**: The generated preview draft and its snapshot revision (`expected_revision`) are held in server assigns, not client parameters.
- **Approval (`Aprobar cambio`)**: Calls `Triggers.reapprove_trigger/4` binding the server-owned revision snapshot. If a concurrent edit occurred, a `:stale_revision` error is caught and displayed, requiring a fresh preview.
- **Inactive State Preservation**: If an inactive trigger is edited and reapproved, its status remains `inactive` until the therapist explicitly clicks `Activar`.
- **Param Change Invalidation**: Modifying the instruction text invalidates any previously displayed preview draft immediately.
