# Tasks — `professional-welcome-message`

**Base branch:** `main` (telegram-paciente-foundation is merged; this is a
standalone follow-up change, not part of that chain).
**Head branch:** `feat/professional-welcome-message`
**Strict TDD:** active — RED → GREEN → REFACTOR per task.
**Chain strategy:** single PR (small change, no chaining needed).

### TASK-1 — `Professional.welcome_message` field + migration + dashboard control (C-1)

- **Type:** impl + migration
- **Files (impl):**
  - `priv/repo/migrations/<timestamp>_add_welcome_message_to_professionals.exs`
  - `lib/alethea/foundation/accounts/professional.ex` (add field + cast)
  - `lib/alethea_web/live/dashboard_live.ex` (`handle_event("save_welcome_message", ...)`)
  - `lib/alethea_web/live/dashboard_live.html.heex` (textarea + save button,
    mirroring the existing crisis-message block)
- **Files (test):** `test/alethea/foundation/accounts/professional_test.exs` (or
  wherever `crisis_message` is currently tested — extend, don't duplicate),
  `test/alethea_web/live/dashboard_live_test.exs` (extend with the
  save_welcome_message event)
- **Requirements:** `REQ-W-professional-welcome-override`
- **Verify:** `mix test test/alethea/foundation/accounts/professional_test.exs test/alethea_web/live/dashboard_live_test.exs`
- **Commit:** `feat(accounts): add professional welcome_message field and dashboard control`
- **Est. lines:** 20 migration + 10 schema + 20 LiveView + 15 heex + 60 test ≈ **125**

### TASK-2 — Welcome-text resolution + professional preload (C-1)

- **Type:** impl
- **Files (impl):** `lib/alethea/jobs/telegram_onboarding_worker.ex` (preload
  `:professional` in `handle_verified/5`; `welcome_text/1` resolves
  `professional.welcome_message || default`, `%{name}` interpolation)
- **Files (test):** `test/alethea/jobs/telegram_onboarding_worker_test.exs`
  (extend with: custom message + name placeholder, custom message without
  placeholder, nil message falls back to default — both with and without a
  patient first name)
- **Requirements:** `REQ-W-welcome-text-resolution`, `REQ-W-name-interpolation`,
  `REQ-W-preload-professional`
- **Risks:** none new — reuses the existing preload pattern from
  `TelegramMessageWorker`'s crisis branch.
- **Verify:** `mix test test/alethea/jobs/telegram_onboarding_worker_test.exs`
- **Commit:** `feat(telegram): resolve welcome text from professional's custom message`
- **Est. lines:** 30 impl + 70 test ≈ **100**

### Totals

- **Tasks:** 2
- **Est. lines:** ~225 — well within the 400-line default budget (D1), no
  chaining or size:exception needed.

### Out of scope (per proposal.md)

- C-4 bind/auth-code mechanism itself — untouched.
- Rich templating, admin preview UI, migration/backfill of existing rows.
