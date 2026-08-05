# Tasks: Retire WhatsApp Messaging Path (#87)

## Review Workload Forecast

| Field | Value |
|-------|-------|
| Estimated changed lines | PR-A total ~950-1263 (lib ~626 + test ~637, per design) |
| 400-line budget risk | High (PR-A whole), Low-Medium per sub-PR after split |
| Chained PRs recommended | Yes |
| Suggested split | PR-A1 → PR-A2 → PR-A3 → PR-A4 → PR-B (5-slice chain) |
| Delivery strategy | auto-forecast |
| Chain strategy | feature-branch-chain |

Decision needed before apply: No
Chained PRs recommended: Yes
Chain strategy: feature-branch-chain
400-line budget risk: High

Rationale: PR-A alone (worker+controller+consent+rate_limiter+reminder deletions
plus tests) is delete-heavy and clears 400 lines by ~2-3x. Split into 4 slices so
each stays near/under budget; lockstep edits (router, application.ex, scheduler)
ride with the module deletions they reference, never split apart.

### Suggested Work Units

| Unit | Goal | Likely PR | Focused test command | Runtime harness | Rollback boundary |
|------|------|-----------|----------------------|-----------------|-------------------|
| 1 | Delete webhook ingest (worker+controller+tests+fixtures), remove route | PR-A1 (base: tracker) | `mix test test/alethea_web/controllers test/alethea_jobs/process_message_worker_test.exs` | `mix precommit` | revert restores controller, worker, route |
| 2 | Delete consent/rate-limit modules+test, application.ex lockstep, drop `:whatsapp` queue | PR-A2 (base: A1) | `mix test test/alethea/rate_limiter_test.exs` | `mix precommit` + boot check | revert restores consent/rate-limit + children |
| 3 | Delete SessionReminderWorker+test, scheduler lockstep | PR-A3 (base: A2) | `mix test test/alethea_jobs/daily_scheduler_worker_test.exs` | `mix precommit` | revert restores worker + enqueue |
| 4 | Config/dashboard/test-helper sweep (dev/runtime/docker/dashboard/oban_helper) | PR-A4 (base: A3) | `mix test test/support/oban_helper_test.exs` | `mix precommit` | revert restores env/queue-list entries |
| 5 | Delete WhatsApp.Client + shared-worker whatsapp branch | PR-B (base: A4) | `mix test test/alethea_jobs/session_timeout_worker_test.exs` | `mix precommit` + grep gate | revert restores client + branch |

Each unit ends with `mix compile --warnings-as-errors && mix test` green before opening the next slice.

## PR-A1: Webhook Ingest Removal
**Satisfies**: No WhatsApp Inbound Path (webhook route removed scenario)

- [ ] A1.1 Delete `test/alethea_web/controllers/whatsapp_webhook_controller_test.exs`, `test/alethea_jobs/process_message_worker_test.exs`
- [ ] A1.2 Delete `lib/alethea_web/controllers/whatsapp_webhook_controller.ex`, `lib/alethea_jobs/process_message_worker.ex`
- [ ] A1.3 Delete `test/support/fixtures/whatsapp_fixtures.ex`, `test/fixtures/whatsapp/*.json`
- [ ] A1.4 Edit `lib/alethea_web/router.ex:45-50` — remove `/webhooks/whatsapp` scope (lockstep with controller delete)
- [ ] A1.5 Add/confirm a router-level assertion that GET/POST `/webhooks/whatsapp` no longer matches (404), proving the scenario
- [ ] A1.6 Boundary: `mix compile --warnings-as-errors && mix test` green

## PR-A2: Consent/Rate-Limit Removal
**Satisfies**: App Boots Clean Without WhatsApp Supervision (lockstep scenario)

- [ ] A2.1 Delete `test/alethea/rate_limiter_test.exs`
- [ ] A2.2 Delete `lib/alethea/whatsapp/consent_cache.ex`, `consent_log.ex`, `lib/alethea/rate_limiter.ex`
- [ ] A2.3 Edit `lib/alethea/application.ex:19-20` — remove `ConsentCache` + `RateLimiter` children (lockstep, same commit as A2.2)
- [ ] A2.4 Edit `config/config.exs:53` — remove `whatsapp: 20` Oban queue (last consumer now gone)
- [ ] A2.5 Boundary: boot smoke test (`mix phx.server` or `Application.start/2` test) + `mix test` green

## PR-A3: Reminder Retirement
**Satisfies**: No WhatsApp Patient Messaging Egress (reminders disabled scenario)

- [ ] A3.1 Delete `test/alethea_jobs/session_reminder_worker_test.exs`
- [ ] A3.2 Delete `lib/alethea_jobs/session_reminder_worker.ex`
- [ ] A3.3 Edit `lib/alethea_jobs/daily_scheduler_worker.ex:32-36` — remove `SessionReminderWorker` enqueue (lockstep)
- [ ] A3.4 Optionally strengthen `daily_scheduler_worker_test.exs` with a no-SessionReminder-enqueued assertion
- [ ] A3.5 Boundary: `mix test` green (only `WeeklyReportWorker` enqueue asserted)

## PR-A4: Config/Dashboard/Helper Sweep
**Satisfies**: No WhatsApp Inbound Path (queue absent scenario)

- [ ] A4.1 Edit `config/dev.exs:77-81`, `config/runtime.exs:128-131` — remove `:whatsapp` api config/env
- [ ] A4.2 Edit `docker-compose.yml:30-33` — remove `WHATSAPP_*` env vars
- [ ] A4.3 Edit `lib/alethea_web/live/oban_dashboard_live.ex:17` — remove `:whatsapp,` from queue list
- [ ] A4.4 Edit `test/support/oban_helper.ex:33`, `test/support/oban_helper_test.exs:20` — remove `drain_queue(queue: :whatsapp)`
- [ ] A4.5 Verify KEEP set untouched and green: `whatsapp/client.ex`, `client_behaviour.ex`, `config/test.exs:30-35`, `test_helper.exs:4` Mox.defmock, `session_timeout_worker` whatsapp branch
- [ ] A4.6 Boundary (end of PR-A chain): `mix compile --warnings-as-errors && mix test` green, no `WHATSAPP_*`/`:whatsapp` queue refs in `config/*.exs`

## PR-B: Client + Shared-Worker Cleanup (blocked by PR-A, base: A4)
**Satisfies**: PR-B End State Has No WhatsApp Client References; Telegram Path Non-Regression

- [ ] B.1 Delete `lib/alethea/whatsapp/client.ex`, `client_behaviour.ex`
- [ ] B.2 Edit `config/test.exs:35` (drop `:whatsapp_client`) and `:30-33` (drop `:whatsapp` api)
- [ ] B.3 Edit `test/test_helper.exs:4` — delete `Mox.defmock` `ClientMock` line
- [ ] B.4 Edit `lib/alethea_jobs/session_timeout_worker.ex` — strip `whatsapp_client/0` (119-120), legacy `perform/1` clause (171-191), `send_goodbye` `"whatsapp"` branch (267-269)
- [ ] B.5 Confirm `perform/1` keeps only the `"channel" => "telegram"` clause (149-169); `send_goodbye` keeps telegram + unknown-channel backstop only
- [ ] B.6 Edit `test/alethea_jobs/session_timeout_worker_test.exs:58-119` — delete only the 2 whatsapp test bodies; keep shared top-level `setup` (17-56)
- [ ] B.7 Edit `lib/alethea/ai/phi_worker_behaviour.ex:3` — doc "WhatsApp AI pipeline" → channel-neutral
- [ ] B.8 Edit `lib/alethea/telegram/log_redactor.ex:38-39` — fix stale doc comment
- [ ] B.9 Grep gate: `rg -i "Alethea\.WhatsApp\.Client|whatsapp_client|:whatsapp" lib test config` → only Category-C schema remnants (`whatsapp_number_hash`, `encrypted_whatsapp_number`, `messages.whatsapp_message_id`)
- [ ] B.10 Boundary: `mix compile --warnings-as-errors && mix test` green (Telegram journaling, crisis, session lifecycle unaffected)

## Out of Scope
Schema strip (columns stay dead-but-harmless), `CacheBodyReader` open question, Telegram reminder build (#97).
