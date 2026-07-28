# Tasks: Session Timeout Channel-Neutral (#86)

## Review Workload Forecast — Overview

| Field | Value |
|-------|-------|
| Estimated changed lines | ~370-440 total, split into 2 independent PRs |
| 400-line budget risk | Low per PR (each PR forecast below) |
| Chained PRs recommended | Yes |
| Suggested split | PR-1 (Goal 1) → PR-2 (Goal 2, branches off PR-1) |
| Delivery strategy | auto-forecast (chain strategy pre-resolved by orchestrator) |
| Chain strategy | feature-branch-chain |

Decision needed before apply: No
Chained PRs recommended: Yes
Chain strategy: feature-branch-chain
400-line budget risk: Low

### Suggested Work Units

| Unit | Goal | Likely PR | Focused test command | Runtime harness | Rollback boundary |
|------|------|-----------|----------------------|-----------------|-------------------|
| 1 | Channel-neutral `SessionTimeoutWorker` dispatch | PR-1 | `mix test test/alethea_jobs/session_timeout_worker_test.exs` | `perform_job(SessionTimeoutWorker, telegram_args)` (Oban.Testing) | Revert `session_timeout_worker.ex` commit alone; whatsapp path unaffected |
| 2 | Telegram enqueue-on-inbound-save (renewal) | PR-1 | `mix test test/alethea/jobs/telegram_message_worker_test.exs` | `TelegramMessageWorker.perform/1` then `assert_enqueued` | Revert the one call-site addition in `process_bound_message/6`; worker stays dormant, no crash |
| 3 | Crisis-path `Repo.transaction` atomicity + post-commit side effects | PR-2 | `mix test test/alethea/jobs/telegram_message_worker_test.exs` | `TelegramMessageWorker.perform/1` forcing diagnosis-save failure | Revert `handle_crisis_path/9` transaction commit; independent of PR-1 (different function) |

---

## PR-1: Channel-Neutral SessionTimeoutWorker

### Review Workload Forecast — PR-1

| Field | Value |
|-------|-------|
| Estimated changed lines | ~220-260 (`session_timeout_worker.ex` ~65, `telegram_message_worker.ex` ~30, `session_timeout_worker_test.exs` ~100, `telegram_message_worker_test.exs` ~30) |
| 400-line budget risk | Low |
| Work-unit split | Units 1 + 2 above |
| Base branch | feature/tracker branch (session-timeout-channel-neutral) |

### Phase 1 — RED: SessionTimeoutWorker channel-dispatch tests
- [x] 1.1 `test/alethea_jobs/session_timeout_worker_test.exs`: add test — telegram-channel args enqueue `Alethea.Jobs.TelegramOutboundWorker` goodbye job (`assert_enqueued` with `chat_id`, `chat_id_hash`, `body`, `patient_id: nil`).
- [x] 1.2 Same file: add test — idempotent skip (`status: "closed"`) also short-circuits telegram channel, no enqueue.
- [x] 1.3 Confirm both RED against current `perform/1` (only accepts `phone` shape) — fails to compile/match.

### Phase 2 — GREEN: `lib/alethea_jobs/session_timeout_worker.ex`
- [x] 2.1 Extend `perform/1` to accept `%{"channel"=>_, "chat_id"=>_, "chat_id_hash"=>_}` alongside legacy `%{"phone"=>_}`; default `channel` to `"whatsapp"` when absent and `phone` present (Req: Channel-Neutral Timeout Dispatch, WhatsApp Backward Compatibility).
- [x] 2.2 Change `run_close_flow/3` to stop calling `whatsapp_client().send_message/2` directly; return control to a new `send_goodbye/2`.
- [x] 2.3 Add `send_goodbye/2` channel switch: `"whatsapp"` → `whatsapp_client().send_message(phone, msg)`; `"telegram"` → `Alethea.Jobs.TelegramOutboundWorker.new(%{chat_id:, chat_id_hash:, body: msg, patient_id: nil}) |> Oban.insert!()`.
- [x] 2.4 Verify Phase 1 tests GREEN; run the 2 pre-existing tests unmodified — must stay green (Req: Existing WhatsApp tests remain green).

### Phase 3 — RED: Telegram enqueue-on-inbound-save tests
- [x] 3.1 `test/alethea/jobs/telegram_message_worker_test.exs`: replace the `refute_enqueued` block (446-458, #85 leftover) with `assert_enqueued(worker: AletheaJobs.SessionTimeoutWorker, args: %{channel: "telegram", ...})` for the safe path (Req: Telegram Timeout Job Args).
- [x] 3.2 Same file: add crisis-path test — crisis inbound save also asserts `SessionTimeoutWorker` enqueued (Req: Crisis-path message also enqueues/renews timeout).
- [x] 3.3 Same file: add renewal test — second inbound message on the same open session pushes `scheduled_at` via `replace: [:scheduled_at]` rather than duplicating the job.

### Phase 4 — GREEN: `lib/alethea/jobs/telegram_message_worker.ex`
- [x] 4.1 Add private `schedule_telegram_session_timeout/4` (session, legacy_patient, chat_id, chat_id_hash): builds `%{session_id: session.id, patient_id: legacy_patient.id, channel: "telegram", chat_id:, chat_id_hash:}`, `unique: [fields: [:args]]`, `Oban.insert!(replace: [:scheduled_at])`, `scheduled_at: now + 30 min`.
- [x] 4.2 Call it once in `process_bound_message/6`, immediately after the successful inbound save (post line 151), before the `CrisisMonitor.detect/1` case split — one call site covering both safe and crisis branches.
- [x] 4.3 Verify Phase 3 tests GREEN.

### Phase 5 — REFACTOR
- [x] 5.1 Confirm no duplicated "now + 30 min" logic leaks cross-module; keep local to each worker (mirrors `process_message_worker.ex` pattern, no shared helper per design).
- [x] 5.2 Clean up `session_timeout_worker.ex`: colocate `whatsapp_client/0` and telegram dispatch helpers, remove dead branches.

### Phase 6 — Verification
- [x] 6.1 `mix test test/alethea_jobs/session_timeout_worker_test.exs`
- [x] 6.2 `mix test test/alethea/jobs/telegram_message_worker_test.exs`
- [x] 6.3 `mix precommit` green before opening PR-1.

---

## PR-2: Crisis-Path Transactional Atomicity (branches off PR-1)

### Review Workload Forecast — PR-2

| Field | Value |
|-------|-------|
| Estimated changed lines | ~150-180 (`telegram_message_worker.ex` ~90-110, `telegram_message_worker_test.exs` ~60-70) |
| 400-line budget risk | Low |
| Work-unit split | Unit 3 above |
| Base branch | PR-1's branch (not main; feature-branch-chain child) |

### Phase 1 — RED: R3 crisis persistence-failure test
- [ ] 1.1 `test/alethea/jobs/telegram_message_worker_test.exs`: add test forcing `save_ai_diagnosis` (or crisis outbound save) to fail inside `handle_crisis_path/9`, invoked via `TelegramMessageWorker.perform/1` — assert zero rows: no `urgent_intervention` flip, no `ai_diagnoses` row, no crisis outbound `Message` row (Req: Crisis Persistence Failure Safety R3).
- [ ] 1.2 Same test: assert the raised/returned error contains no PHI (only `safe_reason/1` field keys, never changeset `changes`).
- [ ] 1.3 Same test: subscribe `"psychologist:alerts"`, `refute_receive {:crisis_detected, _}`.
- [ ] 1.4 Same test: `refute_enqueued(worker: Alethea.Jobs.TelegramOutboundWorker)` — no crisis-lane enqueue on rollback.
- [ ] 1.5 Confirm RED against current sequential (non-transactional) crisis path.

### Phase 2 — GREEN: `lib/alethea/jobs/telegram_message_worker.ex`
- [ ] 2.1 Wrap `handle_crisis_path/9` steps 1-4 (lines 521-578: `update_patient`, `save_ai_diagnosis`, crisis outbound `save_telegram_message`) in one `Repo.transaction(fn -> with ... else {:error, r} -> Repo.rollback(r) end end)` (Req: Crisis-Path Transactional Atomicity).
- [ ] 2.2 Move the PubSub `:crisis_detected` broadcast and `enqueue_outbound(lane: :crisis, ...)` to run only on `{:ok, outbound}` — strictly post-commit (Req: Post-Commit Crisis Side Effects).
- [ ] 2.3 On `{:error, reason}`, raise via the existing PHI-safe `safe_reason/1` (preserve 7bb409d fix) — no broadcast, no enqueue.
- [ ] 2.4 Verify Phase 1 test GREEN; confirm "all crisis writes succeed" happy-path test still passes.

### Phase 3 — REFACTOR
- [ ] 3.1 Optional: fix stale `@moduledoc` (lines 51-59, still describes crisis branch as "PR #3b, out of scope") to reflect landed + now-transactional crisis behavior.
- [ ] 3.2 Confirm the crisis transaction mirrors `persist_and_enqueue_outbound/7`'s existing `Repo.transaction` + `Repo.rollback` shape (pattern consistency, no extraction required — different function per design scope).

### Phase 4 — Verification
- [ ] 4.1 `mix test test/alethea/jobs/telegram_message_worker_test.exs`
- [ ] 4.2 `mix precommit` green before opening PR-2 (target: PR-1's branch).

---

## Out of Scope (per design)

- `SessionManager.current_open_session/1` — unchanged (R1-W1 staleness race accepted/deferred).
- No migration / `channel` column on `clinical_sessions` or `Session`.
- Duplicate `telegram_message_id` `MatchError` — untouched.
