# Proposal: session-timeout-channel-neutral (#86)

## Intent

Telegram sessions never auto-close (deferred from #85), so summaries/trends are never generated for Telegram patients. `SessionTimeoutWorker` is hardcoded to `phone` + `whatsapp_client`. Separately, the crisis path in `telegram_message_worker.ex` broadcasts a crisis alert BEFORE the outbound record is persisted — a partial failure fabricates an alert with no backing record (R1-W4). This change delivers channel-neutral auto-close AND crisis-path atomicity.

## Scope

### In Scope
- **Goal 1** — Generalize `SessionTimeoutWorker`: on fire, close session, generate summary/trends (reuse channel-independent RoBERTa + `SessionSummaryChain` as-is), send goodbye through the correct channel adapter. Thread `channel` + routing identifiers via Oban job args at enqueue.
- **Goal 1** — Enqueue timeout in `telegram_message_worker.ex` `process_bound_message` right after the successful inbound save (post line 151); one call site covers safe + crisis branches.
- **Goal 2** — Wrap crisis patient-update + `save_ai_diagnosis` + crisis-outbound save in ONE `Repo.transaction`; move PubSub broadcast + `enqueue_outbound` to strictly post-commit.
- Worker tests (Telegram goodbye + channel dispatch); replace `refute_enqueued` test at `telegram_message_worker_test.exs:446-458`; add R3 crisis-outbound persistence-failure test.

### Out of Scope
- Changing `current_open_session/1` semantics or locking (R1-W1 accepted/deferred).
- Any new migration / `channel` column / Session schema change.
- Pre-existing duplicate `telegram_message_id` MatchError.
- Optional: stale crisis-branch `@moduledoc` (~51-59) claiming `NotImplementedError`.

## Capabilities

### New Capabilities
None.

### Modified Capabilities
None (behavioral change; no spec-level requirement files exist).

## Approach

- **Channel dispatch = Oban job args.** WhatsApp caller passes `phone` (unchanged); Telegram caller passes `chat_id` + `chat_id_hash` + `channel: "telegram"`. `perform/1` accepts existing `%{session_id,patient_id,phone}` shape unchanged; absent channel + present phone defaults to `"whatsapp"`. Raw `chat_id` MUST ride args (never persisted at rest — only HMAC hash).
- **Crisis atomicity.** Single `Repo.transaction` for the three writes; side effects (broadcast, enqueue) run only after commit. Mirrors safe-path `persist_and_enqueue_outbound` fix from #84.

## Affected Areas

| Area | Impact | Description |
|------|--------|-------------|
| `lib/alethea_jobs/session_timeout_worker.ex` | Modified | Channel-aware goodbye + args (~90→~150) |
| `lib/alethea_jobs/process_message_worker.ex` | Unchanged | Backward-compat args keep working |
| `lib/alethea/jobs/telegram_message_worker.ex` | Modified | Enqueue after save; crisis transaction |
| `test/alethea_jobs/session_timeout_worker_test.exs` | Preserved | 2 tests stay green unmodified |
| `test/alethea/jobs/telegram_message_worker_test.exs` | Modified | Replace :446-458; add R3 failure test |

## Delivery

~450-650 changed lines → EXCEEDS 400 review budget. Chained split: **PR-1 = Goal 1** (worker + Telegram enqueue + worker tests + replace :446-458); **PR-2 = Goal 2** (crisis transaction + R3 failure test). PR-2 is largely independent (different function, same file). `sdd-tasks` concretizes the split.

## Risks

| Risk | Likelihood | Mitigation |
|------|------------|------------|
| R1-W1 staleness race goes live for Telegram once worker fires | Med | ACCEPTED/DEFERRED — mirrors WhatsApp's pre-existing accepted race; blast radius = one late message excluded from summary, no crash/corruption |
| Broadcast reorder (now post-commit) reads as scope creep | Low | Documented explicitly as required by Goal 2 / R1-W4 fix |
| WhatsApp worker regression | Low | Preserve exact args shape; 2 existing tests unmodified |
| Safe-path #84 transaction regressed | Low | Do not touch `persist_and_enqueue_outbound` |

## Rollback Plan

Two independent PRs → revert either commit independently. Reverting PR-1 restores WhatsApp-only worker + Telegram no-auto-close (pre-#86). Reverting PR-2 restores non-atomic crisis path. No migration/schema change → no data rollback needed.

## Success Criteria

- [ ] Telegram session fires timeout → closes, persists summary/trends, sends goodbye via Telegram adapter.
- [ ] 2 existing `session_timeout_worker_test.exs` tests pass unmodified.
- [ ] Crisis writes commit atomically; broadcast + enqueue only post-commit.
- [ ] R3 test: forced crisis-outbound save failure → no partial commit, no PHI in raise, broadcast did NOT fire.
