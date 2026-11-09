# Proposal: /pausa command, onboarding notice and professional notification (#446)

**Status:** decided — patient confirmation reply locked (recommended default accepted); exact Spanish copy still drafted in design

## Intent

Give patients control over whether they keep receiving Alethea's scheduled proactive messages (Trigger activo). A patient sends the literal Telegram command `/pausa`; every one of their active-kind triggers currently `"active"` moves to a new `"paused_by_patient"` status, so no further scheduled message is sent. Triggers that answer the patient's own messages (Trigger reactivo) are unaffected. The professional is told, durably, what happened and can resume each trigger the same way they already resume a crisis- or delivery-failure-paused one.

## Scope

### In Scope

- New `Trigger.status` value `"paused_by_patient"`, plus a new domain function bulk-flipping only `kind == "active" AND status == "active"` rows for the patient, deleting their scheduled Oban jobs, and writing one content-free `AuditLog` row per affected trigger (action `trigger_paused_by_patient`) — mirrors `pause_active_triggers_for_crisis/1`'s shape but adds the `kind` filter that function is missing.
- Literal, case-insensitive, trimmed `/pausa` command recognition in `TelegramMessageWorker`, short-circuited at the same pre-persistence point as `empty_text?/1` — the command text is never saved as a `Message`, never routed through `CrisisMonitor` or the journaling/burst-reply pipeline.
- `resume_trigger/3` extended to also accept `"paused_by_patient"` in its allowed-source-statuses list — reuses its existing schedule-revalidation and re-enqueue logic, no new resume code path.
- Durable pause-reason badge in `triggers_live/index.ex` for `status == "paused_by_patient"`, following the exact `paused_by_delivery_failures` badge pattern, so the professional sees the reason any time they open that patient's triggers, independent of being online when it happened.
- Professional notification via the existing `"psychologist:alerts"` PubSub channel + `NotificationCenter.build_notification/2`, new event type `:trigger_paused_by_patient`.
- Onboarding disclosure: `welcome_text/1` unconditionally appends a short sentence noting the professional may schedule messages, regardless of whether `professional.welcome_message` is the default template or a custom one.
- A short fixed patient-facing confirmation reply after `/pausa` (e.g. "Listo, pausamos tus mensajes programados. Podés escribirme cuando quieras.") — not required by the stated AC, but confirmed with the user as the better default over silence.
- Tests through `TelegramMessageWorker.perform/1` (prior art: existing worker tests), plus `Triggers` context tests for the new pause/resume path, plus a `triggers_live` test for the badge.

### Out of Scope

- A general slash-command parser/dispatcher — `/pausa` is a single literal match; a registry is premature until a second command is actually requested.
- Retrofitting `pause_active_triggers_for_crisis/1`'s missing `kind` filter — that's pre-existing behavior from #443, separate from this issue.
- Bulk resume UI/action — the professional resumes each trigger individually from the existing per-trigger UI, same as today's crisis/delivery-failure resume flow.
- Any change to Trigger reactivo behavior or eligibility.
- A new `trigger_pauses` history table — `status` plus the content-free audit row already cover "what happened and when."

## Capabilities

### New Capabilities

- `telegram-patient-pause`: the `/pausa` command, the new trigger status and pause/resume semantics, the professional notification, and the onboarding disclosure.

### Modified Capabilities

- None (no `openspec/specs/` baseline for the trigger system).

## Approach

Recommended approach from the exploration (engram `sdd/#446 pausa command onboarding notice professional notification/explore`):

| # | Decision | Reason |
|---|----------|--------|
| State | New `Trigger.status = "paused_by_patient"`, not a patient-level flag or new table | Reuses `ActiveTriggerWorker`'s existing `status == "active"` fire-gate for free; reuses `resume_trigger/3`; matches #443/#445 convention exactly |
| Filter | Pause function filters `kind == "active"` explicitly | `pause_active_triggers_for_crisis/1` lacks this filter and today also pauses reactive triggers — #446 must not repeat that bug |
| Command | Literal, case-insensitive, trimmed `/pausa` short-circuited before persistence | Matches the existing `empty_text?/1` short-circuit shape; keeps the command out of the clinical journal and off the AI path, which matters for determinism of "no trigger is sent" |
| Resume | Extend `resume_trigger/3`'s accepted-status list | No new resume logic; single-trigger-scoped resume is already how crisis/delivery-failure pauses are resumed today, so this issue doesn't introduce bulk resume |
| Notification | Reuse `"psychologist:alerts"` PubSub/`NotificationCenter` + durable badge in `triggers_live` | Zero new infra for the real-time half; the badge is what actually guarantees "the professional sees the reason," since `NotificationCenter` is session-ephemeral, not persisted |
| Onboarding | Append the disclosure unconditionally in `welcome_text/1`, after whichever text (default or custom) is active | A professional's custom `welcome_message` would otherwise silently drop the disclosure |

## Affected Areas

| Area | Impact |
|------|--------|
| `lib/alethea/triggers.ex` | New: pause-for-patient function; Modified: `resume_trigger/3`'s accepted statuses |
| `lib/alethea/triggers/trigger.ex` | Modified: status enum (+`"paused_by_patient"`) |
| `lib/alethea/jobs/telegram_message_worker.ex` | Modified: `/pausa` short-circuit before persistence |
| `lib/alethea/jobs/telegram_onboarding_worker.ex` | Modified: `welcome_text/1` disclosure |
| `lib/alethea_web/live/triggers_live/index.ex` | Modified: pause-reason badge for the new status |
| `lib/alethea_web/live/dashboard_live.ex`, `.../components/notification_center.ex` | Modified: new `:trigger_paused_by_patient` event |
| `priv/repo/migrations/` | New: migration to add `"paused_by_patient"` if `status` has a DB check constraint enumerating allowed values |

## Risks

| Risk | Likelihood | Mitigation |
|------|------------|------------|
| Reusing the crisis-pause query shape without its missing `kind` filter | Med | Call it out explicitly in design/tasks; add a regression test asserting reactive triggers are untouched by `/pausa` |
| `/pausa` false-triggering on near-matches (`"/Pausa "`, `"pausa"` without slash) | Low-Med | Pin the exact match rule (literal, case-insensitive, trimmed, slash required) in spec; test the near-miss cases explicitly |
| Professional misses the real-time notification while offline and never learns why messages stopped | Med | The durable badge in `triggers_live` is the actual guarantee, not the PubSub bell — spec must require the badge, not just the notification |
| Onboarding disclosure lost for professionals with a custom welcome message | Med | Append unconditionally in `welcome_text/1`, not only in the default template |

## Rollback Plan

Revert the PR(s). The new status value and badge are additive; if a DB check constraint needs a migration, its down migration removes the added enum value (safe only if no row uses it yet).

## Dependencies

- #440 (closed — was blocking, no longer blocks).
- #443 (crisis pause) and #445 (delivery-failure pause) — not functional dependencies, but the precedent this issue's implementation must match.

## Success Criteria

- [ ] All 4 acceptance criteria of #446 covered by tests through `TelegramMessageWorker.perform/1` and `Triggers` context tests.
- [ ] A test proves reactive triggers are unaffected by `/pausa`.

## Decisions (locked by user)

1. **Patient-facing confirmation reply**: confirmed — `/pausa` gets a short fixed confirmation reply (recommended default accepted).

## Decisions pending user confirmation

1. **Exact Spanish copy** for the onboarding disclosure sentence, the professional notification text, and the `triggers_live` badge reason — none specified in the issue. Design will propose placeholder copy; needs explicit sign-off before apply.
