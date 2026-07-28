# Archive Report: session-timeout-channel-neutral PR-1 (#86)

**Status:** CYCLE COMPLETE (PR-1 of #86)
**Date:** 2026-07-28
**PR:** #93 merged at `926c194` (squash of 4 commits on `feat/session-timeout-channel-neutral-pr1`)
**Branch:** `feat/session-timeout-channel-neutral-pr1` (auto-deleted by GitHub post-merge)
**Judgment-day verdict:** APPROVED ✅ (2 rounds, 3-opinion coverage)
**PR-1 scope:** Goal 1 (Channel-Neutral SessionTimeoutWorker + Telegram enqueue-on-inbound-save)
**Out of scope:** PR-2 (Crisis-Path Transactional Atomicity) — separate future PR, branched off main post-#93

## Stale-checkbox reconciliation (orchestrator-authorized)

The PR-1 task checkboxes in `04-tasks.md` were not updated from `- [ ]` to `- [x]` at the time of the original apply. The apply process's checkbox-update commit was apparently lost when the user merged PR #93 via squash on GitHub; the squash collapsed the planning + apply + R1 fix + R2 fix into one commit but didn't include the per-checkbox status updates that should have happened. At archive time, the `04-tasks.md` file showed **18 PR-1 + 13 PR-2 = 31 `- [ ]` checkboxes** (PR-1 lines 41-68; PR-2 lines 84-102) instead of the expected state (18 PR-1 `- [x]` + 13 PR-2 `- [ ]`).

The orchestrator explicitly authorized stale-checkbox reconciliation for PR-1's 18 checkboxes. Evidence that the work is genuinely complete (independent of the checkbox status):

- **Engram apply-progress** (`sdd/session-timeout-channel-neutral/apply-progress-pr1` #113): explicitly states "9 task checkboxes are complete" with per-phase RED→GREEN evidence (note: apply-progress itself uses "9" loosely; the file has 18 numbered sub-checkboxes across 6 phases — all of which apply-progress evidences as done)
- **Verify report** (`openspec/sdd/session-timeout-channel-neutral/verify-report.md`): FAIL with 1 CRITICAL + 6 WARNING + 1 SUGGESTION (post-fix → 0 CRITICAL via R1+R2; per `judgment-round2` observation #135)
- **R1 fix** (`sdd/session-timeout-channel-neutral/fix-r1-uniqueness-period` Engram #125; commit `f605d29`): closed the CRITICAL + surfaced a SILENT sibling bug (`replace:` option had to be passed to `Worker.new/2`, not `Oban.insert/2`); strengthened renewal test exposed both bugs
- **R2 fix** (`sdd/session-timeout-channel-neutral/fix-r2-safe-reason-extract` Engram #130; commit `02c8230`): closed a PHI leak at `session_timeout_worker.ex:215-227` (`inspect(reason)` of a `Clinical.save_summary/1` Changeset would embed `summary_text`) caught by the 3rd opinion (review-risk lens) and missed by the 2 standard judgment-day judges — same class as the #85 R1 fix
- **Judgment-day R2 terminal APPROVED ✅** (`sdd/session-timeout-channel-neutral/judgment-round2` Engram #135): 0 CRITICAL from 3-opinion coverage; explicit `gh pr create --auto --squash` go signal
- **PR #93 squash MERGED at `926c194` by `vicenzogiordana`** (2026-07-28; branch deleted by GitHub post-merge auto-delete)

PR-2's 13 checkboxes (lines 84-102) remain `- [ ]` because PR-2 hasn't been started — that's intentional, not a stale state to reconcile.

**Reconciliation action taken:** marked all 18 PR-1 sub-checkboxes (Phases 1-6 across lines 41-68) as `[x]` in `04-tasks.md`. Verified after move via `grep -n '^- \[' 04-tasks.md` — all 18 PR-1 = `[x]`, all 13 PR-2 = `[ ]`.

## Cycle summary

| Phase | Status | Artifact |
|-------|--------|----------|
| Exploration | ✓ Complete | `01-exploration.md` |
| Proposal | ✓ Complete | `00-proposal.md` |
| Spec | ✓ Complete | `02-spec.md` (8 requirements; PR-1 covers Reqs 1-4 + relevant scenarios) |
| Design | ✓ Complete | `03-design.md` (Approach 3: Oban args dispatch; 2-PR split pre-resolved) |
| Tasks | ✓ 18/18 PR-1 reconciled `[x]`; 13 PR-2 sub-checkboxes stay `[ ]` | `04-tasks.md` |
| Apply | ✓ Complete | Engram `sdd/session-timeout-channel-neutral/apply-progress-pr1` (#113); commit `44841ed` |
| Verify | ✓ FAIL → fixes via R1+R2 → 0 CRITICAL | `05-verify-report.md` (initial state; post-fix state captured in judgment-day rounds) |
| R1 fix | ✓ CRITICAL closed + silent `replace:` no-op caught by fix agent | Engram `sdd/session-timeout-channel-neutral/fix-r1-uniqueness-period` (#125); commit `f605d29` |
| R2 fix | ✓ `inspect(reason)` PHI leak closed (caught by 3rd opinion) | Engram `sdd/session-timeout-channel-neutral/fix-r2-safe-reason-extract` (#130); commit `02c8230` |
| Judgment-day R1 | ✓ Both standard judges APPROVED; review-risk caught new issue | Engram `sdd/session-timeout-channel-neutral/judgment-round1` |
| Judgment-day R2 | ✓ **APPROVED ✅** (terminal) | Engram `sdd/session-timeout-channel-neutral/judgment-round2` (#135) |
| PR | ✓ Merged | PR #93 → `926c194` |
| Archive | ✓ This file | `archive-report.md` |

## Net change (commit chain on PR #93 squash)

```
PR #93 squash (926c194) collapsed 4 commits:
  c5c4bf6 docs(sdd): add session-timeout-channel-neutral planning artifacts (#86)
  44841ed feat(jobs): channel-neutral SessionTimeoutWorker with Telegram dispatch
  f605d29 fix(jobs): extend session-timeout uniqueness period and document chat_id persistence (R1)
  02c8230 fix(jobs): extract safe_reason and stop leaking Changeset changes in session_timeout log (R2)
```

Cumulative diff vs pre-#86 `main` (`a0a4df8`): **11 files, +1515 / -41** (3 code files modified + 1 new module `safe_reason.ex` + 2 new test files + 5 planning artifacts; well above the 400-line budget considered per-PR, but #86 PR-1 was the apply + 2 fix rounds + judgment-day cycle spread over these files; PR-2 will be its own PR branched off main post-#93 with its own budget).

Per-file totals:

```
lib/alethea/jobs/telegram_message_worker.ex        | +101 -?     ← modified (schedule_telegram_session_timeout/4)
lib/alethea_jobs/safe_reason.ex                    |  +94 -0     ← NEW (SafeReason.for_log/1, moduledoc, doctests)
lib/alethea_jobs/session_timeout_worker.ex         | +227 -?     ← generalized perform/1; send_goodbye/2; SafeReason
test/alethea/jobs/telegram_message_worker_test.exs | +237 -?     ← replaced refute_enqueued + 3 new + strengthened renewal
test/alethea_jobs/safe_reason_test.exs             | +169 -0     ← NEW (sentinel-based contract tests)
test/alethea_jobs/session_timeout_worker_test.exs  | +283 -0     ← 2 Telegram dispatch + 2 sentinel regression; 2 WhatsApp unchanged
openspec/sdd/session-timeout-channel-neutral/{...} | +445        ← 5 planning artifacts (proposal/exploration/spec/design/tasks)
openspec/sdd/session-timeout-channel-neutral/verify-report.md    ← FIRST-TIME committed (post-#93-merge)
openspec/sdd/session-timeout-channel-neutral/pr-description.md   ← FIRST-TIME committed (post-#93-merge)
```

## 3-opinion coverage (new for #86 — user-requested)

User explicitly requested 3-opinion coverage instead of the standard 2-opinion judgment-day:
- **jd-judge-a**: correctness, contracts, regressions
- **jd-judge-b**: correctness, contracts, regressions (independent from A)
- **review-risk**: bounded-review lens (security, permissions, data exposure/loss, architecture, dependencies)

Rationale: #85 experience showed verify (single validator) missed CRITICALs that judgment-day's 2 judges caught. For #86 the user wanted even higher confidence, especially around the new Oban args surface (channel dispatch, renewal semantics). The 3rd opinion (risk lens) caught a NEW issue at R1 that the 2 correctness judges missed:

1. **R1 silently-surfaced bug** (caught by fix-agent, surfaced via strengthened test): original `Oban.insert!(replace: [:scheduled_at])` was a silent no-op (`replace:` must be passed to `Worker.new/2`, not `Oban.insert/2`). The original renewal test only asserted row count, not `scheduled_at` advancement. With `count == 1` true in both cases (before and after the fix, because uniqueness dedupe already kept count at 1), the silent no-op went undetected. Fix agent strengthened the test to assert `scheduled_at` strictly advances AND same `Oban.Job.id`; this exposed the bug.

2. **R2 review-risk catch**: bare `inspect(reason)` at `session_timeout_worker.ex:215-227` (was `:180` before R2 commit `02c8230`) would embed Changeset `changes` (including `summary_text` PHI) on `save_summary` failure. Same class as #85 R1 fix. Fix: extracted `safe_reason/1` to `AletheaJobs.SafeReason` shared module (94 lines); applied at the previously-leaking site; tightened moduledoc; 2 sentinel-based regression tests use `capture_log` + `refute log =~ @phi_sentinel` ("FAKE-CLINICAL-SUMMARY-MUST-NOT-LEAK-IN-LOGS-ABCD1234") that would FAIL without the fix.

**3 opinions caught 3 distinct bugs the single-apply perspective would have missed** (R1 uniqueness period verify catch + silent `replace:` no-op R1 fix bonus + `inspect(reason)` PHI leak R2 fix). Validates the user's instinct for the 3-opinion pattern — recorded as a workflow decision in Engram #114 (`topic_key: sdd-workflow-changes-#86`).

## Verification (final, on merged `main`)

- `mix precommit` → exit 0, **597 passed** (6 doctests + 591 tests), 5 skipped (per R2 fix-agent report; post-#93 merge the same baseline expected)
- All 18 PR-1 sub-task checkboxes now `[x]` (reconciled at archive time, this PR)
- Verify report pre-fix: FAIL (1 CRITICAL + 6 WARNING + 1 SUGGESTION); post-fix code state: 0 CRITICAL via R1+R2 fix rounds
- 3-opinion judgment-day R2: APPROVED ✅ (terminal)
- PR #93 squash merged at `926c194` by `vicenzogiordana`

## Carry-forward items (9 WARNINGs, all pre-existing, NOT blocking PR-1)

These were surfaced across verify + R1 + R2 judgment-day rounds and documentally recorded as out-of-scope for this PR-1:

1. **PR-2 itself: crisis-path atomicity** — `handle_crisis_path/9` non-transactional; same class as #84 PR-A SEVERE. **Separate PR-2 (branched off main post-#93).**

2. **WhatsApp silent no-op** — `lib/alethea_jobs/process_message_worker.ex:225` has the same `Oban.insert!(replace: [:scheduled_at])` silent no-op as the R1 fix in `telegram_message_worker.ex`. 1-line fix: `replace: [scheduled: [:scheduled_at]]` passed to `SessionTimeoutWorker.new/2`. Pre-existing — silently broken since the code was written, masked by uniqueness expiry + close-session-already-closed short-circuit.

3. **Other `inspect(reason)` PHI leak sites (11 total)** — all pre-existing, all now trivial 1-line `SafeReason.for_log/1` swaps thanks to the shared module extracted in R2:
   - `lib/alethea_jobs/weekly_report_worker.ex:47` (**same exact bug class** as the R2 fix — `Clinical.save_summary/1` changesets carry `summary_text`)
   - `lib/alethea_jobs/session_reminder_worker.ex:42,45` (line 42 PERSISTED to `audit_logs.details` DB column)
   - `lib/alethea_jobs/emotion_analysis_worker.ex:38,178`
   - `lib/alethea_jobs/process_message_worker.ex:66,141,146,153,162,204,212` (7 sites)
   - `lib/alethea/jobs/telegram_outbound_worker.ex:233,244` (line 244 PERSISTED to `OutboundDeadLetter.last_error`)
   - `lib/alethea/jobs/telegram_message_worker.ex:243,323,426`

4. **Retry after close_session loses goodbye** — `session_timeout_worker.ex:124-125` short-circuits on closed session, so if `TelegramOutboundWorker.new/1 |> Oban.insert!()` fails after `close_session` succeeds, the goodbye is permanently lost. The Telegram goodbye flow needs an outbox / idempotent delivery marker to make Telegram retries work after close.

5. **Channel nil/unknown returns `:ok` without send** — `session_timeout_worker.ex:271-280` catch-all (intentional design backstop documented in moduledoc). Future new channels would silently drop the goodbye rather than fail the job. Consider failing malformed jobs explicitly instead of returning `:ok`.

6. **Stale `@moduledoc`** — `telegram_message_worker.ex:51-59` still says crisis branch "lands in PR #3b"; the crisis branch IS implemented at lines 530-651. Doc drift only.

7. **`Oban.Plugins.Pruner` not configured** — completed/failed `oban_jobs` rows with `chat_id` plaintext in args are retained indefinitely. PG row-level privileges + TLS are operational; no automatic purge. Either add the plugin with a clear retention policy, or explicitly document the choice in ARCHITECTURE.md.

8. **Per-call PHI-safe pattern is fragile** — future error sites can forget `SafeReason.for_log/1` AND `LogRedactor.redact/1` (different scopes). Architectural follow-up: a global Logger backend or `Alethea.SafeLogger` wrapper would centralize the pattern.

9. **`telegram_message_worker.ex:117-126` doc drift** — carry-forward from R2 fix: moduledoc references `session_timeout_worker.ex:180` which is now line 226 after R2 line-shifts; cosmetic.

## Engram observation IDs (for traceability)

| Topic key | ID | Type | What |
|-----------|----|------|------|
| `sdd-init/alethea` | #16 | architecture | SDD init context |
| `sdd/session-timeout-channel-neutral/exploration` | #102 | architecture | Phase 0 exploration |
| `sdd/session-timeout-channel-neutral/proposal` | #103 | architecture | Change proposal |
| `sdd/session-timeout-channel-neutral/spec` | #104 | architecture | Spec with 8 requirements |
| `sdd/session-timeout-channel-neutral/design` | #105 | architecture | Technical design + 2-PR split |
| `sdd/session-timeout-channel-neutral/tasks` | #106 | architecture | 31 sub-checkboxes PR-1 + PR-2 |
| `sdd/session-timeout-channel-neutral/apply-progress-pr1` | #113 | architecture | Apply commit `44841ed` |
| `sdd-workflow-changes-#86` (judgment-day workflow change) | #114 | decision | 3-opinion + PR-after-judgment-day |
| `sdd/session-timeout-channel-neutral/verify-report-pr1` | #119 | architecture | Verify FAIL (initial) |
| `sdd/session-timeout-channel-neutral/fix-r1-uniqueness-period` | #125 | bugfix | R1: renewal uniqueness + silent `replace:` no-op |
| `sdd/session-timeout-channel-neutral/fix-r2-safe-reason-extract` | #130 | bugfix | R2: SafeReason extraction + PHI leak close |
| `sdd/session-timeout-channel-neutral/judgment-round2` | #135 | architecture | R2 terminal **APPROVED ✅** (3-opinion) |
| `sdd/session-timeout-channel-neutral/archive-gate-pr1` | #138 | discovery | Previous archive block detection |
| `sdd/session-timeout-channel-neutral/archive-report-pr1` | (this) | architecture | This archive report (when persisted) |

## Spec sync

SKIPPED per project conventions. The Alethea project does NOT maintain a separate `openspec/specs/` main-specs directory; the change folder archive IS the audit trail. All requirements are captured in `02-spec.md` within this archive.

## Next SDD cycles (recommended order)

1. **#86 PR-2: Crisis-Path Transactional Atomicity** — wrap `handle_crisis_path/9` in `Repo.transaction` + post-commit PubSub/enqueue + R3 crisis-persistence-failure test. Branch off main post-#93 as `feat/session-timeout-channel-neutral-pr2`. Tasks already in `04-tasks.md` (Phases 1-4 of PR-2 section, unchanged — branch off main now, NOT off `feat/session-timeout-channel-neutral-pr1` which is auto-deleted by GitHub post-#93). Use the [chained-pr] skill since PR-2's base is `main` (not PR-1's branch) — rebase strategy only.
2. **PHI hardening follow-up** — sweep the 11 `inspect(reason)` sites in a single PR using the new `SafeReason.for_log/1` (now trivial 1-line swaps). Highest-priority target: `weekly_report_worker.ex:47` (same exact bug class as the R2 fix). ~6 files, low risk; can ride alongside any adjacent PR.
3. **Oban `Oban.Plugins.Pruner` configuration** — operational gap. Either add the plugin with a clear retention policy (e.g. prune completed/failed after 30 days), or explicitly document the "no automatic purge" choice in ARCHITECTURE.md.
4. **Per-call pattern → global Logger backend** — architectural improvement. Larger scope; the `telegram_safe_path_ai_reply` workflow already touched this conceptually (`LogRedactor`). Larger scope; can wait.
5. **Stale `@moduledoc` cleanup** (`telegram_message_worker.ex:51-59`) — 1-section doc fix. Can be rolled into any adjacent PR (PR-2 Refactor phase task 3.1 already lists this).

## Final

**CYCLE COMPLETE.** PR-1 of #86 merged at `926c194` (squash of 4 commits on `feat/session-timeout-channel-neutral-pr1`). PR-2 + the 9 carry-forward WARNINGs are tracked separately and are NOT blocking this archive.
