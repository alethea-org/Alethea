## Crisis-Path Transactional Atomicity — final piece of #86

Closes #86.

PR-2 of the `session-timeout-channel-neutral` change (PR-1 = #93, channel-neutral SessionTimeoutWorker, already merged). This makes the Telegram crisis path atomic and closes the last carry-forward (R1-W4).

### What this delivers

`handle_crisis_path/9` previously ran patient update → AI diagnosis save → PubSub `:crisis_detected` broadcast → crisis outbound save → enqueue as a flat, non-transactional sequence — the broadcast fired **before** the outbound save, so a partial failure could fabricate a crisis alert with no backing record.

- The three clinical writes (patient `urgent_intervention` update, `save_ai_diagnosis`, crisis outbound `save_telegram_message`) now run inside ONE `Repo.transaction`; any failure rolls back all three (no partial commit). Steps 1 & 2 (previously bare matches) are now `with` clauses.
- The `:crisis_detected` broadcast + `enqueue_outbound(lane: :crisis)` + log run strictly **post-commit** (only on `{:ok, outbound}`); on `{:error, reason}` the worker raises via `AletheaJobs.SafeReason.for_log/1` (PHI-redacted — field keys only, never the changeset), with no broadcast and no enqueue.
- **R3 acceptance test**: forces `save_ai_diagnosis` to fail (blank `crisis_message` → empty `ai_response` → `validate_required` rejects), asserting no partial commit (no `urgent_intervention` flip, 0 `ai_diagnoses`, 0 crisis outbound rows), a PHI-safe raise, `refute_receive {:crisis_detected, _}`, and `refute_enqueued(TelegramOutboundWorker)`.

### Validation

- `mix precommit`: **598 passed, 5 skipped, 0 failures** (compile `--warnings-as-errors` + format + full suite), independently reproduced.
- 3-judge adversarial review (jd-judge-a + jd-judge-b + review-risk): **0 CRITICAL, 0 SEVERE**. One verified test-hygiene finding (a vacuous `session_uuid` sentinel in the R3 test) was cleaned up in this PR.

### Out of scope (documented carry-forwards)

Post-commit "committed-but-undelivered" gap on the crisis path (tied to the pre-existing inbound `telegram_message_id` retry `MatchError`); crisis-path transaction lock contention (inherent to atomicity); the stale `@moduledoc`; the `inspect(reason)` bare matches in the other 4 workers (separate PHI-hardening PR).

### Diff

2 files: `lib/alethea/jobs/telegram_message_worker.ex` + its test.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
