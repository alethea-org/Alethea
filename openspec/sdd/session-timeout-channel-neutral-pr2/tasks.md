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

- [x] 1.1 In `test/alethea/jobs/telegram_message_worker_test.exs` (~1551), add `setup_bound_patient_with_blank_crisis_message/1` — one-liner delegating to `setup_bound_patient_with_crisis_message("")`, mirroring `setup_bound_patient_with_custom_crisis_message/1`.
- [x] 1.2 Add the R3 test inside a new describe block (`perform/1 — crisis branch — R3 forced save_ai_diagnosis failure`, immediately after the customized-crisis_message describe) to avoid the `telegram_chat_id_hash` unique-index collision when both the describe-level `setup :setup_bound_patient` and a per-test `setup :setup_bound_patient_with_blank_crisis_message` run. The test forces `save_ai_diagnosis/2` to fail via `crisis_message: ""` -> `crisis_text: ""` -> `ai_response: ""` -> `validate_required(:ai_response)`. Assertions: (a) reloaded `Patient.urgent_intervention` is false, `ai_diagnoses` count is 0, crisis outbound `Message` (`direction: "outbound"`, `behavior_type: "crisis_bypass"`) count is 0; (b) `assert_raise RuntimeError, ~r/failed to persist/` + `assert error.message =~ "[:ai_response]"` (SafeReason shape) + `refute error.message =~ "%Ecto.Changeset"`, `"changes:"`, and the session UUID; (c) `refute_receive {:crisis_detected, _}` on `"psychologist:alerts"`; (d) `refute_enqueued(worker: Alethea.Jobs.TelegramOutboundWorker)`.
- [x] 1.3 R3 RED confirmed: `mix test test/alethea/jobs/telegram_message_worker_test.exs:1153` -> `MatchError` (not `RuntimeError`) with `%Ecto.Changeset{}` exception value (current non-transactional `handle_crisis_path/9` raises bare match on the failing changeset — exactly the bug class being closed).

## Phase 2: GREEN — Transactional Crisis Path

- [x] 2.1 In `lib/alethea/jobs/telegram_message_worker.ex`, wrap steps 1 (`update_patient`), 2 (`save_ai_diagnosis`), 4 (crisis outbound `save_telegram_message`) in one `Repo.transaction(fn -> with ... else {:error, r} -> Repo.rollback(r) end end)`, mirroring `persist_and_enqueue_outbound/9` (268-285). Inline body (no shared helper) per proposal/design decision.
- [x] 2.2 Convert step 1's bare `{:ok, _updated_patient} =` match into a `with` clause.
- [x] 2.3 Convert step 2's bare `{:ok, _diagnosis} =` match into a `with` clause.
- [x] 2.4 Collapse step 4's existing `case`/raise into the transaction's `with`/rollback branch — no double-raise; keep `SafeReason.for_log/1` (already aliased at worker.ex:75).
- [x] 2.5 Move the `:crisis_detected` broadcast, `enqueue_outbound(lane: :crisis)`, and `Logger.warning` into the post-commit `case` branch for `{:ok, outbound}`.
- [x] 2.6 On `{:error, reason}` (transaction failure), raise `"TelegramMessageWorker: failed to persist crisis path (reason=#{SafeReason.for_log(reason)}, hash_prefix=#{hash_prefix})"` — no broadcast, no enqueue. PHI-safe wording (Phase 4 refactor applied inline — the old "crisis outbound" wording became inaccurate once the transaction spans steps 1-2-4).
- [x] 2.7 Run `mix test test/alethea/jobs/telegram_message_worker_test.exs` — R3 GREEN + all 44 pre-existing tests still PASS (45 passed total).

## Phase 3: Non-Regression Verification

- [x] 3.1 Run the existing crisis-branch describe block (862, tests 894-1079) unmodified — all 10 PASS (they assert eventual state, not step ordering, so the post-commit broadcast reorder leaves them green).
- [x] 3.2 Run `mix test` (full suite) — `598 passed (6 doctests, 592 tests), 5 skipped`. Matches expected baseline (597 pre-existing + 1 new R3 = 598; 5 skipped unchanged). No unrelated regressions.

## Phase 4: Refactor (optional, non-blocking)

- [x] 4.1 Generalized raise message applied inline with Phase 2 GREEN: `"failed to persist crisis path (reason=#{SafeReason.for_log(reason)}, hash_prefix=#{hash_prefix})"`. Replaces the misleading "crisis outbound" wording now that the transaction spans steps 1-2-4. R3 asserts only `[:ai_response]` shape, not exact prose.
- [x] 4.2 Confirmed untouched:
    - `current_open_session/1` — unchanged (R1-W1 staleness race deferred per orchestrator scope).
    - The stale `@moduledoc` at `telegram_message_worker.ex:51-59` — unchanged (doc-drift-only, deferred per orchestrator scope).
    - The other 4 workers' `inspect(reason)` matches — unchanged (separate PHI-hardening PR per orchestrator scope).
    - No migration / schema change — none added (the design forbids it).

## Phase 5: Final Verification

- [x] 5.1 `mix format` — clean.
- [x] 5.2 `mix compile --warnings-as-errors` — clean.
- [x] 5.3 `mix precommit` — green. `598 passed (6 doctests, 592 tests), 5 skipped`. Matches expected baseline (597 pre-existing + 1 new R3 = 598; 5 skipped unchanged).

### Diff size vs. forecast

| File | Lines |
|---|---|
| `lib/alethea/jobs/telegram_message_worker.ex` | +129/-49 (worker.ex `handle_crisis_path/9` only — ~348 raw lines including mandatory re-indent) |
| `test/alethea/jobs/telegram_message_worker_test.exs` | +146/-0 (new describe block + helper + R3 test) |
| `openspec/sdd/session-timeout-channel-neutral-pr2/tasks.md` | +24/-8 (task checkboxes) |
| **Total raw lines** | +299/-57 = **356** (under 400 budget) |
