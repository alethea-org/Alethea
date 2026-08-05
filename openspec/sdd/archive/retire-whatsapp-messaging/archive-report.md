# Archive Report — retire-whatsapp-messaging (#87)

**Change:** retire-whatsapp-messaging — retire the WhatsApp patient-messaging path (Telegram-only).
**Issue:** alethea-org/Alethea#87 (CLOSED). Final slice of PRD #83.
**PRs:** #98 (PR-A) + #99 (PR-B), squash-merged to `main`.
**Status:** ✅ shipped, verified, adversarially reviewed (3 judges each PR), merged.
**Store:** hybrid (Engram topic keys `sdd/retire-whatsapp-messaging/*`).

## What shipped

Telegram reached full journaling parity across #84–#86, so the legacy WhatsApp path was retired. Delivered as two chained PRs (pure deletion, `size:exception`):

**PR-A (#98) — message-path removal + reminder retirement**
- Deleted the WhatsApp message worker (`ProcessMessageWorker`, Oban queue `:whatsapp`), the Meta webhook controller + its `/webhooks/whatsapp` route, the WhatsApp consent stack (`ConsentCache`, `ConsentLog`), and `RateLimiter` (its only caller was the WhatsApp webhook), plus their tests and fixtures.
- Retired `SessionReminderWorker` (100% WhatsApp, no Telegram equivalent): removed the `DailyScheduler` enqueue and kept the worker **inert** so pre-retirement Oban jobs resolve to `:ok` instead of crashing on a missing module.
- Removed the `:whatsapp` Oban queue, WhatsApp dev/runtime/docker config, the dashboard queue entry, and the `oban_helper` drain — all in lockstep with the supervision-tree child removals.

**PR-B (#99) — residual client + shared-worker cleanup**
- Deleted `Alethea.WhatsApp.Client` + `ClientBehaviour`, the `:whatsapp_client` test binding + `:whatsapp` api config, and the `WhatsApp.ClientMock` defmock.
- Stripped the `SessionTimeoutWorker` whatsapp surface (`whatsapp_client/0`, the legacy phone-args `perform/1` clause, the `"whatsapp"` `send_goodbye/2` branch). The worker is now Telegram-only.
- Orphan-job handling: a legacy `%{"phone" => ...}` timeout job still closes + summarizes its session (channel-independent) and skips only the retired goodbye; a job matching neither shape raises `FunctionClauseError` (fails loud).
- Migrated the #86 SessionTimeoutWorker tests and refreshed stale doc references.

## Judgment Day (3 judges per PR: jd-judge-a + jd-judge-b + review-risk)

- **PR-A**: 0 build-breakers; Telegram left protected (its own secret-token plug). One operational finding (2/3 judges — orphaned `SessionReminderWorker` jobs) fixed in-PR by keeping the worker inert. Minor cleanups applied (dashboard grid, stale doc refs, a `refute_enqueued` regression test).
- **PR-B**: 0 CRITICAL/SEVERE. Convergent WARNING/SUGGESTION findings (orphan sessions not closing, an over-broad fallback clause, lost close-flow coverage) fixed in-PR: legacy jobs now close + summarize, malformed jobs fail loud, and close-flow coverage was restored on both the telegram and legacy paths.
- `mix precommit` green at each boundary (559 passed on `main` after PR-B). No regression to Telegram journaling, crisis handling, session lifecycle, or summaries.

## Follow-ups (documented, out of scope)

1. **Telegram session-reminder equivalent** — filed as **#97**. Session reminders are OFF until it ships (they were WhatsApp-only and already broken for Telegram patients).
2. **Patient-identity channel-neutralization (schema strip)** — `patients.whatsapp_number_hash` / `encrypted_whatsapp_number` remain `NOT NULL` and required at registration (`create_patient/2` rule + `PatientLive.Index` form); `messages.whatsapp_message_id` is a dead-but-harmless column. Removing them needs a migration + a registration-rule/UI change — deferred to a dedicated change.

## Feature status

**PRD #83 (Telegram-only journaling pipeline) is complete.** All four slices are merged: #84 (safe-path AI reply), #85 (session lifecycle), #86 (channel-neutral timeout + crisis atomicity), #87 (WhatsApp retirement). #83 is closed once this archive lands.
