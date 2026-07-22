# Tasks: Telegram Session Lifecycle — Session Association

## Review Workload Forecast

| Field | Value |
|-------|-------|
| Estimated changed lines | ~90-140 (worker ~25-35 additions/moves; test file ~65-105 additions across 5 new tests) |
| 400-line budget risk | Low |
| Chained PRs recommended | No |
| Suggested split | Single PR |
| Delivery strategy | auto-forecast |
| Chain strategy | pending |

Decision needed before apply: No
Chained PRs recommended: No
Chain strategy: pending
400-line budget risk: Low

### Suggested Work Units

| Unit | Goal | Likely PR | Focused test command | Runtime harness | Rollback boundary |
|------|------|-----------|----------------------|-----------------|-------------------|
| 1 | Thread `session.id` through inbound + safe + crisis saves, full RED→GREEN test suite | PR 1 (single) | `mix test test/alethea/jobs/telegram_message_worker_test.exs` | `mix test` (Oban.Testing + DataCase, no live external harness needed — no shell/process boundary per design Threat Matrix N/A) | Revert single commit touching `lib/alethea/jobs/telegram_message_worker.ex` + its test file; additive `session_id` default `nil`, no migration |

## Phase 1: RED — Inbound Session Association

- [x] 1.1 In `test/alethea/jobs/telegram_message_worker_test.exs`, add test: two `TelegramMessageWorker.perform(%Oban.Job{args: build_args(...)})` calls (distinct `telegram_message_id`/`telegram_update_id`) → query both inbound `Message` rows via `Repo` → assert `session_id` is non-nil and equal on both. Run `mix test` — MUST fail (worker doesn't call `SessionManager` yet, `session_id` stays `nil`/mismatched).

## Phase 2: GREEN — Inbound Session Association

- [x] 2.1 In `lib/alethea/jobs/telegram_message_worker.ex`, add `alias Alethea.Clinical.SessionManager` to the alias block (line 69-74).
- [x] 2.2 After `legacy_patient = Accounts.get_patient_with_professional(legacy_patient.id)` (line 132), insert `{:ok, session} = SessionManager.current_open_session(legacy_patient.id)`.
- [x] 2.3 Add `session.id` as the 6th arg to the inbound `Clinical.save_telegram_message(...)` call (lines 134-141).
- [x] 2.4 Run `mix test test/alethea/jobs/telegram_message_worker_test.exs` — confirm Phase 1 test now passes; confirm no other existing test regresses.

## Phase 3: RED — Safe-Path Outbound Session Association

- [x] 3.1 Add test: single safe-path `perform/1` call (non-crisis text) → query inbound and outbound `Message` rows → assert `outbound.session_id == inbound.session_id` and both non-nil. Run `mix test` — MUST fail (arity mismatch / outbound `session_id` still `nil`).

## Phase 4: GREEN — Safe-Path Outbound Session Association

- [x] 4.1 Bump `handle_safe_path/6` → `/7`: add `session_id` param; update the call site (line 147) to pass `session.id`.
- [x] 4.2 Bump `persist_and_enqueue_outbound/6` → `/7`: add `session_id` param; update the call inside `handle_safe_path` (lines 183-190) to forward `session_id`.
- [x] 4.3 Inside the `#84 Repo.transaction` (lines 223-230), add `session_id` as the 6th arg to the outbound `Clinical.save_telegram_message(...)` call (replace positional `nil`).
- [x] 4.4 Run `mix test test/alethea/jobs/telegram_message_worker_test.exs` — confirm Phase 3 test passes; confirm the #84 transaction/rollback tests still pass unmodified.

## Phase 5: RED — Crisis-Path Outbound Session Association

- [x] 5.1 Add test using the existing crisis fixture pattern (e.g. `build_args("me voy a suicidar", telegram_message_id: ..., telegram_update_id: ...)`) → query inbound + crisis outbound `Message` rows → assert `outbound.session_id == inbound.session_id`. Run `mix test` — MUST fail (arity mismatch / `session_id` nil).

## Phase 6: GREEN — Crisis-Path Outbound Session Association

- [x] 6.1 Bump `handle_crisis_path/8` → `/9`: add `session_id` param; update the call site (lines 150-159) to pass `session.id`.
- [x] 6.2 Add `session_id` as the 6th arg to the crisis outbound `Clinical.save_telegram_message(...)` call (lines 523-530).
- [x] 6.3 Run `mix test test/alethea/jobs/telegram_message_worker_test.exs` — confirm Phase 5 test passes; confirm crisis-branch existing tests (urgent_intervention, ai_diagnosis, PubSub broadcast, escalation) all still pass.

## Phase 7: RED/GREEN — Session Window Grouping + No-Auto-Close Guard

- [x] 7.1 Add test: `perform/1` → `SessionManager.close_session/1` on the returned open session → `perform/1` again (new `telegram_message_id`/`telegram_update_id`) → assert the second inbound `session_id` differs from the first. Run `mix test` — expect it to already pass once Phase 2 lands (no production change needed here since `current_open_session/1` naturally opens a new session after close); if it fails, re-verify Phase 2 wiring before proceeding.
- [x] 7.2 Add guard test: after any safe-path or crisis-path `perform/1`, `refute_enqueued(worker: AletheaJobs.SessionTimeoutWorker)`. Confirm it passes with no production change (no timeout worker is scheduled by this change, per design scope).

## Phase 8: REFACTOR / Cleanup

- [x] 8.1 Re-read the full diff of `lib/alethea/jobs/telegram_message_worker.ex`: confirm the #84 transaction semantics, the duplicate `telegram_message_id` `MatchError` behavior, and no `SessionTimeoutWorker` scheduling remain untouched.
- [x] 8.2 Optional: fix the stale `@moduledoc` (lines 51-59) claiming the crisis branch raises `NotImplementedError` (doc drift only, non-blocking per design Open Questions). Skipped to keep the implementation commit focused; the cleanup remains non-blocking.
- [x] 8.3 Run `mix precommit` (compile `--warnings-as-errors`, `mix format`, full `mix test` suite) — MUST be green before PR.

## Phase 9: PR Notes

- [x] 9.1 PR description explicitly states automatic Telegram inactivity auto-close is NOT live until #86 (design Open Questions boundary note).
