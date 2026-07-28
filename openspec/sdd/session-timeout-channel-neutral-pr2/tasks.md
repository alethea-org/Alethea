# Tasks: Crisis-Path Transactional Atomicity (#86 PR-2)

## Review Workload Forecast

| Field | Value |
|-------|-------|
| Estimated changed lines | ~150-180 (re-indent counted as remove+add) |
| 400-line budget risk | Low |
| Chained PRs recommended | No |
| Suggested split | single PR |
| Delivery strategy | auto-forecast |
| Chain strategy | pending (not needed — single PR confirmed) |

Decision needed before apply: No
Chained PRs recommended: No
Chain strategy: pending
400-line budget risk: Low

### Suggested Work Units

| Unit | Goal | Likely PR | Focused test command | Runtime harness | Rollback boundary |
|------|------|-----------|----------------------|-----------------|-------------------|
| 1 | RED: R3 forced-failure test + blank-crisis helper | PR 1 (only PR) | `mix test test/alethea/jobs/telegram_message_worker_test.exs:1080` (new R3 test line, adjust after insert) | N/A — zero-mock DB-level `perform/1` call, no external process | Revert test-file diff only; no production code touched yet |
| 2 | GREEN: transactional `handle_crisis_path/9` + non-regression | PR 1 (only PR) | `mix test test/alethea/jobs/telegram_message_worker_test.exs` | N/A — pure Ecto/Oban sandbox, no external send | One merge-commit revert restores prior flat 6-step body |

## Phase 1: RED — R3 Failing Test

- [ ] 1.1 In `test/alethea/jobs/telegram_message_worker_test.exs` (~1551), add `setup_bound_patient_with_blank_crisis_message/1` — one-liner delegating to `setup_bound_patient_with_crisis_message("")`, mirroring `setup_bound_patient_with_custom_crisis_message/1`.
- [ ] 1.2 In `describe "perform/1 — crisis branch"` (test:862), add the R3 test calling `perform/1` on a crisis-triggering message with the blank-crisis-message setup; assert (a) reloaded `Patient.urgent_intervention` is false, `ai_diagnoses` count is 0, outbound `Message` (`direction: "outbound"`, `behavior_type: "crisis_bypass"`) count is 0; (b) `assert_raise` + `refute error.message =~` crisis plaintext, message contains only `SafeReason` field-name keys; (c) `refute_receive {:crisis_detected, _}` on `"psychologist:alerts"`; (d) `refute_enqueued(worker: Alethea.Jobs.TelegramOutboundWorker)`.
- [ ] 1.3 Run `mix test test/alethea/jobs/telegram_message_worker_test.exs` — confirm the new R3 test FAILS against current non-transactional `handle_crisis_path/9` (partial commit / premature broadcast).

## Phase 2: GREEN — Transactional Crisis Path

- [ ] 2.1 In `lib/alethea/jobs/telegram_message_worker.ex` (557-651), wrap steps 1 (`update_patient`), 2 (`save_ai_diagnosis`), 4 (crisis outbound `save_telegram_message`) in one `Repo.transaction(fn -> with ... else {:error, r} -> Repo.rollback(r) end end)`, mirroring `persist_and_enqueue_outbound/9` (268-285).
- [ ] 2.2 Convert step 1's bare `{:ok, _updated_patient} =` match into a `with` clause.
- [ ] 2.3 Convert step 2's bare `{:ok, _diagnosis} =` match into a `with` clause.
- [ ] 2.4 Collapse step 4's existing `case`/raise (616-631) into the transaction's `with`/rollback branch — no double-raise; keep `SafeReason.for_log/1` (already aliased at worker.ex:75).
- [ ] 2.5 Move the `:crisis_detected` broadcast (582-601), `enqueue_outbound(lane: :crisis)` (633-643), and `Logger.warning` into the post-commit `case` branch for `{:ok, outbound}`.
- [ ] 2.6 On `{:error, reason}` (transaction failure), raise using `SafeReason.for_log(reason)` — no broadcast, no enqueue.
- [ ] 2.7 Run `mix test test/alethea/jobs/telegram_message_worker_test.exs` — confirm the R3 test is GREEN.

## Phase 3: Non-Regression Verification

- [ ] 3.1 Run the existing crisis-branch describe block (862, tests 894-1079) unmodified — confirm all pass (they assert eventual state, not ordering).
- [ ] 3.2 Run `mix test` (full suite) — confirm no unrelated regressions.

## Phase 4: Refactor (optional, non-blocking)

- [ ] 4.1 Optionally generalize the raise message to span the whole crisis path, e.g. `"failed to persist crisis path (reason=#{SafeReason.for_log(reason)})"`.
- [ ] 4.2 Confirm untouched: `current_open_session/1`, the stale `@moduledoc` (51-59), the other 4 workers' `inspect(reason)` matches, no migration.

## Phase 5: Final Verification

- [ ] 5.1 `mix format`
- [ ] 5.2 `mix compile --warnings-as-errors`
- [ ] 5.3 `mix precommit` — green (compile, format, full suite)
