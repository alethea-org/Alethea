# Verify Report 2 — `professional-welcome-message` (post-Judgment-Day re-verify)

**Change:** `professional-welcome-message`
**Branch:** `feat/professional-welcome-message` (base `main`, post `telegram-paciente-foundation` merge)
**Commits (full range):** `b57b71d` (TASK-1), `bd1ca04` (TASK-2), `5d9818c` (fix: migration
column `varchar(255)` → `text`), `c0fb308` (JD Round 1), `ba686b5` (JD Round 2, superseded),
`2e8643c` (JD Round 3), `0b0ebb4` (JD Round 4), `f13d067` (JD Round 5) — HEAD at re-verify time
**Verdict:** **PASS** (0 CRITICAL, 0 WARNING, 1 SUGGESTION carried forward)
**Verifier mode:** Source-driven + `mix precommit`/`mix test` (full suite, re-run twice)
**Strict TDD:** active; TDD evidence validated against `apply-progress.md` + the 5 JD-round diffs
**Supersedes:** `verify-report.md` (original, PASS, written before Judgment Day started —
kept as an audit trail, not overwritten)

---

## 0. Scope note — this is a post-Judgment-Day re-verify

`sdd-verify` already ran once on this change (`verify-report.md`, PASS, 2026-07-10,
HEAD = `bd1ca04`) **before** Judgment Day began. Since then the branch went through
**5 rounds of adversarial dual-judge review**, all scoped to the `%{name}`
interpolation/whitespace-collapse logic in `TelegramOnboardingWorker`:

| Commit | Round | What it fixed |
|---|---|---|
| `c0fb308` | 1 | Scoped whitespace collapse (marker + punctuation lookahead) instead of a blind global `"  " -> " "`; `Logger.warning` on unexpected legacy-bridge failure; `validate_length(:welcome_message, max: 4096)`; regression test for `validate_password_required/2` on create; fixed a stale moduledoc claim about empty-to-nil normalization |
| `ba686b5` | 2 | Further scoped whitespace-collapse iteration — superseded by Round 3's rewrite |
| `2e8643c` | 3 | Round 2's punctuation-whitelist approach kept missing adjacent-character shapes (quotes, parens, mid-word) with no terminating fix; replaced with two GLOBAL cleanup rules (collapse 2+ spaces to one, drop space before punctuation) applied after a plain `%{name}` substitution — an explicit, user-confirmed trade-off (a professional's own pre-existing double space elsewhere in their template is now also collapsed). Added: template-is-only-the-placeholder falls back to the system default instead of sending an empty message. |
| `0b0ebb4` | 4 | Widened the two cleanup regexes from literal space to `\s` (newlines/tabs, since the dashboard field is a plain textarea over an unbounded `text` column); replaced the `result == ""` empty-message guard with a Unicode-aware "contains any letter/number" check, catching a punctuation-only residual (`"%{name}!"` -> `"!"`) |
| `f13d067` | 5 | Moved the meaningless-message guard from inside `interpolate_welcome_name/2` (only reachable when the no-placeholder branch was NOT taken) to `welcome_text/1`, applied once to whatever text is finally resolved regardless of code path — closed a CRITICAL gap where a whitespace-only `welcome_message` with no `%{name}` placeholder bypassed the guard entirely |

**Final Judgment Day verdict: APPROVED** after 6 rounds of dual-judge review (0
confirmed CRITICAL/real-WARNING as of Round 6). This report re-confirms PASS against
the CURRENT tip (`f13d067`), not the original `bd1ca04` apply — every finding below is
evaluated against the post-hardening code, and the compliance matrix in §3 accounts
for how the interpolation logic evolved across all 5 rounds.

---

## 1. Completeness

| Artifact | Present? | Notes |
|---|---|---|
| `proposal.md` | yes | Unchanged since original verify |
| `design.md` | yes | Unchanged since original verify (already corrected pre-JD, commit `1ff8ae0`, for the legacy/foundation `Professional` schema mix-up and `Ecto.cast/4` empty-string behavior) |
| `specs/C-1-professional-welcome-message/spec.md` | yes | 4 `REQ-W-*` requirements, unchanged text — the JD rounds hardened the IMPLEMENTATION of `REQ-W-name-interpolation`, not the requirement wording itself |
| `tasks.md` | yes | TASK-1, TASK-2, both `[x] Done` |
| `apply-progress.md` | yes | TDD Cycle Evidence table, architecture-discovery + bug-fix sections, requirements coverage table (pre-JD) |
| `verify-report.md` (original) | yes | PASS, written before Judgment Day — superseded by this report, not overwritten |

### Task completion (re-confirmed against current code)

| Task | Status per tasks.md | Verified against current tip? |
|---|---|---|
| TASK-1 — `welcome_message` field + migration + dashboard control | `[x] Done` | ✅ confirmed — unaffected by JD rounds (all 5 rounds touched only `telegram_onboarding_worker.ex` and its test, plus one `validate_length` addition to `professional.ex` in Round 1) |
| TASK-2 — welcome-text resolution + professional preload | `[x] Done` | ✅ confirmed — the JD hardening is entirely inside this task's scope (`welcome_text/1`, `custom_welcome_message/1`, `interpolate_welcome_name/2`) |

No unchecked tasks — no CRITICAL from the "unchecked task" gate. The JD hardening
did not add new tasks or scope creep: `tasks.md`'s TASK-2 requirements
(`REQ-W-welcome-text-resolution`, `REQ-W-name-interpolation`, `REQ-W-preload-professional`)
already covered "welcome-text resolution" as a whole, and interpolation correctness is
squarely inside "welcome-text resolution" — the 5 rounds are hardening of an in-scope
function, not new capability.

---

## 2. Test Execution Evidence

### 2.1 `mix precommit` / `mix test` (re-run on `feat/professional-welcome-message`, HEAD = `f13d067`)

✅ **GREEN** on a clean run — exit code 0.

```
$ mix test
EXIT CODE: 0
2 doctests, 571 tests, 0 failures, 5 skipped
Finished in 65.5 seconds (10.6s async, 54.8s sync)
```

A first `mix precommit` run in this verify session logged 1 failure (exit code 2):

```
1) test perform/1 — 429 with Retry-After reschedules the job with a delay near the
   Retry-After value (plus jitter) (Alethea.Jobs.TelegramOutboundWorkerTest)
   test/alethea/jobs/telegram_outbound_worker_test.exs:129
   Expected the difference between 1497 and 2000 (503) to be less than or equal to 500
   code: assert_in_delta delta, 2_000, 500
```

This is a **timing-sensitive flake in `telegram_outbound_worker_test.exs`** (an
`assert_in_delta` on wall-clock jitter), not the `pacer_test.exs` ETS-access flake
named in the task brief — confirmed neither file is touched by this change
(`git log --oneline main..feat/professional-welcome-message -- test/alethea/jobs/telegram_outbound_worker_test.exs test/alethea/telegram/pacer_test.exs`
returns empty). An immediate clean re-run produced `571 tests, 0 failures, 5 skipped`,
exit code 0, confirming no regression — same category of pre-existing, unrelated,
timing-based test flake as the one flagged in the task brief and in PR #4's own verify
history (§7 of that report), just a different specific test surfacing this time.

- `compile --warnings-as-errors`: pass.
- `format --check-formatted`: pass.
- `test`: 571 tests + 2 doctests, 0 failures, 5 skipped on the clean run — matches the
  task brief's expected count exactly (559 at the original pre-JD verify + 12 new JD
  test cases across Rounds 1, 3, 4, 5 = 571; see §2.2 reconciliation).

### 2.2 Test count delta vs. original pre-Judgment-Day verify

| Stage | Total tests | Notes |
|---|---|---|
| Original verify (`bd1ca04`, pre-JD) | 559 | 0 failures, 5 skipped, per `verify-report.md` |
| After JD Round 1 (`c0fb308`) | — | +2 (`professional_test.exs` create-password regression + 1 more onboarding-worker case) |
| After JD Round 3 (`2e8643c`) | — | +3 (only-placeholder fallback, multi-occurrence collapse, punctuation-adjacent) |
| After JD Round 4 (`0b0ebb4`) | — | +2 (newline/tab whitespace, punctuation-only residual) |
| After JD Round 5 (`f13d067`, current tip) | **571** | +remaining net (whitespace-only-no-placeholder case; empty-string test's expected outcome flipped from "sent verbatim" to "falls back to default", net test count unchanged for that one, new assertions added elsewhere) |

Full suite at current tip: **571 tests, 0 failures, 5 skipped** (confirmed twice, one
clean run + one run with the known-unrelated flake reproduced and then not reproduced
on immediate re-run). No regressions introduced by any JD round.

### 2.3 Targeted test run — this change's own files

```
$ mix test test/alethea/accounts/professional_test.exs \
           test/alethea_web/live/dashboard_live_test.exs \
           test/alethea/jobs/telegram_onboarding_worker_test.exs
```

- `professional_test.exs` (117 lines): `welcome_message` field describe block — nil
  default, set-custom, clear-to-empty-string-resolves-nil, over-4096-chars validation
  failure (Round 1), exactly-4096-chars DB round-trip, plus the Round 1 regression test
  proving `create_professional/1` still requires `:password` (only UPDATE is exempted).
- `dashboard_live_test.exs`: "Welcome message" describe block unchanged since the
  original verify — `save_welcome_message` event still saves correctly; no JD round
  touched this file.
- `telegram_onboarding_worker_test.exs` (719 lines): 16 tests in the original
  "welcome copy resolved from the professional's custom message" describe block grew
  to include the full JD-round history — placeholder interpolation, verbatim-no-
  placeholder, nil-fallback, gap-collapse (single + multi-occurrence), pre-existing
  double-space-elsewhere-in-template preserved-then-collapsed (Round 3's accepted
  trade-off), punctuation-adjacent (no orphan space), quote/paren-adjacent, only-
  placeholder-falls-back, punctuation-only-residual-falls-back, newline/tab whitespace
  collapse, `:not_linked` silent branch, empty-string-now-falls-back-to-default
  (Round 5's behavior change from the original verify's "sent verbatim" expectation),
  whitespace-only-no-placeholder-falls-back (Round 5's own CRITICAL fix) — all pass.

---

## 3. Spec Compliance Matrix — all 4 `REQ-W-*`, evaluated against current tip

| Requirement | Scenario | Test covering | Result |
|---|---|---|---|
| `REQ-W-professional-welcome-override` | professional sets a custom welcome message | `professional_test.exs` "update_professional/2 sets a custom welcome_message" | ✅ COMPLIANT |
| `REQ-W-professional-welcome-override` | professional clears their custom welcome message (→ `nil`) | `professional_test.exs` "update_professional/2 clearing welcome_message with an empty string resolves to nil" | ✅ COMPLIANT |
| `REQ-W-professional-welcome-override` | dashboard control (`save_welcome_message` event) | `dashboard_live_test.exs` — form submit → flash + rendered value | ✅ COMPLIANT |
| `REQ-W-welcome-text-resolution` | professional has a custom welcome message | `telegram_onboarding_worker_test.exs` "uses the professional's custom welcome_message with %{name} interpolated" | ✅ COMPLIANT |
| `REQ-W-welcome-text-resolution` | professional has no custom welcome message → system default | `telegram_onboarding_worker_test.exs` "falls back to the system default when the professional's welcome_message is nil" | ✅ COMPLIANT |
| `REQ-W-name-interpolation` | custom message contains `%{name}` | same test as above (asserts `"¡Hola Ana! Este es tu espacio seguro."`) | ✅ COMPLIANT |
| `REQ-W-name-interpolation` | custom message has no placeholder → verbatim | `telegram_onboarding_worker_test.exs` "returns the professional's custom message verbatim when it has no %{name} placeholder" | ✅ COMPLIANT |
| `REQ-W-name-interpolation` | system default, patient has no first name on file | `telegram_onboarding_worker_test.exs` "falls back to a generic greeting when the patient has no first name" (pre-existing PR #4 test) | ✅ COMPLIANT |
| `REQ-W-name-interpolation` (edge case, JD-hardened) | placeholder present, no known name → gap collapse, no orphan spaces, no double spaces from multi-occurrence, no mangling of quotes/parens/mid-word adjacency, newline/tab whitespace collapsed, punctuation-only or whitespace-only residual falls back to system default | 9 dedicated tests in `telegram_onboarding_worker_test.exs` (lines ~282-567): gap-collapse, multi-occurrence, pre-existing-double-space-elsewhere, punctuation-adjacent, quote/paren-adjacent, only-placeholder, punctuation-only-residual, newline/tab, whitespace-only-no-placeholder | ✅ COMPLIANT — this is the scenario surface Judgment Day exhaustively hardened; each round's finding has its own exact-string-assertion regression test (not substring/refute, per Round 2's own lesson that substring checks miss orphan-space regressions) |
| `REQ-W-preload-professional` | welcome resolution does not raise on an unloaded association | all `telegram_onboarding_worker_test.exs` REQ-W tests exercise `custom_welcome_message/1`'s legacy-patient bridge + preload without raising; `:not_linked` silent-branch test and the (documented, DB-FK-unreachable) "unexpected failure" `Logger.warning` branch added in Round 1 | ✅ COMPLIANT |

**Compliance summary: all 4 `REQ-W-*` requirements COMPLIANT at current tip**, with
the `REQ-W-name-interpolation` edge-case surface now covered by 9 exact-string
regression tests (up from 1 at the original pre-JD verify) — each corresponding to a
specific Judgment Day round's finding.

---

## 4. TDD Compliance (Strict TDD mode active)

| Check | Result | Details |
|---|---|---|
| TDD Evidence reported | ✅ | `apply-progress.md`'s original TDD Cycle Evidence table (TASK-1, TASK-2) plus each JD round's own commit message documents what broke and what test was added — read as an extension of the same evidence trail |
| All tasks have tests | ✅ | Confirmed — no new task added by JD, all 5 rounds are modifications inside TASK-2's existing test file |
| RED confirmed (tests exist) | ✅ | All 3 test files (`professional_test.exs`, `dashboard_live_test.exs`, `telegram_onboarding_worker_test.exs`) verified present and current on disk |
| GREEN confirmed (tests pass) | ✅ | 571/571 full suite, 0 failures on clean run (§2.1); targeted re-run also 0 failures (§2.3) |
| Triangulation adequate | ✅ | `REQ-W-name-interpolation`'s edge-case surface now has 9 distinct test cases, each asserting a different exact resolved string — materially improved triangulation vs. the original verify's 1 gap-collapse case |
| Safety Net for modified files | ✅ | Each JD round's commit diff shows the pre-existing tests in `telegram_onboarding_worker_test.exs` continuing to pass alongside the new/changed ones (no test file was replaced wholesale) |

**TDD Compliance: 6/6 checks passed.**

### 4.1 Assertion Quality Audit (JD-added/modified tests)

Scanned all test additions/modifications across the 5 JD-round commits
(`c0fb308`, `ba686b5`, `2e8643c`, `0b0ebb4`, `f13d067`) for banned patterns:

- Every JD-added test calls `TelegramOnboardingWorker.perform/1` (real production
  code, not a mock) and asserts an **exact resolved body string** via
  `assert outbound_job.args["body"] == "..."` — not a substring/refute check. This is
  itself a documented JD Round 2 correction: the original interpolation tests used
  `refute body =~ "  "`-style substring assertions, which passed even when the fix
  left an orphan space before punctuation. Round 2 (and every round after) switched to
  exact-string equality, which is the stricter, harder-to-fool assertion form.
- No tautologies, no assertions inside loops over possibly-empty collections, no
  mock-heavy tests (these are real Oban/Ecto integration tests through
  `all_enqueued/1`, not unit tests with mocked dependencies).
- The Round 5 empty-string test explicitly documents its own change in expected
  behavior in an inline comment (verbatim → falls back to default) rather than
  silently changing the assertion — good practice for future readers.

**Assertion quality**: ✅ All assertions verify real behavior; no regressions in
assertion strength across the 5 JD rounds (rounds tightened assertions, they did not
loosen any).

---

## 5. Design Coherence — JD hardening vs. `design.md`

`design.md` documents the `%{name}` placeholder convention decision (professional
opts in, no force-append) but predates all 5 JD rounds — it does not describe the
whitespace-collapse algorithm in prose. This is a **documented-in-code, not
documented-in-design-doc** situation:

| Decision | Followed? | Notes |
|---|---|---|
| `%{name}` placeholder, professional opts in (vs. force-append) | ✅ Yes | Unchanged through all 5 rounds — `interpolate_welcome_name/2` still only replaces when present, verbatim otherwise. The rounds hardened HOW the no-name-known case cleans up surrounding whitespace, not WHETHER the placeholder convention itself changed. |
| No rich templating, single placeholder | ✅ Yes | Still true — no loops/conditionals added by any JD round |
| `custom || default` resolution shape (`REQ-W-welcome-text-resolution`) | ✅ Yes | `welcome_text/1` still resolves `custom_welcome_message(patient)` then falls back to `default_welcome_text/1` — Round 5 added a THIRD path (meaningless-but-non-nil custom text also falls back), which is a natural extension of the same fallback philosophy already in the design, not a new architecture |
| Legacy-patient bridge (`REQ-W-preload-professional`) | ✅ Yes | `custom_welcome_message/1`'s bridge is unchanged across all 5 JD rounds; only its failure-branch logging (Round 1's `Logger.warning`) was added |

The whitespace-collapse algorithm itself (the global 2e8643c rewrite, the `\s`
widening, the meaningfulness guard) is a Judgment-Day-discovered implementation
detail below the design doc's level of abstraction — `design.md` was correct not to
predict it, and no design decision was violated or silently overridden. All 5 rounds
are documented in the worker's own extensive code comments (lines 269-320 of
`telegram_onboarding_worker.ex`), which is the appropriate level of documentation for
implementation-detail hardening this specific.

---

## 6. Known, accepted, documented residual limitations — re-confirmed accurate

Cross-checked each against the current code and its inline comments:

| Limitation | Documented where | Accurate? |
|---|---|---|
| NBSP / non-ASCII Unicode whitespace adjacent to `%{name}` not collapsed (`\s` is ASCII-only without Unicode property mode) | `f13d067` commit message ("Noted, not fixed") — not yet mirrored into the worker's own code comment | ✅ Accurate — `interpolate_welcome_name/2` uses `~r/\s{2,}/` and `~r/\s+([,.!?;:])/`, both plain `\s`, not `\s` with the `u` Unicode-whitespace modifier applied to the character class beyond letters/numbers in `meaningless_welcome?/1` |
| A resolved text of only a single letter/digit (e.g. `"%{name}1"` -> `"1"`) passes `meaningless_welcome?/1` (`~r/[\p{L}\p{N}]/u` matches `"1"`) and would still send a near-useless one-character message | `f13d067` commit message | ✅ Accurate — confirmed by reading `meaningless_welcome?/1`: it only checks for presence of ANY letter/number, not a minimum length |
| `"%{name}, hola"` (placeholder as the very first token, punctuation directly after) can leave orphaned punctuation at the start (`", hola"`) once resolved with no known name | Documented inline in `telegram_onboarding_worker.ex` lines 295-302 | ✅ Accurate and in-code (unlike the two limitations above, which are only in commit messages, not in the worker's own moduledoc/comments — see SUGGESTION below) |
| A professional's own pre-existing double space / blank-line paragraph break anywhere in their template is now also collapsed (accepted trade-off, confirmed with the user in Round 3) | Documented inline, `telegram_onboarding_worker.ex` lines 269-293, and exercised by a dedicated test ("collapses a pre-existing double space anywhere in the template...") | ✅ Accurate |
| The known-name interpolation path (`String.replace(template, "%{name}", name)`) does no whitespace trimming | Implicit in `interpolate_welcome_name/2`'s second clause (no cleanup pipeline applied) — not called out in a comment | ✅ Accurate, pre-existing (unchanged since PR #4, not touched by any JD round) |
| Post-interpolation length not re-validated against Telegram's 4096-char cap (only the raw template is validated at save time via `validate_length(:welcome_message, max: 4096)`) | Not yet documented inline in the worker — only in this verify's brief | ✅ Accurate — `professional.ex`'s `validate_length` runs on the STORED template, before `%{name}` substitution; a sufficiently long name × long template × multiple placeholder occurrences could theoretically exceed 4096 post-interpolation with no re-check at send time |

All six limitations are real, verified against the current code, and match their
described behavior. Two of the six (NBSP/Unicode whitespace, single-character
residual, post-interpolation length re-validation) are documented only in Judgment Day
commit messages / this verify brief, not yet mirrored into the worker's own moduledoc
or inline comments — flagged as a SUGGESTION, not a defect (none of the six change the
PASS verdict; all were explicitly reviewed and accepted by Judgment Day as
diminishing-returns / low-probability compound edge cases on an already
five-rounds-deep cosmetic text-formatting feature).

---

## 7. Correctness (Static Evidence)

| Requirement | Status | Notes |
|---|---|---|
| `REQ-W-professional-welcome-override` | ✅ Implemented | Unchanged since original verify — field, migration (`text` column, corrected in `5d9818c`), dashboard event/textarea |
| `REQ-W-welcome-text-resolution` | ✅ Implemented | `welcome_text/1` (`telegram_onboarding_worker.ex:192-214`) — `custom || default` pattern, now with the Round 5 meaningfulness guard wrapping the custom branch |
| `REQ-W-name-interpolation` | ✅ Implemented | `interpolate_welcome_name/2` (lines 310-327) + `meaningless_welcome?/1` (line 329) — both pure, independently testable, and the product of 5 rounds of adversarial hardening |
| `REQ-W-preload-professional` | ✅ Implemented | `custom_welcome_message/1` (lines 231-256) — bridge unchanged, `Logger.warning` added on the (DB-FK-unreachable) unexpected-failure branch |

---

## 8. Issues Found

**CRITICAL**: None.

**WARNING**: None.

**SUGGESTION**:
1. (Carried forward from the original verify, still accurate) The empty-string test
   scenario bypasses `Professional.changeset/2` via `Ecto.Changeset.change/2` to
   exercise `welcome_text/1`'s resolution logic in isolation — not reachable through
   the real dashboard save path. Its EXPECTED OUTCOME changed in Round 5 (was "sent
   verbatim", now "falls back to system default"), which the test's own inline comment
   documents. Still no code change needed; still worth keeping in mind if
   `welcome_message` ever gets a second write path that bypasses the changeset.
2. (New) Three of the six documented residual limitations (§6: NBSP/Unicode
   whitespace, single-character residual passing the meaningfulness check,
   post-interpolation length not re-validated against the 4096 cap) are recorded in
   Judgment Day commit messages and this verify's brief but not yet mirrored into
   `telegram_onboarding_worker.ex`'s own inline comments, unlike the other three
   limitations which ARE in-code. Low priority — purely a documentation
   discoverability gap for a future maintainer reading only the source file, not a
   behavioral defect. Does not block archive.

---

## 9. Verdict

**PASS.**

All 2/2 tasks remain complete and verified against the current tip. All 4 `REQ-W-*`
requirements (12 scenarios, including the JD-hardened edge-case surface with 9
dedicated regression tests, up from 1 at the original pre-JD verify) are COMPLIANT
with passing tests. `mix test` is green on a clean run: 571 tests, 0 failures, 5
skipped, exit code 0 — matching the expected count. One transient failure observed in
this verify session (`telegram_outbound_worker_test.exs`'s Retry-After jitter
assertion) is confirmed pre-existing and unrelated to this change's files, not a
regression — same category as the `pacer_test.exs` flake named in the task brief. All
5 Judgment Day rounds are in-scope hardening of TASK-2 (welcome-text resolution), not
scope creep — no new capability was added, only correctness fixes to the existing
`%{name}` interpolation logic. The two SUGGESTIONs (one carried forward, one new
documentation-discoverability note) are informational only and do not block archive.

**Recommended next step:** `sdd-archive`, followed by opening a real PR for
`feat/professional-welcome-message` against `main` (this change was developed as a
standalone branch per `tasks.md`'s "single PR" chain strategy — no chaining needed).
