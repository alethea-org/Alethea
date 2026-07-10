# Design — `professional-welcome-message`

## Architecture

Single capability, three touch points, no new module:

1. **`Professional` schema** — add `field :welcome_message, :string`, cast in
   `changeset/2` alongside `:crisis_message`. Migration: `add
   :welcome_message, :string` on `professionals` (nullable, no default,
   no backfill needed).

2. **`DashboardLive`** — add `handle_event("save_welcome_message", %{"welcome_message" => message}, socket)`,
   calling `Accounts.update_professional(professional, %{welcome_message: message})`,
   mirroring `save_crisis_message/2` exactly. Verified there is no
   empty-string normalization anywhere in the `crisis_message` path
   (`Professional.changeset/2` casts it as a plain string, no
   `update_change/3`) — `welcome_message` matches that behavior as-is
   rather than introducing a divergent nicety for one field only.

3. **`TelegramOnboardingWorker`** —
   - `handle_verified/5`: preload `:professional` on `patient` before calling
     `welcome_text/1` (one `Repo.preload/2` call, mirroring
     `TelegramMessageWorker`'s crisis-branch preload).
   - `welcome_text/1`: resolve `template = patient.professional.welcome_message || default_welcome_template()`,
     then interpolate: if `template =~ "%{name}"`, `String.replace(template, "%{name}", name || "")`
     (trim resulting double-spaces if name is nil — see Decisions below);
     else return `template` verbatim. The existing system-default templates
     (with/without name) become the `default_welcome_template/0` /
     `default_welcome_template(name)` private helpers, unchanged in wording.

## Interpolation convention decision

`crisis_message` needs no interpolation (it's read verbatim). The welcome
message needs the patient's first name. Two options considered:

- **`%{name}` placeholder, professional opts in** (chosen) — matches Elixir's
  own string-interpolation mental model, keeps the default templates'
  current wording unchanged (no forced placeholder), and a professional who
  writes a name-agnostic message ("¡Hola! Este es tu espacio seguro.") isn't
  forced to include a token they don't want.
- Force-append the name if absent — rejected: would mangle a
  professional's intentionally name-agnostic copy.

## No preload regression risk

`TelegramAuthController`'s six-digit web-fallback path enqueues the SAME
`TelegramOnboardingWorker` (per PR #4's design decision to not duplicate the
verify/consume/welcome state machine), so the preload fix in
`handle_verified/5` covers both entry points with one change.

## Out of scope

- No rich templating (no loops/conditionals) — a single placeholder,
  matching `crisis_message`'s plain-string simplicity.
- No admin-facing preview UI for the welcome message — the existing
  crisis-message textarea has none either.
- No migration/backfill of existing `professionals` rows — `welcome_message`
  starts `nil` for everyone, which resolves to the current system-default
  behavior (no behavior change for existing professionals until they opt in).
