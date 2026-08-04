# Design: Retire WhatsApp Messaging Path (#87)

## Technical Approach

Pure removal in two chained sibling PRs. PR-A deletes the standalone WhatsApp
message path and fully retires the reminder worker; PR-B removes the residual
`WhatsApp.Client` and the shared-worker coupling once nothing references it.
No new behavior, no migration. Each PR compiles `--warnings-as-errors` and keeps
full `mix test` green at its own boundary. Line refs below were re-verified
against `main` (this branch base) and are current.

## Architecture Decisions

### Decision: SessionReminderWorker — delete, not inert no-op
**Choice**: Delete `session_reminder_worker.ex` + its test AND remove the
`DailyScheduler` enqueue (daily_scheduler_worker.ex:32-36). **Alternatives**:
(a) inert `perform/1` returning `:ok` but keep the module + enqueue.
**Rationale**: The success goal is "nothing *enqueues or sends* a WhatsApp
reminder." An inert no-op still enqueues a dead job every day and keeps a live
`WhatsApp.Client` consumer, which would block PR-B's client deletion. Removing
the enqueue is mandatory either way; once removed the module is fully dead, so
deletion is strictly cleaner. #97 will build the Telegram reminder fresh.

### Decision: KEEP the shared coupling in PR-A
**Choice**: `whatsapp/client.ex`, `client_behaviour.ex`, `config/test.exs`
`:whatsapp` + `:whatsapp_client`, `test_helper` Mox.defmock, and the
`session_timeout_worker` whatsapp branch stay in PR-A. **Alternatives**: remove
everything in one PR. **Rationale**: `session_timeout_worker_test.exs` (2 tests,
lines 58-119) directly exercises the whatsapp `perform/1` clause via
`ClientMock`. Removing the client in PR-A would break those + blow the 400-line
budget. PR-B removes them together.

### Decision: Deletion-first ordering keeps the suite green
Delete test files before their subjects; remove supervision children in the same
commit as the modules they name (lockstep) so boot never references a missing
child.

## Data Flow (removed path)

    POST /webhooks/whatsapp → WhatsappWebhookController → RateLimiter
        → ProcessMessageWorker (queue :whatsapp) → WhatsApp.{Client,ConsentCache,ConsentLog}
    DailyScheduler → SessionReminderWorker → WhatsApp.Client   (both deleted)

Telegram path (`telegram_webhook` → `telegram_message_worker` → shared
Clinical/PhiWorker → channel-neutral `SessionTimeoutWorker`) is structurally
independent and untouched.

## File Changes — PR-A (pure removal + reminder retirement)

| File | Action | Note |
|------|--------|------|
| `lib/alethea_jobs/process_message_worker.ex` | Delete | queue `:whatsapp` |
| `lib/alethea_web/controllers/whatsapp_webhook_controller.ex` | Delete | |
| `lib/alethea/whatsapp/consent_cache.ex`, `consent_log.ex` | Delete | |
| `lib/alethea/rate_limiter.ex` | Delete | only caller was webhook:39 |
| `lib/alethea_jobs/session_reminder_worker.ex` | Delete | see decision |
| tests: `whatsapp_webhook_controller_test.exs`, `process_message_worker_test.exs`, `rate_limiter_test.exs`, `session_reminder_worker_test.exs` | Delete | delete before subjects |
| `test/support/fixtures/whatsapp_fixtures.ex`, `test/fixtures/whatsapp/*.json` | Delete | |
| `lib/alethea_web/router.ex:45-50` | Modify | remove `/webhooks/whatsapp` scope |
| `lib/alethea/application.ex:19-20` | Modify | remove `ConsentCache` + `RateLimiter` children — **lockstep with module deletes** |
| `lib/alethea_jobs/daily_scheduler_worker.ex:32-36` | Modify | remove `SessionReminderWorker` enqueue |
| `config/config.exs:53` | Modify | remove `whatsapp: 20` Oban queue |
| `config/dev.exs:77-81`, `config/runtime.exs:128-131` | Modify | remove `:whatsapp` api config |
| `docker-compose.yml:30-33` | Modify | remove `WHATSAPP_*` env |
| `lib/alethea_web/live/oban_dashboard_live.ex:17` | Modify | **NEW** — remove `:whatsapp,` from queue list |
| `test/support/oban_helper.ex:33`, `oban_helper_test.exs:20` | Modify | **NEW** — remove `drain_queue(queue: :whatsapp)` |

**KEEP in PR-A** (verify still green): `whatsapp/client.ex` + `client_behaviour.ex`,
`config/test.exs:30-35`, `test_helper.exs:4`, `session_timeout_worker` whatsapp
branch. `daily_scheduler_worker_test.exs` asserts only `WeeklyReportWorker`, so
the enqueue removal stays green (optionally add a no-SessionReminder assertion).

## File Changes — PR-B (residual client + shared cleanup, blocked by PR-A)

| File | Action | Note |
|------|--------|------|
| `lib/alethea/whatsapp/client.ex`, `client_behaviour.ex` | Delete | |
| `config/test.exs:35` (`:whatsapp_client`) + `:30-33` (`:whatsapp` api) | Modify | both dead once client gone |
| `test/test_helper.exs:4` (Mox.defmock ClientMock) | Modify | delete line |
| `lib/alethea_jobs/session_timeout_worker.ex` | Modify | strip `whatsapp_client/0` (119-120), legacy `perform/1` clause (171-191), `send_goodbye` `"whatsapp"` branch (267-269) |
| `test/alethea_jobs/session_timeout_worker_test.exs:58-119` | Modify | delete only the 2 whatsapp test bodies; **keep top-level `setup` 17-56** (shared with #86 Telegram describe-block) |
| `lib/alethea/ai/phi_worker_behaviour.ex:3` | Modify | doc "WhatsApp AI pipeline" → channel-neutral |
| `lib/alethea/telegram/log_redactor.ex:38-39` | Modify | stale doc comment |

### Remaining `perform/1` shape after PR-B (telegram-only)
Keep only the `"channel" => "telegram"` clause (149-169). `send_goodbye` keeps
the `"telegram"` branch + the unknown-channel backstop; drop the `"whatsapp"`
branch. Delete the `%{"phone" => phone}` clause entirely.

## Interfaces / Contracts
No new interfaces. `WhatsApp.ClientBehaviour` (the only removed contract) has no
remaining implementors or callers after PR-B.

## Testing Strategy

| Layer | What | Approach |
|-------|------|----------|
| Compile | no dangling refs | `mix compile --warnings-as-errors` per PR |
| Suite | green at each boundary | full `mix test` per PR |
| Non-regression | Telegram journaling, crisis path, session lifecycle/summaries | must stay green: `telegram_message_worker_test.exs`, `session_timeout_worker_test.exs` (Telegram describe-block), `session_manager_test.exs`, crisis/R3 worker tests, `weekly_report_worker_test.exs`, `daily_scheduler_worker_test.exs`, `accounts_test.exs` |
| Grep gate (PR-B end) | only intended remnants | `rg -i "Alethea\.WhatsApp\.Client|whatsapp_client|:whatsapp" lib test config` → expect only Category-C schema remnants (`whatsapp_number_hash`, `encrypted_whatsapp_number`, `messages.whatsapp_message_id`) |

## Threat Matrix
Routing boundary only: PR-A removes `/webhooks/whatsapp` (router.ex:45-50).
Verified isolated from the Telegram scopes (separate pipeline + controller);
removal leaves Telegram routing intact. No shell, subprocess, VCS/PR automation,
or executable-file classification is introduced. All other rows: **N/A**.

## Migration / Rollout
No migration. Category-C columns (`patients.whatsapp_number_hash`,
`encrypted_whatsapp_number` NOT NULL; `messages.whatsapp_message_id`) stay
**dead-but-harmless** — still required at patient registration; schema strip is
the deferred patient-identity channel-neutralization follow-up. Reminders stay
OFF until #97.

## Review Workload
Per-PR budget: each slice must land under 400 changed lines. PR-A is
delete-heavy (~626 lib + ~637 test lines split across the two PRs) — if PR-A
alone approaches the budget, deletions may sub-split (workers vs config), but the
lockstep router/application/config edits must ride together.

## Rollback
Per-PR revert on isolated feature branches. PR-B reverts independently (restores
client + shared branch). PR-A revert restores modules, supervision children,
config, dashboard/helper queue refs, and the reminder enqueue. No data-state
rollback (no schema change).

## Open Questions
- [ ] Confirm `AletheaWeb.CacheBodyReader` (lib/alethea_web/cache_body_reader.ex)
  is dead — endpoint.ex:45 wires `AletheaWeb.Plugs.CacheBodyReader` (different
  module). If unused it is a WhatsApp-doc remnant; deletion is optional and out
  of #87's message-path scope.
