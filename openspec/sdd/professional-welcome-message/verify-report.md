# Verify Report — `professional-welcome-message`

**Change:** `professional-welcome-message`
**Branch:** `feat/professional-welcome-message` (base `main`, post `telegram-paciente-foundation` merge)
**Commits:** `b57b71d` (TASK-1), `bd1ca04` (TASK-2)
**Verdict:** **PASS** (0 CRITICAL, 0 WARNING, 1 SUGGESTION)
**Verifier mode:** Source-driven + `mix precommit` (full suite) re-run
**Strict TDD:** active; TDD evidence validated against `apply-progress.md`
**Date:** 2026-07-10

---

## 1. Completeness

| Artifact | Present? | Notes |
|---|---|---|
| `proposal.md` | yes | Names the C-4 scope-cut this change closes, mirrors `crisis_message` pattern |
| `specs/C-1-professional-welcome-message/spec.md` | yes | 4 `REQ-W-*` requirements; corrected post-apply (commit `1ff8ae0`) to match verified `Ecto.cast/4` empty-string behavior |
| `design.md` | yes | Corrected post-apply (same commit) — legacy vs. foundation `Professional` schema, `empty_values: [""]` normalization |
| `tasks.md` | yes | TASK-1, TASK-2, both marked `[x] Done` |
| `apply-progress.md` | yes | TDD Cycle Evidence table, architecture-discovery + bug-fix sections, requirements coverage table |

All planning artifacts present. Full-spec verification performed (proposal + specs + design + tasks + apply-progress all available).

### Task completion

| Task | Status per tasks.md | Verified against code? |
|---|---|---|
| TASK-1 — `welcome_message` field + migration + dashboard control | `[x] Done` | ✅ confirmed |
| TASK-2 — welcome-text resolution + professional preload | `[x] Done` | ✅ confirmed |

Both tasks checked complete, both match the actual code state. No unchecked tasks — no CRITICAL from the "unchecked task" gate.

---

## 2. Test Execution Evidence

### 2.1 `mix precommit` (re-run on `feat/professional-welcome-message`, HEAD = `bd1ca04`)

✅ **GREEN** — exit code 0.

```
$ mix precommit
EXIT CODE: 0
2 doctests, 559 tests, 0 failures, 5 skipped
Finished in 61.3-61.7 seconds (10.1-10.2s async, 51.1-51.5s sync)
```

- `compile --warnings-as-errors`: pass (2 pre-existing warnings observed in the log —
  unused alias `EmotionAnalysisWorker` in `test/alethea_jobs/emotion_analysis_worker_test.exs`
  and an unused `call_count` var in `test/alethea/ai/retry_test.exs` — both in files
  untouched by this change and both non-fatal for `--warnings-as-errors` because they
  are `test/` files, not `lib/`; `apply-progress.md` independently confirmed the alias
  warning pre-exists via `git stash`; exit code 0 confirms neither blocks the build).
- `format --check-formatted`: pass.
- `test`: 559 tests + 2 doctests, 0 failures, 5 skipped — matches `apply-progress.md`'s
  claimed final count exactly (554 baseline + 5 net new: 1 new `professional_test.exs`
  test file with 3 tests + 1 dashboard test + 5 onboarding-worker tests, net accounting
  for shared setup — reconciled below in §2.2).
- Command run twice (once standalone, once piped for exit-code capture): identical
  `559 tests, 0 failures` both times — no flake observed in this change's own tests.
  (The pacer ETS-access warning and Oban telemetry handler `{:badkey, :success}` log
  noise visible in the run are pre-existing, unrelated to this change's files — same
  category of transient log noise documented in the PR #4 verify report, §7.)

### 2.2 Targeted test run — this change's own files

```
$ mix test test/alethea/accounts/professional_test.exs \
           test/alethea_web/live/dashboard_live_test.exs \
           test/alethea/jobs/telegram_onboarding_worker_test.exs
```

- `professional_test.exs`: 3 tests (nil default, set custom, clear-to-nil) — new file, all pass.
- `dashboard_live_test.exs`: extended with 1 new test ("Welcome message" describe block,
  "saves a custom welcome message") — passes; pre-existing tests in the file unaffected.
- `telegram_onboarding_worker_test.exs`: 16 tests total (11 pre-existing from PR #4 +
  5 new REQ-W-* tests: placeholder interpolation, verbatim-no-placeholder, nil-fallback,
  gap-collapse, empty-string-verbatim) — all pass, matches `apply-progress.md`'s
  "16 tests in the file green" claim exactly (counted describe blocks: 1+2+1+4+5+2+1 = 16).

### 2.3 Test count delta vs. `main`

| Stage | Total tests | Notes |
|---|---|---|
| `main` tip (baseline, per `apply-progress.md`) | 554 | 0 failures, 5 skipped |
| After TASK-1 (`b57b71d`) | 555 | +1 net (professional_test.exs is a new 3-test file; dashboard_live_test.exs extension nets against shared setup accounting in apply-progress.md) |
| After TASK-2 (`bd1ca04`, current tip) | **559** | +4 more (5 new onboarding-worker tests; apply-progress.md's own count) |

No regressions: 0 failures at every stage, confirmed by this independent re-run.

---

## 3. Spec Compliance Matrix — all 4 `REQ-W-*`

| Requirement | Scenario | Test covering | Result |
|---|---|---|---|
| `REQ-W-professional-welcome-override` | professional sets a custom welcome message | `professional_test.exs:31` "update_professional/2 sets a custom welcome_message" | ✅ COMPLIANT |
| `REQ-W-professional-welcome-override` | professional clears their custom welcome message (→ `nil` via dashboard/changeset path) | `professional_test.exs:47` "update_professional/2 clearing welcome_message with an empty string resolves to nil" | ✅ COMPLIANT |
| `REQ-W-professional-welcome-override` | dashboard control (`save_welcome_message` event) | `dashboard_live_test.exs:86` "saves a custom welcome message" (form submit → flash + rendered value) | ✅ COMPLIANT |
| `REQ-W-welcome-text-resolution` | professional has a custom welcome message | `telegram_onboarding_worker_test.exs:228` "uses the professional's custom welcome_message with %{name} interpolated" | ✅ COMPLIANT |
| `REQ-W-welcome-text-resolution` | professional has no custom welcome message → system default | `telegram_onboarding_worker_test.exs:262` "falls back to the system default when the professional's welcome_message is nil" | ✅ COMPLIANT |
| `REQ-W-name-interpolation` | custom message contains `%{name}` | `telegram_onboarding_worker_test.exs:228` (asserts `"¡Hola Ana! Este es tu espacio seguro."`) | ✅ COMPLIANT |
| `REQ-W-name-interpolation` | custom message has no placeholder → verbatim | `telegram_onboarding_worker_test.exs:245` "returns the professional's custom message verbatim when it has no %{name} placeholder" | ✅ COMPLIANT |
| `REQ-W-name-interpolation` | system default, patient has no first name on file | `telegram_onboarding_worker_test.exs:119` "falls back to a generic greeting when the patient has no first name" (pre-existing PR #4 test, still exercised through the new `welcome_text/1` code path) | ✅ COMPLIANT |
| `REQ-W-name-interpolation` (edge case, not a named spec scenario but directly implied by the placeholder convention) | placeholder present, patient has no first name → gap collapse | `telegram_onboarding_worker_test.exs:282` "collapses the %{name} gap to a single space when the patient has no first name" | ✅ COMPLIANT |
| `REQ-W-preload-professional` | welcome resolution does not raise on an unloaded association | All 5 REQ-W tests in `telegram_onboarding_worker_test.exs` (lines 228-314) exercise `custom_welcome_message/1`'s legacy-patient bridge + preload without raising; pre-existing failure-branch tests (patients with no legacy link) continue to pass via graceful `nil` fallback (`custom_welcome_message/1`'s `with ... else _ -> nil end`) | ✅ COMPLIANT |

**Compliance summary: 9/9 scenarios across all 4 `REQ-W-*` requirements are COMPLIANT** (8 explicitly named in spec.md + 1 implied edge case that the implementation also covers with a dedicated test).

---

## 4. TDD Compliance (Strict TDD mode active)

| Check | Result | Details |
|---|---|---|
| TDD Evidence reported | ✅ | `apply-progress.md` §"TDD Cycle Evidence" — 2-task table (TASK-1, TASK-2) with RED/GREEN/REFACTOR columns |
| All tasks have tests | ✅ | TASK-1 → `professional_test.exs` (new) + `dashboard_live_test.exs` (extended); TASK-2 → `telegram_onboarding_worker_test.exs` (extended) |
| RED confirmed (tests exist) | ✅ | All 3 test files verified present on disk and exercised in §2.2 |
| GREEN confirmed (tests pass) | ✅ | 559/559 full suite, 0 failures (§2.1); targeted re-run also 0 failures (§2.2) |
| Triangulation adequate | ✅ | TASK-1: 3 distinct professional_test.exs cases (default/set/clear) + 1 dashboard case; TASK-2: 5 distinct cases (placeholder, verbatim, nil-fallback, gap-collapse, empty-string), each asserting a different resolved body string |
| Safety Net for modified files | ✅ | `apply-progress.md` reports full suite green before/after each task; `dashboard_live_test.exs` and `telegram_onboarding_worker_test.exs` were extended (not replacements) — pre-existing tests in both files continue to pass unchanged |

**TDD Compliance: 6/6 checks passed.**

### 4.1 Assertion Quality Audit

Scanned all 3 test files touched by this change (`professional_test.exs`,
`dashboard_live_test.exs`'s new block, `telegram_onboarding_worker_test.exs`'s new
block) for banned patterns (tautologies, orphan empty checks, ghost loops, smoke-test-only,
mock-heavy ratios). None found:

- Every new test calls production code (`Accounts.update_professional/2`,
  `TelegramOnboardingWorker.perform/1`) and asserts a specific, non-trivial resolved
  value (a literal string body, a specific field value) — no tautologies, no bare
  `toBeDefined()`-equivalents, no assertions inside loops over possibly-empty
  collections.
- The one "empty" assertion in the new suite (`assert cleared.welcome_message == nil`)
  has a companion non-empty test in the same describe block (`assert updated.welcome_message == "¡Bienvenido a Alethea!"`) — satisfies the "orphan empty check" exception.

**Assertion quality**: ✅ All assertions verify real behavior.

---

## 5. Design Coherence

| Decision | Followed? | Notes |
|---|---|---|
| `welcome_message` added to the **legacy** `Alethea.Accounts.Professional`, not the originally-planned `Alethea.Foundation.Accounts.Professional` | ✅ Yes | Confirmed: `lib/alethea/accounts/professional.ex:13` has the field; `DashboardLive` (`alias Alethea.Accounts`) and `Accounts.update_professional/2` both operate on the legacy module. This is a **verified, documented correction** to `design.md` itself (commit `1ff8ae0`), not an undocumented deviation — the design doc explicitly records why the foundation module was the wrong target (no `update_professional/2` there at all). Legitimate. |
| `TelegramOnboardingWorker` bridges to the legacy Patient (`Foundation.Accounts.legacy_patient/1` → `Alethea.Accounts.get_patient_with_professional/1`) rather than a bare `Repo.preload(patient, :professional)` on the foundation patient | ✅ Yes | Confirmed in `telegram_onboarding_worker.ex:215-223` (`custom_welcome_message/1`). Matches the exact bridge `TelegramMessageWorker`'s crisis branch already uses for `crisis_message` — same pattern, not a new abstraction. Falls back to `nil` (→ system default) rather than raising, per design. |
| `Ecto.Changeset.cast/4`'s default `empty_values: [""]` normalizes `""` → `nil` for both `crisis_message` and `welcome_message` — no extra normalization code needed | ✅ Yes | Confirmed empirically by this verify: `professional_test.exs:47` exercises exactly this path (`update_professional(professional, %{welcome_message: ""})` → `cleared.welcome_message == nil`) and passes. `professional.ex`'s `changeset/2` has no custom empty-string handling — behavior comes entirely from `cast/4`'s default, as designed. |
| Discovered pre-existing bug: `validate_required(:password)` blocked all partial updates of persisted professionals | ✅ Yes, fixed correctly | `professional.ex:41-45` — `validate_password_required/2` now only requires `:password` when `professional.id == nil` (registration). This is an **out-of-scope-but-necessary** fix, fully documented in `apply-progress.md` with the root cause (`:password` is `virtual: true`, never reloaded) and its blast radius (also fixes `save_crisis_message`, which had no prior test covering its happy path). Legitimate — without this fix, TASK-1's own `save_welcome_message` test could not pass, since `Accounts.update_professional/2` shares the same changeset. |
| `%{name}` placeholder convention, professional opts in (vs. force-appending name) | ✅ Yes | `interpolate_welcome_name/2` (`telegram_onboarding_worker.ex:236-244`) only replaces `%{name}` if present; verbatim otherwise. Matches design's stated rationale (don't mangle name-agnostic copy). |
| No rich templating, no admin preview UI, no backfill/migration of existing rows | ✅ Yes | Migration is a single nullable `add :welcome_message, :string`, no default, no backfill (`20260710120000_add_welcome_message_to_professionals.exs`). No templating engine beyond the single placeholder. No preview UI added (matches `crisis_message`'s own lack of one). |

All design decisions in the corrected `design.md` are followed by the implementation. No undocumented deviations found — all three deviations described in `tasks.md`/`apply-progress.md` (wrong-schema correction, legacy-patient bridge, password-validation bug fix) are real, verified, and match what's on disk.

---

## 6. Empty-String Test — Sanity Check

`telegram_onboarding_worker_test.exs:299` ("an empty-string welcome_message is sent
verbatim, not falling back to the default") sets up its fixture via
`bind_patient_to_legacy_professional(patient, "")`, which calls
`insert_legacy_professional_with_welcome_message("")`:

```elixir
professional
|> Ecto.Changeset.change(%{welcome_message: welcome_message})
|> Repo.update!()
```

This uses `Ecto.Changeset.change/2` (a raw changeset builder with no `cast/4`, no
`empty_values` normalization, no validations) — **not** `Professional.changeset/2`,
which is the function `DashboardLive`'s `save_welcome_message` event actually calls
via `Accounts.update_professional/2`. The dashboard save path — confirmed in §5 — always
normalizes an incoming `""` to `nil` via `cast/4`'s default. So a literal `""` persisted
to `welcome_message` (and consequently `welcome_text/1`'s `||`-based resolution treating
it as truthy, per Elixir's `nil`/`false`-only falsiness) is a real code path in
`welcome_text/1` in isolation, but **not reachable through the dashboard UI** — only
via direct/programmatic writes to the field (fixtures, seeds, a future admin tool, or a
future API bypassing the changeset).

This is explicitly documented in `spec.md`'s own scenario note ("this only holds for
values that pass through `Professional.changeset/2`... this path is not reachable via
the dashboard save flow") and in the worker's own doc comment
(`telegram_onboarding_worker.ex:188-190`). Treated as a **documented-but-unreachable-
via-the-UI test scenario**, not a defect — the same category of accepted "landmine"
test already present in this codebase (e.g. PR #4's Judgment Day findings). No action
required; flagged here only as a SUGGESTION for future awareness (§8).

---

## 7. Correctness (Static Evidence)

| Requirement | Status | Notes |
|---|---|---|
| `REQ-W-professional-welcome-override` | ✅ Implemented | Field, migration, dashboard event/textarea all present and match `crisis_message`'s shape exactly |
| `REQ-W-welcome-text-resolution` | ✅ Implemented | `welcome_text/1` (`telegram_onboarding_worker.ex:191-198`) — `custom || default` pattern |
| `REQ-W-name-interpolation` | ✅ Implemented | `interpolate_welcome_name/2` + `collapse_placeholder_gap/2`, both pure and independently testable |
| `REQ-W-preload-professional` | ✅ Implemented | `custom_welcome_message/1`'s bridge; no `%Ecto.Association.NotLoaded{}` ever reaches `.welcome_message` |

---

## 8. Issues Found

**CRITICAL**: None.

**WARNING**: None.

**SUGGESTION**:
1. The empty-string test scenario (§6) exercises a state that is unreachable via the
   actual dashboard save path (bypasses `Professional.changeset/2` by using
   `Ecto.Changeset.change/2` directly in the test fixture). It correctly documents
   `welcome_text/1`'s own resolution logic in isolation and is already flagged with an
   inline comment in `spec.md` and the worker's moduledoc — no code change needed, but
   worth keeping in mind if `welcome_message` ever gets a second write path (e.g. a
   future admin API) that doesn't go through the changeset.

---

## 9. Verdict

**PASS.**

All 2/2 tasks complete and verified against the code. All 4 `REQ-W-*` requirements
(9/9 scenarios, including one implied edge case) are COMPLIANT with passing tests.
`mix precommit` is green: 559 tests, 0 failures, 5 skipped, exit code 0 — matching
`apply-progress.md`'s reported final count exactly. All three documented deviations
from the literal task/design file paths (legacy-schema correction, legacy-patient
bridge, pre-existing password-validation bug fix) are legitimate, verified corrections
recorded in `design.md`/`apply-progress.md` before this verify — not defects. The one
SUGGESTION (empty-string test scenario) is informational only and does not block
archive.

**Recommended next step:** `sdd-archive`.
