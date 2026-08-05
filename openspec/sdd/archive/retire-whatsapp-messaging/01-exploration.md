# Exploration — retire-whatsapp-messaging (#87)

**Source:** #87 (final slice of PRD #83) — retire the WhatsApp messaging path (removal only, Telegram parity). Base: main @ 272a4c8.
**Store:** hybrid. Strict TDD (`mix test`).

## Two paths sharing one clinical core
- WhatsApp (to retire): whatsapp_webhook_controller → ProcessMessageWorker (queue :whatsapp) → Alethea.WhatsApp.{Client,ConsentCache,ConsentLog} → shared Clinical/Accounts.
- Telegram (keep): telegram_webhook_controller → telegram_message_worker → shared Clinical/PhiWorker → channel-neutral SessionTimeoutWorker (#86).
- Two patient-identity schemas: legacy Alethea.Accounts.Patient (patients table, FK target of Session.patient_id) + Foundation.Accounts.Patient (foundation_patients, Telegram-native, nullable legacy_patient_id bridge).

## Blast-radius classification (~30 files)

### A — Pure-WhatsApp, safe to delete
- lib/alethea_jobs/process_message_worker.ex (232, queue :whatsapp)
- lib/alethea_web/controllers/whatsapp_webhook_controller.ex (138)
- lib/alethea/whatsapp/{client.ex 40, client_behaviour.ex 4, consent_cache.ex 155, consent_log.ex 17}
- lib/alethea/rate_limiter.ex (151) — ONLY caller is whatsapp_webhook_controller:39 (reclassified to pure-WhatsApp); supervised application.ex:20
- lib/alethea_web/router.ex:45-50 (GET/POST /webhooks/whatsapp)
- lib/alethea/application.ex:19,20 (ConsentCache + RateLimiter children — MUST remove in lockstep or boot crashes)
- tests: whatsapp_webhook_controller_test.exs (337), process_message_worker_test.exs (229), test/support/fixtures/whatsapp_fixtures.ex (71), test/fixtures/whatsapp/*.json (9)
- config: config.exs:53 (:whatsapp Oban queue), dev.exs:77-81, runtime.exs:128-131, docker-compose.yml WHATSAPP_*
- priv migration add_whatsapp_consent_logs (self-contained; optional DROP TABLE companion)
- CAUTION: config/test.exs :whatsapp_client binding + test_helper.exs Mox.defmock(WhatsApp.ClientMock) MUST survive PR-A (still used by session_timeout + session_reminder tests).

### B — Shared/channel-neutral, touch carefully
- session_timeout_worker.ex: legacy whatsapp perform/1 clause (171-191, matches bare %{"phone"} no channel key) + "whatsapp" branch in send_goodbye (267-269) + whatsapp_client/0 (119-120). Dead in production once A gone (telegram always sends channel:"telegram"; only bare-phone producer was ProcessMessageWorker.schedule_session_timeout, in set A). BUT session_timeout_worker_test.exs exercises the whatsapp clause DIRECTLY (2 tests 58-119) — removing needs rewriting those + they SHARE a setup block with the #86 Telegram describe-block (don't break).
- clinical.ex save_message/8 whatsapp_message_id param 6 — channel-neutral, Telegram passes nil, harmless if left.
- clinical/message.ex whatsapp_message_id field (nullable, partial unique index) — dead-but-harmless.
- ai/phi_worker_behaviour.ex + telegram/log_redactor.ex — doc-only staleness, zero functional risk.

### C — Schema-level (the fork)
- messages.whatsapp_message_id — nullable, self-contained, low-risk either way.
- patients.whatsapp_number_hash + encrypted_whatsapp_number — **NOT NULL** (migration 20260512151206:30-31) + unique index. Accounts.create_patient/2 HARD-REJECTS blank whatsapp_number (accounts.ex:244-252); PatientLive.Index form has a REQUIRED "Número de WhatsApp" (291-306). So patient IDENTITY/onboarding is still WhatsApp-number-centric for ALL patients incl Telegram. Every test fixture fabricates a whatsapp_number just to satisfy NOT NULL. => #87 CAN be pure message-path removal with ZERO schema change; the whatsapp_number_hash columns are NOT dead (actively required at registration). Stripping them = migration + create_patient rule change + UI change = OUT OF SCOPE for #87.

## NEW FINDING (blocking) — SessionReminderWorker
lib/alethea_jobs/session_reminder_worker.ex (enqueued by daily_scheduler_worker:33 per patient with tomorrow's session) has NO Telegram equivalent — body is whatsapp_client().send_message(phone, @reminder_message) (line 25), decrypting patient.encrypted_whatsapp_number (52). Its tests genuinely exercise the WhatsApp send. Session reminders ARE patient messaging → contradicts "nothing routes patient messaging to WhatsApp." Deleting WhatsApp.Client/ClientBehaviour breaks it; and reminders already target fabricated placeholder numbers on Telegram patients (go nowhere). => whether WhatsApp.Client can be deleted in PR-A DEPENDS on this decision.

## Routing confirmation
router.ex:45-50 is the ONLY WhatsApp route; Telegram routes (62-77) structurally independent (different pipeline + controller). Removing 45-50 leaves Telegram untouched.

## Size / chunking
Pure-WhatsApp lib deletions ~626 lines + tests ~637 → combined ~1,250+, far over 400 budget. RECOMMENDED CHAINED:
- PR-A (pure removal, no shared code): delete ProcessMessageWorker + whatsapp_webhook_controller + whatsapp/* + rate_limiter + router route + application.ex children + :whatsapp queue/config + matching tests/fixtures. KEEP config/test.exs :whatsapp_client + test_helper Mox.defmock.
- PR-B (shared-code): strip session_timeout_worker whatsapp clause + its 2 tests, fix stale doc comments. Blocked by PR-A + the SessionReminderWorker decision.
- DEFERRED/separate issue: Category-C schema strip (whatsapp_number_hash NOT NULL removal + create_patient rule + PatientLive.Index UI) + SessionReminderWorker Telegram equivalent.

## DECISIONS TO SURFACE (not resolved here)
1. Scope depth: pure message-path removal (columns dead-but-harmless, no migration) — RECOMMENDED — vs full schema strip (high risk, out of #87 scope).
2. SessionTimeoutWorker whatsapp branch: remove in PR-B (RECOMMENDED, dead once PR-A lands) vs leave inert.
3. SessionReminderWorker (blocking): (a) keep WhatsApp.Client alive just for reminders (contradicts retirement, still broken for Telegram patients); (b) disable the reminder worker + its DailyScheduler enqueue in #87 + follow-up issue for Telegram reminders (RECOMMENDED — fully retires WhatsApp, and reminders are already broken for Telegram patients); (c) build Telegram reminders now (= new functionality, out of #87's "removal only" scope → separate prerequisite).
4. Chaining: PR-A + PR-B — RECOMMENDED.

## Recommendation
Approach 1 (message-path-only removal, chained PR-A + PR-B), schema fork + SessionReminderWorker surfaced as explicit decisions. Matches #87's "removal only."

**Ready for proposal:** contingent on decisions 1 & 3.
