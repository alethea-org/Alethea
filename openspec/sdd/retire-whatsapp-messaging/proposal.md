# Proposal: Retire WhatsApp Messaging Path (#87)

## Intent

Telegram now has parity for patient journaling, crisis, and session lifecycle. The
legacy WhatsApp messaging path is redundant, unmaintained, and already broken for
Telegram-native patients (reminders send to placeholder numbers). Final slice of
PRD #83: remove the WhatsApp message path so there is a single, maintained channel.
Removal only — no new functionality.

## Scope

### In Scope
- Delete pure-WhatsApp modules: `ProcessMessageWorker`, `whatsapp_webhook_controller`, `whatsapp/{client,client_behaviour,consent_cache,consent_log}` (client + behaviour in PR-B), `rate_limiter`.
- Remove `router.ex:45-50` route, `application.ex:19-20` supervision children (lockstep), `:whatsapp` Oban queue + WhatsApp config (config/dev/runtime/docker-compose).
- Delete WhatsApp tests + fixtures.
- DISABLE `SessionReminderWorker` (make inert) + remove its `DailyScheduler` enqueue; adjust/remove its test.
- PR-B: strip `SessionTimeoutWorker` whatsapp branch (perform clause, send_goodbye branch, `whatsapp_client/0`) + its 2 tests; delete `whatsapp/client` + behaviour, `config/test.exs :whatsapp_client`, `test_helper` Mox defmock; fix stale doc comments.

### Out of Scope
- **Schema strip** (deferred follow-up: patient-identity channel-neutralization): `messages.whatsapp_message_id`, `patients.whatsapp_number_hash`/`encrypted_whatsapp_number` stay DEAD-BUT-HARMLESS. NOT NULL removal + `create_patient/2` rule change + `PatientLive.Index` UI change excluded — patient onboarding is still WhatsApp-number-centric.
- **Telegram reminder equivalent**: filed as alethea-org/Alethea#97. Reminders are OFF until #97 ships.

## Capabilities

### New Capabilities
- None

### Modified Capabilities
- None (pure removal + config; no `openspec/specs/` exists, no spec-level requirement deltas)

## Approach

Chained sibling PRs (combined ~1,250+ lines, far over 400 budget):
- **PR-A** — pure removal + reminder disable. KEEP `whatsapp/client` + behaviour, `config/test.exs :whatsapp_client`, `test_helper` Mox defmock, and the `session_timeout_worker` whatsapp branch (still referenced by `session_timeout_worker_test` until PR-B).
- **PR-B** (blocked by PR-A) — delete residual client + shared-worker cleanup. Coupling rationale: disabling the reminder worker in PR-A is what frees `WhatsApp.Client` for deletion in PR-B.

## Affected Areas

| Area | Impact | Description |
|------|--------|-------------|
| `lib/alethea_jobs/process_message_worker.ex` | Removed | PR-A |
| `lib/alethea_web/controllers/whatsapp_webhook_controller.ex` | Removed | PR-A |
| `lib/alethea/whatsapp/{consent_cache,consent_log}.ex` | Removed | PR-A |
| `lib/alethea/rate_limiter.ex` | Removed | PR-A (only caller was webhook) |
| `lib/alethea/{router,application}.ex` | Modified | Route + supervision children (lockstep) |
| `config/{config,dev,runtime}.exs`, `docker-compose.yml` | Modified | `:whatsapp` queue + WHATSAPP_* |
| `lib/alethea_jobs/session_reminder_worker.ex` + `daily_scheduler_worker.ex` | Modified | Disable worker + enqueue |
| `lib/alethea/whatsapp/{client,client_behaviour}.ex` | Removed | PR-B |
| `lib/alethea_jobs/session_timeout_worker.ex` | Modified | Strip whatsapp branch (PR-B) |
| WhatsApp tests + fixtures | Removed | PR-A/PR-B |

## Risks

| Risk | Likelihood | Mitigation |
|------|------------|------------|
| Reminders off until #97 | High (intended) | Documented; already broken for Telegram patients; #97 filed |
| Supervision-tree lockstep — boot crash if children not removed with modules | Med | Remove `application.ex:19-20` in same PR-A commit as module deletions |
| `session_timeout_worker_test` shares setup with #86 Telegram describe-block | Med | PR-B rewrites only whatsapp tests; keep Telegram setup intact |
| Dangling refs to deleted modules | Med | `--warnings-as-errors` + full suite green at each PR boundary |

## Rollback Plan

Pure deletions on isolated feature branches — revert per PR. PR-B reverts independently (leaves client + branch in place). PR-A revert restores modules, supervision children, config, and reminder enqueue. No migrations, no schema change → no data-state rollback needed.

## Dependencies

- PR-B blocked by PR-A.
- Follow-ups: #97 (Telegram reminders), patient-identity channel-neutralization (schema strip).

## Success Criteria

- [ ] No WhatsApp message-path code/routes/config remain (except deferred dead-but-harmless columns).
- [ ] Each PR compiles `--warnings-as-errors` and full `mix test` green at its own boundary.
- [ ] No regression to Telegram journaling, crisis, session lifecycle, or session summaries.
