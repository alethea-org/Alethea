# Spec: session-timeout-channel-neutral-pr2 (#86 PR-2)

## Purpose

Close #86 by making the Telegram crisis path (`handle_crisis_path/9`) transactionally atomic: patient update, AI diagnosis persistence, and crisis outbound message save commit or roll back together, with crisis-alert side effects (broadcast, outbound enqueue) strictly gated on commit success. No existing spec file covers this domain under `openspec/specs/`; this is a full spec, not a delta. It tightens the three requirements already declared in the PR-1 archive (`openspec/sdd/archive/session-timeout-channel-neutral-pr1/02-spec.md`) — this change is what actually implements them.

## Requirements

### Requirement: Crisis-Path Transactional Atomicity

The crisis-path patient update (`Accounts.update_patient/2` setting `urgent_intervention: true`), AI diagnosis save (`Clinical.save_ai_diagnosis/2`), and crisis outbound message save (`Clinical.save_telegram_message/6`) MUST execute inside one `Repo.transaction`. WHEN any of the three steps returns an error, the transaction MUST roll back all three, leaving no partial commit.

#### Scenario: All three crisis writes succeed

- GIVEN a valid crisis-path inbound Telegram message
- WHEN patient update, AI diagnosis save, and crisis outbound save all succeed
- THEN all three writes commit together inside one transaction

#### Scenario: Any single write fails

- GIVEN a valid crisis-path inbound Telegram message
- WHEN any one of patient update, diagnosis save, or outbound save fails
- THEN the transaction rolls back and none of the three rows persist

### Requirement: Post-Commit Crisis Side Effects

The `:crisis_detected` PubSub broadcast and the crisis-lane outbound enqueue (`enqueue_outbound(lane: :crisis)`) MUST occur only after the transaction from the above requirement commits successfully. WHEN the transaction fails, neither the broadcast nor the enqueue MUST fire.

#### Scenario: Broadcast and enqueue fire after commit

- GIVEN the crisis transaction commits (`{:ok, outbound}`)
- WHEN post-commit side effects run
- THEN the `:crisis_detected` broadcast fires, the crisis-lane outbound job is enqueued, and a warning is logged

#### Scenario: No side effects on transaction failure

- GIVEN the crisis transaction fails (`{:error, reason}`)
- WHEN the worker returns
- THEN no PubSub broadcast fires, no outbound job is enqueued, and the raised error carries no PHI (only `SafeReason.for_log/1` output)

### Requirement: Crisis Persistence Failure Safety (R3)

A forced failure of `save_ai_diagnosis` — triggered end-to-end through `perform/1`, not by mocking — MUST produce zero partial commits, an error free of PHI, and no crisis-alert side effects. This is the central acceptance criterion for this change.

#### Scenario: Forced save_ai_diagnosis failure via perform/1

- GIVEN a bound patient whose professional has `crisis_message: ""` (forcing `ai_response: ""`, which fails `validate_required` inside `save_ai_diagnosis`)
- WHEN a crisis-triggering inbound message is processed via `perform/1`
- THEN no `urgent_intervention` flip persists, no `ai_diagnoses` row is inserted, and no crisis outbound `Message` row is inserted
- AND the raised error's message contains no PHI — only `SafeReason.for_log/1`'s changeset field-name keys
- AND `refute_receive {:crisis_detected, _}` holds
- AND `refute_enqueued(worker: Alethea.Jobs.TelegramOutboundWorker)` holds

### Requirement: Crisis Happy-Path Non-Regression

The pre-existing crisis-branch happy-path behavior (describe block at `telegram_message_worker_test.exs:862`) MUST remain unchanged in outcome: broadcast still fires, outbound message is still enqueued, `urgent_intervention` is still set — only the ordering (post-commit) and atomicity (transactional) change.

#### Scenario: Existing crisis tests stay green

- GIVEN the existing crisis-branch test suite at line 862
- WHEN it runs unmodified against the transactional implementation
- THEN all tests pass without test-file changes

## Deferred / Out of Scope

- R1-W1 staleness race (accepted risk, mirrors pre-existing WhatsApp race) — not addressed here.
- `current_open_session/1` semantics/locking — unchanged.
- The stale `@moduledoc` (worker.ex:51-59) — unchanged.
- `inspect(reason)` bare matches in the other 4 workers — separate PHI-hardening PR.
- No migration or schema change.
