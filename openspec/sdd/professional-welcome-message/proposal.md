# Proposal — `professional-welcome-message`

## Intent

Let a professional customize the Telegram onboarding welcome message their
patients receive on a successful bind, mirroring the existing `crisis_message`
override + system-default pattern on `Professional`.

## Why

PR #4 (`telegram-paciente-foundation`) shipped patient onboarding with a
single hardcoded welcome template (`"¡Hola{, name}! Tu cuenta de Telegram fue
vinculada correctamente..."`). This was a deliberate scope cut: the original
C-4 spec never required professional-level customization, and PR #4 was
already 1.5× its line budget. The cut was tracked as a named follow-up.

Alethea's own philosophy (CLAUDE.md "AI persona": personality configurable by
the psychologist) already has exactly this pattern for the crisis-lane
message (`Professional.crisis_message`, `Accounts.update_professional/2`, a
dashboard textarea) — the welcome message is the same shape of problem, one
step earlier in the patient's lifecycle.

## Scope

- Add `Professional.welcome_message` (nullable string), same shape as
  `crisis_message`.
- Add a save-message LiveView control on the professional's dashboard,
  mirroring the existing crisis-message textarea.
- `TelegramOnboardingWorker`'s welcome text resolves
  `patient.professional.welcome_message || <system default>`, interpolating
  the patient's first name into whichever template is active.
- Preload `:professional` wherever the onboarding worker needs it (the
  crisis branch in `TelegramMessageWorker` already does this for
  `crisis_message` — same pattern).

## Non-goals

- No change to the C-4 bind/auth-code mechanism itself (TTL, rate-limit,
  single-use, chat-collision rejection) — this change only touches welcome
  **copy** resolution.
- No rich templating engine — a single `%{name}` placeholder convention
  (or append-if-absent), matching the simplicity of `crisis_message`'s plain
  string.

## Risks

- Low. Additive field + one worker function change. No new external
  dependency, no migration touching existing data (nullable column, existing
  rows unaffected).
