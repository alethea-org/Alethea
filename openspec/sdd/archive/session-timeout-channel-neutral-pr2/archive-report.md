# Archive Report — session-timeout-channel-neutral-pr2 (#86 PR-2)

**Change:** session-timeout-channel-neutral-pr2 — Crisis-Path Transactional Atomicity
**Issue:** alethea-org/Alethea#86 (this PR **closed #86** completely; PR-1 = #93/#94)
**PR:** #95 — `feat(worker): crisis-path transactional atomicity (#86 PR-2)`, squash-merged to `main` (`59b1220`)
**Status:** ✅ shipped, verified, adversarially reviewed, merged.
**Store:** hybrid (Engram topic keys `sdd/session-timeout-channel-neutral-pr2/*`).

## What shipped

`handle_crisis_path/9` in `lib/alethea/jobs/telegram_message_worker.ex` is now transactionally atomic:

- The three crisis clinical writes — patient `urgent_intervention` update, `Clinical.save_ai_diagnosis`, crisis outbound `Clinical.save_telegram_message` — run inside ONE `Repo.transaction` (`with … else {:error, r} -> Repo.rollback(r)`), mirroring the safe-path `persist_and_enqueue_outbound`. Steps 1 & 2 (previously bare `{:ok,_} =` matches) are now `with` clauses.
- The `:crisis_detected` PubSub broadcast + `enqueue_outbound(lane: :crisis)` + `Logger.warning` moved to strictly **post-commit** (`{:ok, outbound}` branch only). This reordered the broadcast, which previously fired *before* the outbound save.
- On `{:error, reason}` the worker raises via `AletheaJobs.SafeReason.for_log/1` (PHI-redacted — field-key names only, never the changeset), with no broadcast and no enqueue.
- **R3 acceptance test** (central deliverable): forces `save_ai_diagnosis` to fail (professional `crisis_message: ""` → `ai_response: ""` → `validate_required` rejects), proving no partial commit, a PHI-safe raise, no crisis broadcast, and no crisis enqueue — all via `perform/1`, zero mocks.

This closes carry-forward **R1-W4** (crisis-path non-atomic / fabricated-record risk) from #85.

## Verification

- `mix precommit`: **598 passed (6 doctests, 592 tests), 5 skipped, 0 failures** — independently reproduced by `sdd-verify` (PASS, 0 CRITICAL/0 WARNING/1 SUGGESTION).
- **Judgment Day — 3 judges** (jd-judge-a + jd-judge-b + review-risk, 3-opinion coverage for a crisis/PHI/transactional change): **0 CRITICAL, 0 SEVERE**. One verified test-hygiene finding (a vacuous `session_uuid` sentinel + false comment in the R3 test) was cleaned up in-PR (commit `7aad4fe`). No re-judgment needed — production code unchanged.

## Carry-forward items (documented, out of scope for #86)

1. **Post-commit "committed-but-undelivered" crisis gap** — if the post-commit broadcast/enqueue raises after the transaction commits, the crisis rows persist but the delivery job may not enqueue, and an Oban retry re-hits the pre-existing inbound `telegram_message_id` `MatchError` before reaching the crisis path again. Both blind judges flagged this (WARNING). Tied to the pre-existing inbound idempotency gap and inherent to the at-least-once + post-commit-side-effects model. → future idempotency-hardening change.
2. **Crisis-path transaction lock contention** — wrapping the three writes holds the legacy-patient row lock + DB connection for their duration; increased contention exposure under concurrent crisis load. Inherent cost of atomicity (the accepted tradeoff of this fix).
3. **PHI-hardening of the other 4 workers** — `inspect(reason)` bare matches in `weekly_report`, `session_reminder`, `emotion_analysis`, `process_message_worker` remain; a dedicated PHI-hardening PR should migrate them to `SafeReason.for_log/1`.
4. **Stale `@moduledoc`** (`telegram_message_worker.ex:51-59`) still claims the crisis branch raises `NotImplementedError` — doc drift, non-blocking.
5. **Unscoped zero-row test query** — the R3 test's crisis-outbound count query isn't scoped to the test patient (relies on DataCase sandbox isolation, the repo's standard).

## Feature status

**#86 is fully closed.** With #84 (safe-path AI reply), #85 (session lifecycle), and #86 (PR-1 channel-neutral timeout worker + PR-2 crisis atomicity) all merged, the only remaining slice of the Telegram-only pipeline PRD (#83) is **#87 — Retire the WhatsApp messaging path**. When #87 closes, #83 closes and the pipeline is complete.
