# Proposal: Reply once after a Telegram message burst (#391)

## Intent

Per-message replies interrupt journaling, and stale generation or queued delivery can answer a conversation that has already moved on. Rapid messages stay individual records but get one reply after ~45s of inactivity. Stale replies are never sent. Crisis handling stays immediate.

## Scope

### In Scope
- Debounced burst-reply Oban job per patient. Each ordinary inbound renews it.
- One reply covers every uncovered inbound in the burst, in the patient's send order.
- Staleness check at commit time (after generation) and at dispatch time (claim, including retries).
- New `superseded` delivery state. A crisis supersedes pending ordinary replies.
- Superseded replies are excluded from model history.
- Behavior tests through `TelegramMessageWorker.perform/1`, with `PhiWorkerMock` and the fake client.

### Out of Scope
- Changes to classifier, crisis protocol or copy, or reply guard/fallback rules (#392).
- Recalling replies that are already `sending` or `ambiguous`.
- WhatsApp pipeline. Changing the emotion analysis pipeline (AC7 already holds; only asserted).

## Capabilities

### New Capabilities
- `telegram-burst-reply`: debounce window, burst coverage, stale suppression, crisis supersession.

### Modified Capabilities
- None (no `openspec/specs/` baseline exists).

## Approach

Approach A from exploration. Locked decisions:

| # | Decision | Reason |
|---|----------|--------|
| Debounce | New worker with `unique: [keys: [:patient_id], states: [:scheduled]]` and `replace: [scheduled: [:scheduled_at]]` | Same idea as `SessionTimeoutWorker`, but scoped to `:scheduled`. Its default states with `period: :infinity` would block every later burst. A newer inbound during execution therefore re-arms naturally. |
| A: order | Order burst members by `telegram_message_id::bigint` | The Telegram per-chat counter is the true send order. `timestamp` is second-truncated (`list_conversation_turns` documents this) and `id` is a UUID. No schema change. |
| D: coverage | New nullable `messages.replied_by_message_id` on inbound rows, set by a conditional UPDATE (`IS NULL`) in the reply transaction | Deriving coverage from a time range gives no atomic guarantee against overlapping jobs, crisis interleaving or out-of-order inserts. The DB update makes AC5 provable. A migration backfills existing inbound rows so history never joins a burst. |
| Generation | Burst-aware entry in `JournalingReply`: all members sanitized, in order, exactly once. The anchor (`reply_to_message_id`) is the newest member. | `generate/3` takes one inbound today. Guard and fallback stay untouched. |
| Withhold | A lost coverage UPDATE or a newer uncovered inbound rolls back the transaction: no reply row, no diagnosis | Follows #390's rule: no fabricated undelivered records. |
| Dispatch | The claim UPDATE also requires that no newer inbound exists. Otherwise the reply becomes `superseded` and releases its coverage. | This reuses the existing claim, which runs after `Pacer.acquire` and again on every retry. |
| Crisis | The crisis transaction supersedes pending ordinary replies, then covers all uncovered inbound up to and including the crisis inbound | No generative rewrite. Later ordinary messages start a new burst. |
| B: in-flight | Accepted residual race, documented | Telegram sends cannot be recalled. The claim follows the Pacer wait, so the window is one HTTP request. |
| C: history | `list_conversation_turns` excludes `superseded` outbound rows | It does not filter on delivery state today. Withheld text was never said to the patient. |

## Affected Areas

| Area | Impact |
|------|--------|
| `lib/alethea/jobs/telegram_message_worker.ex` | Modified: safe path arms the job, crisis path supersedes |
| `lib/alethea/jobs/telegram_burst_reply_worker.ex` | New |
| `lib/alethea/jobs/telegram_outbound_worker.ex`, `lib/alethea/clinical.ex` | Modified: claim recheck, coverage, `superseded`, history filter |
| `lib/alethea/telegram/journaling_reply.ex` | Modified: burst input |
| `priv/repo/migrations/` | New: coverage column, index and backfill |
| `test/alethea/jobs/` | New behavior tests |

## Risks

| Risk | Likelihood | Mitigation |
|------|------------|------------|
| Backfill misses rows, so an old backlog joins a burst | Med | Backfill is tested. The burst query is bounded. |
| Over 400 changed lines | High | Chained PRs, planned in tasks |
| A crisis right after an ordinary send | Low | Accepted (B) |

## Rollback Plan

Revert the PR(s). The safe path goes back to synchronous `generate/3`. The column is nullable and additive, so the down migration drops it. `superseded` rows remain unsent.

## Dependencies

- #390 (merged), #392 (merged).

## Success Criteria

- [ ] All 8 acceptance criteria of #391 are covered by worker-entry tests, with no live model calls.
- [ ] An existing sentiment regression test still passes.
