# Tasks: /pausa command, onboarding notice and professional notification (#446)

**Forecast**: ~450-600 lines (code + tests). Chained PRs: likely 2 slices — S1 domain+worker (the behavior), S2 UI+onboarding+notification (the surfacing). Confirm actual size after S1's diff; split further only if needed.

## Phase 1 — Domain: pause/resume on `Trigger`

- [x] 1.1 `lib/alethea/triggers/trigger.ex`: add `"paused_by_patient"` to the `validate_inclusion(:status, [...])` list (no migration needed — this is a changeset validation, not a DB check constraint).
- [x] 1.2 `lib/alethea/triggers.ex`: add `pause_active_triggers_for_patient/1`, modeled on `pause_active_triggers_for_crisis/1` (L694) with an explicit `t.kind == "active"` filter the crisis function lacks. Broadcasts `{:trigger_paused_by_patient, %{patient_id, professional_id, count}}` on `"psychologist:alerts"` when `count > 0`.
- [x] 1.3 `lib/alethea/triggers.ex`: extend `resume_trigger/3`'s status guard (L677-679) to also accept `"paused_by_patient"`.
- [x] 1.4 `lib/alethea/triggers.ex`: add a `%Trigger{status: "paused_by_patient"} -> Repo.rollback(:paused_by_patient)` clause to `activate_trigger/3` (L620-624), for parity with the two existing paused-status clauses.
- [x] 1.5 `test/alethea/triggers_test.exs`: extend the pause/resume block (~L341-511) — `pause_active_triggers_for_patient/1` pauses active-kind, leaves reactive-kind `active`; writes one audit row per paused trigger; deletes scheduled jobs; broadcasts; `resume_trigger/3` accepts `"paused_by_patient"` and revalidates an expired one-shot schedule the same way it does for the other two statuses.

## Phase 2 — Telegram worker: `/pausa` command

- [x] 2.1 `lib/alethea/jobs/telegram_message_worker.ex`: add `pause_command?/1` (trim + downcase, exact `"/pausa"` match).
- [x] 2.2 `lib/alethea/jobs/telegram_message_worker.ex`: in `process_bound_message/5` (L115), check `pause_command?/1` before `empty_text?/1`; on match, call new `handle_pause_command/4` instead of falling through to persistence.
- [x] 2.3 `lib/alethea/jobs/telegram_message_worker.ex`: add `handle_pause_command/4` (two clauses, mirroring `handle_empty_inbound/3`'s unlinked/linked split) — resolves the legacy patient, calls `Triggers.pause_active_triggers_for_patient/1`, then sends the fixed confirmation via `enqueue_outbound/6` with `message_id: nil` (same no-`Message`-row path as `enqueue_unregistered_reply/3`, L934-941).
- [x] 2.4 Confirmation copy constant: `"Listo, pausamos tus mensajes programados. Podés escribirme cuando quieras."`
- [x] 2.5 `test/alethea/jobs/telegram_message_worker_test.exs` (or new `telegram_message_worker_pause_test.exs`): drive `perform/1` with `/pausa`, `" /Pausa "`, and near-misses (`"pausa"`, `"necesito pausa"`); assert no `Message` row for the command, active-kind triggers paused, reactive-kind untouched, confirmation enqueued with no `message_id`, no scheduled `ActiveTriggerWorker` job remains.

## Phase 3 — Professional notification

- [ ] 3.1 `lib/alethea_web/live/dashboard_live.ex`: add a `handle_info({:trigger_paused_by_patient, ...}, socket)` clause next to `:crisis_detected` (L778), building a notification via `NotificationCenter.build_notification/2` and `send_update`.
- [ ] 3.2 `lib/alethea_web/live/dashboard_live/components/notification_center.ex`: add `notification_severity(:trigger_paused_by_patient, _)` (`:info`) and `notification_message(:trigger_paused_by_patient, ...)` → `"#{alias} pausó #{count} mensaje(s) programado(s) con /pausa."`.
- [ ] 3.3 `test/alethea_web/live/dashboard_live_test.exs`: assert the PubSub broadcast produces the notification.

## Phase 4 — Durable UI surfacing

- [ ] 4.1 `lib/alethea_web/live/triggers_live/index.ex` (~L1131-1144): add the `"paused_by_patient"` branch to the status-pill `cond`, label "Pausado por el paciente" (use `pt-pill--warning`; fall back to `pt-pill--risk` if that class doesn't exist in the stylesheet).
- [ ] 4.2 `lib/alethea_web/live/triggers_live/index.ex` (~L1210): add `"paused_by_patient"` to the "Reanudar" button's `in [...]` guard.
- [ ] 4.3 `lib/alethea_web/live/triggers_live/index.ex` (~L1248): add a durable reason block for `status == "paused_by_patient"`: "El paciente pausó este trigger con el comando /pausa. Podés reanudarlo cuando corresponda."
- [ ] 4.4 `test/alethea_web/live/triggers_live_test.exs`: assert the badge, reason block, and "Reanudar" button render for a `paused_by_patient` trigger.

## Phase 5 — Onboarding disclosure

- [ ] 5.1 `lib/alethea/jobs/telegram_onboarding_worker.ex`: in `welcome_text/1` (L211-233), append `@scheduling_disclosure` ("Tu psicólogo/a también puede programarte mensajes puntuales desde Alethea.") unconditionally after the `case` resolves (covers both default and custom-message branches).
- [ ] 5.2 `test/alethea/jobs/telegram_onboarding_worker_test.exs`: assert the disclosure is present for both the default template and a custom `welcome_message`.

## Success Criteria (from proposal, carried here)

- [ ] All 4 acceptance criteria of #446 covered by tests through `TelegramMessageWorker.perform/1` and `Triggers` context tests.
- [ ] A test proves reactive triggers are unaffected by `/pausa`.
