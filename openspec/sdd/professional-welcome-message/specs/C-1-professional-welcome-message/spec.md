# Spec — C-1: Professional-Configurable Welcome Message

**Capability:** C-1 — professional-configurable Telegram welcome message
**Change:** `professional-welcome-message`
**Status:** ADDED
**Module(s):** `Alethea.Foundation.Accounts.Professional`, `AletheaWeb.DashboardLive`,
`Alethea.Jobs.TelegramOnboardingWorker`

---

## Purpose

The system shall let a professional configure the welcome message their
patients receive on a successful Telegram bind, falling back to a system
default when unset — mirroring the existing `crisis_message` override
pattern on `Professional`.

---

## REQ-W-professional-welcome-override

The system shall add a nullable `welcome_message` string field to
`Professional`, editable via the same dashboard mechanism as
`crisis_message` (a `save_welcome_message` LiveView event backed by
`Accounts.update_professional/2`).

#### Scenario: professional sets a custom welcome message

- GIVEN a professional with `welcome_message: nil`
- WHEN they submit the welcome-message form with `"¡Bienvenido a Alethea!"`
- THEN `professional.welcome_message == "¡Bienvenido a Alethea!"`

#### Scenario: professional clears their custom welcome message

- GIVEN a professional with a non-nil `welcome_message`
- WHEN they submit the form with an empty string
- THEN `professional.welcome_message == ""` (verified: `crisis_message` has
  no empty-to-nil normalization anywhere in `Professional.changeset/2` or
  `DashboardLive.handle_event("save_crisis_message", ...)` — this feature
  matches that exact, existing behavior rather than inventing a divergent
  one). Note this means an empty string does NOT fall back to the system
  default (`"" || default` evaluates to `""` in Elixir, since only `nil`/
  `false` are falsy) — a pre-existing quirk of the `crisis_message` pattern,
  not something this change introduces or fixes.

---

## REQ-W-welcome-text-resolution

The system shall resolve the onboarding welcome text as
`patient.professional.welcome_message || <system default>`, where the system
default is read from `Application.get_env(:alethea, :default_welcome_message, ...)`,
matching the `crisis_message` / `crisis_support_message` fallback pattern.

#### Scenario: professional has a custom welcome message

- GIVEN patient P's professional has `welcome_message: "¡Hola! Este es tu espacio."`
- WHEN P successfully binds their Telegram chat
- THEN the enqueued welcome body is derived from the professional's custom
  message (with the patient's first name interpolated, see below), not the
  system default

#### Scenario: professional has no custom welcome message

- GIVEN patient P's professional has `welcome_message: nil`
- WHEN P successfully binds their Telegram chat
- THEN the enqueued welcome body is derived from the system default template
  (unchanged from the current PR #4 behavior)

---

## REQ-W-name-interpolation

The system shall interpolate the patient's first name (when known) into
whichever template is active (custom or default), using a `%{name}`
placeholder convention in custom text; if the professional's custom text
contains no `%{name}` placeholder, the name is not force-appended (the
professional's copy is respected verbatim) — this differs from
`crisis_message`, which has no interpolation need.

#### Scenario: custom message contains the placeholder

- GIVEN `welcome_message: "¡Hola %{name}! Bienvenido."` and patient first name `"Ana"`
- WHEN the welcome is built
- THEN the body is `"¡Hola Ana! Bienvenido."`

#### Scenario: custom message has no placeholder

- GIVEN `welcome_message: "Bienvenido a tu espacio."` (no `%{name}`)
- WHEN the welcome is built
- THEN the body is `"Bienvenido a tu espacio."` verbatim (no name appended)

#### Scenario: system default, patient has no first name on file

- GIVEN `welcome_message: nil` and `patient.profile_name: nil`
- THEN the system default's generic-greeting branch is used (same fallback
  already implemented in PR #4's `welcome_text/1`)

---

## REQ-W-preload-professional

The system shall preload `:professional` on the patient struct before
resolving welcome text, since `consume_patient_auth_code/3`'s `{:ok, patient}`
does not preload it today (unlike the crisis branch in
`TelegramMessageWorker`, which already preloads `:professional` for
`crisis_message`).

#### Scenario: welcome resolution does not raise on an unloaded association

- GIVEN the patient struct returned by `consume_patient_auth_code/3`
- WHEN `TelegramOnboardingWorker` resolves the welcome text
- THEN `patient.professional` is preloaded (not `%Ecto.Association.NotLoaded{}`)
  before `.welcome_message` is accessed
