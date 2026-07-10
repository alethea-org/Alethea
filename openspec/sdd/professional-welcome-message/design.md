# Design — `professional-welcome-message`

## Architecture

Single capability, three touch points, no new module:

1. **`Professional` schema** — CORRECTED post-apply: this project has TWO
   parallel `Professional` schemas — `Alethea.Accounts.Professional`
   (`lib/alethea/accounts/professional.ex`, legacy, WhatsApp-era) and
   `Alethea.Foundation.Accounts.Professional`
   (`lib/alethea/foundation/accounts/professional.ex`, the newer v2/Telegram
   foundation). Both happen to have their own `crisis_message` field, which
   is what made the wrong one easy to assume. `DashboardLive` (and its
   `save_crisis_message`/`save_welcome_message` events) uses
   `alias Alethea.Accounts` — the LEGACY module — via
   `Alethea.Accounts.update_professional/2`, which only exists on the legacy
   `Accounts` context. `welcome_message` was added to the LEGACY
   `Alethea.Accounts.Professional`, not the foundation one. Migration:
   `add :welcome_message, :string` on the `professionals` table (nullable,
   no default, no backfill needed).

2. **`DashboardLive`** — add `handle_event("save_welcome_message", %{"welcome_message" => message}, socket)`,
   calling `Accounts.update_professional(professional, %{welcome_message: message})`,
   mirroring `save_crisis_message/2` exactly.

   Empty-string handling — CORRECTED post-apply: verified empirically
   (`Professional.changeset(existing, %{crisis_message: ""})` then
   `Ecto.Changeset.get_change/2`) that `Ecto.Changeset.cast/4`'s default
   `empty_values: [""]` option normalizes an incoming `""` to `nil` before
   it reaches `changes` — this is Ecto's own default behavior, not
   application code, and it already applied to `crisis_message` (an
   earlier draft of this doc incorrectly claimed no such normalization
   existed). `welcome_message` gets the same normalization for free via
   the identical `cast/4` call — no extra code needed, and clearing the
   field through the dashboard correctly falls back to the system default.

3. **`TelegramOnboardingWorker`** — CORRECTED post-apply: a bare
   `Repo.preload(patient, :professional)` on the FOUNDATION patient (as
   originally planned here) would have preloaded the FOUNDATION
   `Professional` — the wrong schema, disconnected from the one
   `DashboardLive` actually edits (see point 1). The implemented resolution
   bridges to the legacy Patient first (`Foundation.Accounts.legacy_patient/1`,
   the same bridge `TelegramMessageWorker`'s crisis branch already uses for
   `crisis_message`), then loads `:professional` on THAT legacy Patient via
   `Alethea.Accounts.get_patient_with_professional/1`. Falls back to the
   system default (does not raise) if the foundation patient has no
   `legacy_patient_id` at all.
   - `welcome_text/1`: resolve `template = custom_welcome_message(patient) || default_welcome_template()`,
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
