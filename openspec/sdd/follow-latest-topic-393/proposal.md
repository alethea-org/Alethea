# Proposal: Follow the latest topic and close exploration gently (#393)

**Status:** decided — Q1 and the post-closing behavior locked by the user (both recommended defaults)

## Intent

Today Alethea can keep questioning without limit and can revive topics the patient abandoned. After this change the patient decides when the topic changes: each topic stretch gets at most three exploratory questions, then a soft closing invitation.

## Scope

### In Scope
- The model flags a new situation inside the existing single generation call. Code counts questions, enforces the limit, and picks the closing copy.
- Prompt rules: follow the latest topic, never revive abandoned topics, multi-topic burst handling, closing mode.
- Closing-aware `JournalingFallback` variants.
- Non-PHI per-reply columns on `messages`, written in the burst save transaction.
- Behavior tests through `TelegramMessageWorker.perform/1` and the burst job, using `PhiWorkerMock`.

### Out of Scope
- Classifier work (story 30), crisis protocol or copy, confirmed-case copy, WhatsApp.
- The #394 running summary (independent; only merge order matters).
- Storing topic text.

## Capabilities

### New Capabilities
- `telegram-topic-exploration`: following the latest topic, the per-stretch question limit, the closing invitation, and accepted-outcome counting.

### Modified Capabilities
- None (no `openspec/specs/` baseline).

## Approach

Approach 1 from the exploration. Locked decisions:

| # | Decision | Reason |
|---|----------|--------|
| State | Read the latest accepted reply's counters from the same snapshot `generate_burst/2` uses (bounded at the earliest member, `superseded` excluded) | Stable across retries by construction (AC6) |
| Q3 | `failed` and `ambiguous` replies count | Matches the existing history filter, and the model sees them. Delivery state changes asynchronously, so filtering on it would break retry stability. |
| Q2 | A new `session_id` resets the stretch | History is not session-bounded (`turns_before` has no session filter). Replies already carry `session_id`. |
| Q1 | A `crisis_bypass` reply after the latest ordinary reply resets the stretch (**locked by user**) | It can be detected from `behavior_type` in the same snapshot; a crisis interruption plausibly changes what's being discussed |
| Post-closing | If the patient keeps writing on the same topic after the closing invitation, give a brief acknowledgement with no question and no repeated invitation (**locked by user**) | Avoids nagging the patient with a repeated invitation; still respects the limit |
| Q4 | First output line is a fixed marker (`<<NUEVO>>` / `<<SIGUE>>`). It is stripped before the guard, persistence, and delivery. | A leading marker survives truncation at the 160-token cap and is cheaper than JSON |
| Q5 | Missing or malformed marker counts as "same situation", and counting stays deterministic | Fails toward closing, never toward more questions |
| Count | A reply counts as a question when it contains `?` or `¿`. Fallback questions count. The closing invitation never counts. | AC3, AC4 |
| Request | Add a static `exploration_mode` (`:open`/`:closing`) field; no patient data enters the prompt | Keeps the prompt static |

## Affected Areas

| Area | Impact |
|------|--------|
| `lib/alethea/telegram/journaling_reply.ex` | Modified: state, mode, parse, enforce |
| `lib/alethea/ai/phi_worker_behaviour.ex`, `phi_worker.ex`, `chains/guided_conversation_chain.ex` | Modified: mode field, marker parsing |
| `lib/alethea/ai/journaling_prompt.ex` | Modified: new sections and examples |
| `lib/alethea/telegram/journaling_fallback.ex` | Modified: closing variants |
| `lib/alethea/clinical.ex`, `clinical/message.ex`, `priv/repo/migrations/` | Modified/New: counter columns, snapshot read |
| `lib/alethea/jobs/telegram_burst_reply_worker.ex` | Modified: persist metadata |

## Risks

| Risk | Likelihood | Mitigation |
|------|------------|------------|
| phi-4-mini omits or misplaces the marker | Med | Q5 fallback; strip the marker anywhere in the text |
| Topic judgement stays probabilistic | Med | Code guarantees the limit regardless |
| Deliberate contract-test updates (3-key request, prompt headings) | High | Called out in tasks |
| Over 400 changed lines | High | Chained PRs |

## Rollback Plan

Revert the PR(s). The columns are nullable and additive, so the down migration drops them. The request goes back to 3 keys.

## Dependencies

- #391 and #392 (merged).

## Success Criteria

- [ ] All 7 acceptance criteria of #393 are covered by worker-entry tests, with no live model calls.
- [ ] The sentiment regression test still passes.

## Decisions (locked by user)

Both confirmed with the recommended default — see the Approach table above (Q1 row and the Post-closing row).
