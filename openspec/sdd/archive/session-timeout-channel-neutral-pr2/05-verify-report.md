# Verify Report: session-timeout-channel-neutral-pr2 (#86 PR-2)

**Change**: Crisis-path transactional atomicity for `TelegramMessageWorker.handle_crisis_path/9`
**Mode**: hybrid (openspec + Engram) — full artifact set (proposal/spec/design/tasks) available
**Base**: 8a9ed71 (planning docs) → **HEAD**: 9f3f718 (`feat(worker): wrap crisis path in Repo.transaction with post-commit broadcast`)
**Strict TDD**: active

## Task Completeness

All checkboxes in `tasks.md` are marked `[x]` (Phase 1 RED, Phase 2 GREEN, Phase 3 Non-Regression, Phase 4 Refactor, Phase 5 Final Verification). No unchecked tasks. Full verification proceeds.

## Independent Test Execution (not trusted from apply report — re-run)

| Command | Result | Exit |
|---|---|---|
| `mix test test/alethea/jobs/telegram_message_worker_test.exs` | **45 passed**, 0 failures | 0 |
| `mix test` (full suite) | **598 passed (6 doctests, 592 tests), 5 skipped** | 0 |
| `mix compile --warnings-as-errors` | clean, no warnings | 0 |
| `mix format --check-formatted` | clean, no diff | 0 |

Matches tasks.md's self-reported figures exactly (45 focused / 598 full-suite / 5 skipped unchanged). Independently reproduced, not merely trusted.

## Spec Requirement Compliance Matrix

### 1. Crisis-Path Transactional Atomicity — **PASS**

`lib/alethea/jobs/telegram_message_worker.ex:590-613`: single `Repo.transaction(fn -> with ... else {:error, r} -> Repo.rollback(r) end end)` wraps all three steps:
- Step 1 `Alethea.Accounts.update_patient(legacy_patient, %{urgent_intervention: true})` — now a `with {:ok, _updated_patient} <- ...` clause (worker.ex:592-593), previously a bare match per tasks.md 2.2.
- Step 2 `Clinical.save_ai_diagnosis/2` — now a `with {:ok, _diagnosis} <- ...` clause (worker.ex:594-599), previously a bare match per tasks.md 2.3.
- Step 4 crisis outbound `Clinical.save_telegram_message/6` — `with {:ok, outbound} <- ...` (worker.ex:600-608), the old `case`/raise collapsed into this transaction's `else` branch (tasks.md 2.4).

Confirmed structural mirror of `persist_and_enqueue_outbound/9` (worker.ex:268-285): same `Repo.transaction(fn -> with ... else {:error, r} -> Repo.rollback(r) end end)` shape followed by a `case` on `{:ok, _}` / `{:error, _}`. Verified side-by-side (worker.ex:590-613 vs 268-285) — pattern is intentionally duplicated inline, not a shared helper, per design.md's explicit rejection of a shared helper.

### 2. Post-Commit Crisis Side Effects — **PASS**

`worker.ex:615-668`: `case transaction_result do`
- `{:ok, outbound} ->` branch (616-654) contains, IN ORDER: `Phoenix.PubSub.broadcast(..., :crisis_detected, ...)` (628-639), `enqueue_outbound(..., lane: :crisis, ...)` (644-647), `Logger.warning(...)` (649-652), then `:ok`. All strictly inside the post-commit branch — broadcast can only fire after `transaction_result` resolves to `{:ok, outbound}`, i.e. after commit.
- `{:error, reason} ->` branch (656-667): `raise "TelegramMessageWorker: failed to persist crisis path (reason=#{SafeReason.for_log(reason)}, hash_prefix=#{hash_prefix})"` — uses `SafeReason.for_log/1`, NOT `inspect(reason)`. No broadcast call, no `enqueue_outbound` call in this branch. Single raise site — no double-raise (the old step-4 `case`/raise is gone, collapsed into the transaction `else`, confirmed by absence of a second raise/case in the diff).

Diff confirms the broadcast is NOT emitted before the outbound save in the new code (old code broadcast mid-sequence per design.md's before/after diagram; new code only broadcasts inside `{:ok, outbound} ->`).

### 3. Crisis Persistence Failure Safety (R3, central) — **PASS**

Test exists: `describe "perform/1 — crisis branch — R3 forced save_ai_diagnosis failure"` (`telegram_message_worker_test.exs:1145`), using `setup :setup_bound_patient_with_blank_crisis_message` (helper at line 1697, delegates to `setup_bound_patient_with_crisis_message("")` at line 1698 — real, not a stub).

Verified assertions are non-tautological and exercise production code through `perform/1` (no mocks):
- (a) `refute reloaded_patient.urgent_intervention` (1191) + `ai_diagnoses_count == 0` scoped by real inbound row FK (1206-1213) + `crisis_outbound_count == 0` scoped by `direction: "outbound"` AND `behavior_type: "crisis_bypass"` (1216-1225). All three query the DB post-`assert_raise`, not pre-computed/mocked values.
- (b) PHI-absence audit is real, not a ghost check: `assert error.message =~ "[:ai_response]"` (1234, positive — proves SafeReason's shape actually appears) is paired with THREE distinct negative assertions: `refute error.message =~ "%Ecto.Changeset"` (1238), `refute error.message =~ "changes:"` (1241), and `refute error.message =~ session_uuid` (1244) where `session_uuid` is a **real UUID captured from `SessionManager.current_open_session/1`** (1173-1174) before the raise — a genuine PHI-surface sentinel, not a hardcoded string that could trivially pass. This is exactly the assertion-quality bar required: a real value that WOULD appear if the bug regressed (pre-fix, the bare `MatchError` exception value was the literal `%Ecto.Changeset{}` struct containing `changes: %{ai_response: ..., message_id: <uuid>}` — confirmed in tasks.md 1.3's RED evidence).
- (c) `refute_receive {:crisis_detected, _}, 200` (1254), subscribed via `Phoenix.PubSub.subscribe(Alethea.PubSub, "psychologist:alerts")` in the describe-level `setup` (1148-1151) — a real subscription, not a no-op.
- (d) `refute_enqueued(worker: TelegramOutboundWorker)` (1258) — real Oban assertion.

No tautologies, no ghost loops (no loop over collections here), no assertion-without-production-call (perform/1 is invoked at 1180-1182), no ratio-imbalance (zero mocks vs. 8 assertions). This is the strongest test in the diff.

### 4. Crisis Happy-Path Non-Regression — **PASS**

`git diff 8a9ed71 9f3f718 -- test/.../telegram_message_worker_test.exs` shows the diff is **purely additive** (+146/-0): the entire existing `describe "perform/1 — crisis branch"` block (862) and `describe "perform/1 — crisis branch with a customized crisis_message"` block (1101-1124) are byte-for-byte unmodified — the new R3 describe block and helper are inserted after them, not interleaved. Focused test run confirms all 45 tests in the file pass (10 from the 862 block + others), consistent with tasks.md 3.1's claim.

### 5. Out-of-Scope Respected — **PASS**

- `current_open_session/1`: zero occurrences in the `git diff 8a9ed71 9f3f718 -- lib/.../telegram_message_worker.ex` — confirmed untouched (grep on the diff returns nothing).
- Stale `@moduledoc` (worker.ex:51-59, "Crisis branch (out of scope here)... lands in PR #3b"): still present verbatim, unchanged (still stale/inaccurate — acknowledged deferred, not this PR's concern).
- Other 4 workers' `inspect(reason)`: `rg -l "inspect(reason)" lib/alethea_jobs/` returns `weekly_report_worker.ex`, `process_message_worker.ex`, `session_reminder_worker.ex`, `session_timeout_worker.ex`, `emotion_analysis_worker.ex` (plus `safe_reason.ex` which defines the shared helper) — none touched by this diff (diff stat confirms only `telegram_message_worker.ex` and the test file changed in `lib`/`test`).
- No migration: `git diff 8a9ed71 9f3f718 --stat -- priv/repo/migrations` returns empty.

## TDD Compliance
| Check | Result | Details |
|-------|--------|---------|
| TDD Evidence reported | ✅ | tasks.md Phase 1 (RED) / Phase 2 (GREEN) / Phase 3 (non-regression) sequence documented with exact `mix test` output at each stage |
| All tasks have tests | ✅ | 2/2 work units (RED test, GREEN implementation) have direct test coverage |
| RED confirmed (tests exist) | ✅ | R3 test file line 1145-1260 exists and is real |
| GREEN confirmed (tests pass) | ✅ | 45/45 independently re-run, 0 failures |
| Triangulation adequate | ✅ | R3 (failure path) + existing 862/1079 block (happy path) + 1101 (customized message happy path) triangulate atomicity from both failure and success angles |
| Safety Net for modified files | ✅ | tasks.md 1.3 documents pre-fix RED state (`MatchError` with raw `%Ecto.Changeset{}`) before the GREEN fix — genuine RED→GREEN cycle, not a fabricated report |

**TDD Compliance**: 6/6 checks passed

### Assertion Quality
No violations found. R3 test (audited above) uses real production calls, scoped DB queries, a genuine PHI sentinel (captured session UUID), and paired positive/negative assertions — no tautologies, ghost loops, or smoke-test-only patterns.

**Assertion quality**: ✅ All assertions verify real behavior

### Quality Metrics
**Linter**: N/A — no linter configured in this Elixir project beyond `mix format`/`mix compile --warnings-as-errors`, both clean.
**Type Checker**: ➖ Not available (no Dialyzer run in this pass; not part of `mix precommit`).

## Design Coherence
Implementation matches design.md's before/after data-flow diagram exactly: transaction wraps steps 1/2/4, `case` on the result, broadcast/enqueue/log strictly in the `{:ok, outbound}` branch, single raise via `SafeReason.for_log/1` in the `{:error, reason}` branch collapsing the old step-4 case. The "Open Questions" item (raise message wording generalized beyond "crisis outbound") was resolved inline exactly as recommended (worker.ex:666-667: "failed to persist crisis path").

## Issues

None found at CRITICAL or WARNING level.

**SUGGESTION** (non-blocking, does not affect this PR's correctness):
- The stale `@moduledoc` at worker.ex:51-59 still claims the crisis branch "lands in PR #3b" and is "out of scope here" — now doubly inaccurate since two PRs (#86 PR-1, PR-2) have since hardened this exact branch. Correctly deferred per this change's explicit out-of-scope list; flagging only so it isn't forgotten in a future doc-hygiene pass.

## Final Verdict: **PASS**

All 5 spec requirements independently verified PASS with file:line evidence. All tasks checked and consistent with code state. Independent `mix test` (598 passed, 5 skipped), `mix test` on the focused file (45 passed), `mix compile --warnings-as-errors`, and `mix format --check-formatted` all reproduce cleanly with exit code 0. R3's assertion quality is strong — real PHI sentinel, zero mocks, scoped DB assertions. No CRITICAL or WARNING issues. Ready for archive.
