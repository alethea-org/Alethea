# Apply Progress — `professional-welcome-message`

**Base branch:** `main` (telegram-paciente-foundation merged)
**Head branch:** `feat/professional-welcome-message`
**Strict TDD:** active — RED → GREEN → REFACTOR per task.

## Plan

| Task | Description | Status |
|------|--------------|--------|
| TASK-1 | `Professional.welcome_message` field + migration + dashboard control (C-1) | [x] Done |
| TASK-2 | Welcome-text resolution + professional preload (C-1) | [x] Done |

## Architecture discovery (read before trusting task file paths verbatim)

The repo has TWO parallel `Professional` schemas from an in-progress
migration (see `Alethea.Foundation.Accounts.Professional`'s own
moduledoc, "Boundary with legacy"):

- **Legacy** `Alethea.Accounts.Professional` (table `professionals`) —
  the one `DashboardLive` actually reads/writes (`alias Alethea.Accounts`),
  and the one `save_crisis_message` / `Accounts.update_professional/2`
  operate on.
- **Foundation v2** `Alethea.Foundation.Accounts.Professional` (table
  `foundation_professionals`) — used by the Telegram onboarding/patient
  auth-code flow (PR #4). A `Foundation.Accounts.Patient` `belongs_to
  :professional` this one directly.

There is **no professional-level bridge** between the two (only
patients have one, via `Foundation.Accounts.Patient.legacy_patient_id`).
`TelegramMessageWorker`'s crisis branch reaches the LEGACY professional
by bridging foundation-patient → legacy-patient (`FoundationAccounts.
legacy_patient/1`) → legacy-patient's `belongs_to :professional`
(`Accounts.get_patient_with_professional/1`), NOT by reading the
foundation patient's own `.professional` association directly.

Both `TASK-1` (dashboard-editable field) and `TASK-2` (worker
resolution) target the **legacy** `Alethea.Accounts.Professional`,
using the exact same legacy-patient bridge as `crisis_message`. This
is the only way the feature is functionally meaningful: a professional
edits their welcome message on the (legacy) dashboard, and the worker
must read that same row to have any effect. Reading the
foundation-namespace professional's `welcome_message` directly would
be a well-typed no-op — dashboard edits would never reach it.

This deviates from the literal file path named in the apply task
(`lib/alethea/foundation/accounts/professional.ex`) — confirmed via
`DashboardLive`'s `alias Alethea.Accounts` (legacy) and
`design.md`'s own migration line (`add :welcome_message, :string` on
table **`professionals`**, the legacy table name), plus the fact that
`Alethea.Foundation.Accounts` has no `update_professional/2` at all.

## Discovered pre-existing bug (fixed as part of TASK-1)

`Alethea.Accounts.Professional.changeset/2` had
`validate_required([:email, :password, :full_name])` unconditionally.
`:password` is `virtual: true` and is never reloaded from the DB, so
**every** partial update of an already-persisted professional (e.g.
`save_crisis_message`, and now `save_welcome_message`) failed
validation and silently fell into the `{:error, _changeset}` branch —
verified directly via `Ecto.Changeset.cast/4` + `validate_required/2`
against a professional with `password: nil`. This was a real,
previously-untested bug in the shipped `crisis_message` feature (no
test ever exercised the happy path of `save_crisis_message` — checked,
none exists). Fixed by only requiring `:password` when the professional
has no `:id` yet (registration), which also fixes `save_crisis_message`
as a side effect. See `lib/alethea/accounts/professional.ex`.

## Discovered discrepancy vs. design.md's "verified" crisis_message claim

`design.md` / `spec.md` state "verified: `crisis_message` has no
empty-to-nil normalization anywhere in `Professional.changeset/2`" and
expect clearing the field to `""` to persist as `""`. Directly tested
this claim against the actual `Professional.changeset/2` +
`Ecto.Changeset.cast/4` call (both for `crisis_message` and
`welcome_message`): `Ecto.Changeset.cast/4`'s default
`empty_values: [""]` normalizes an incoming `""` to `nil` for **any**
string field cast this way — this is Ecto's own built-in default, not
app code, and it applies identically to `crisis_message`. The "no
normalization" claim was incorrect (it likely only checked for
explicit `update_change/3`/custom logic, missing Ecto's implicit
default). `welcome_message` intentionally mirrors the real, verified
behavior (clearing → `nil`) rather than the assumed one. Test updated
accordingly with an inline comment recording this evidence.

## TDD Cycle Evidence

| Task | RED | GREEN | REFACTOR |
|------|-----|-------|----------|
| TASK-1 | `test/alethea/accounts/professional_test.exs` (new) + `dashboard_live_test.exs` "Welcome message" describe block — failed with `KeyError: key :welcome_message not found` / `ArgumentError: selector not found` before implementation | Added `welcome_message` field + cast to `lib/alethea/accounts/professional.ex`, migration `20260710120000_add_welcome_message_to_professionals.exs`, `save_welcome_message` handler in `dashboard_live.ex`, textarea block in `dashboard_live.html.heex` — all 10 tests in the two files green | Fixed the `validate_password_required/2` pre-existing bug (discovered mid-RED, was blocking GREEN); corrected the empty-string test expectation to match verified Ecto behavior instead of the design doc's assumption |
| TASK-2 | Added 5 new tests to `telegram_onboarding_worker_test.exs` (custom message + `%{name}`, no-placeholder verbatim, nil fallback, no-first-name gap collapse, empty-string verbatim) — 4 of 5 failed pre-implementation (fallback test incidentally matched old behavior) | Implemented `custom_welcome_message/1` (legacy-patient bridge + preload), `default_welcome_text/1`, `interpolate_welcome_name/2`, `collapse_placeholder_gap/2` in `telegram_onboarding_worker.ex` — all 16 tests in the file green | None needed beyond the initial implementation; kept `first_name/1` unchanged per design |

## Commit History

- `b57b71d` — `feat(accounts): add professional welcome_message field and dashboard control`
- `bd1ca04` — `feat(telegram): resolve welcome text from professional's custom message`

## Test Counts

- Baseline before this change: 554 tests, 0 failures, 5 skipped (2 doctests)
- After TASK-1: `mix test test/alethea/accounts/professional_test.exs test/alethea_web/live/dashboard_live_test.exs` → 10 tests, 0 failures, 1 skipped; full suite 555 tests green (net +1 test file, dashboard test extended)
- After TASK-2: `mix test test/alethea/jobs/telegram_onboarding_worker_test.exs` → 16 tests, 0 failures
- Final full suite: `mix test` → **559 tests, 0 failures, 5 skipped, 2 doctests**

## `mix precommit` Result

PASS — compile (no warnings introduced by this change; one pre-existing
`unused alias EmotionAnalysisWorker` warning confirmed present before
this change via `git stash` + recompile), `mix format` (applied one
line-wrap to `dashboard_live.html.heex`, committed), full test suite
(559 tests, 0 failures, 5 skipped).

## Requirements Coverage

| Requirement | Status | Evidence |
|---|---|---|
| `REQ-W-professional-welcome-override` | Done | `professional_test.exs` (nil default, set custom, clear-to-nil); `dashboard_live_test.exs` "Welcome message" describe |
| `REQ-W-welcome-text-resolution` | Done | `telegram_onboarding_worker_test.exs` custom-message and nil-fallback tests |
| `REQ-W-name-interpolation` | Done | placeholder-present / placeholder-absent / no-first-name-gap-collapse tests |
| `REQ-W-preload-professional` | Done | all TASK-2 tests exercise the bridge+preload path without raising; existing bind/failure-branch tests (patients with no legacy link) continue to pass via graceful fallback to default |

## Out of Scope (untouched, per proposal.md)

- `patient_auth_code.ex` verify/consume logic — not touched.
- Rich templating beyond `%{name}` — not added.
- Migration/backfill of existing `professionals` rows — not added
  (nullable column, no default).

## Status

2/2 tasks complete. Ready for verify.
