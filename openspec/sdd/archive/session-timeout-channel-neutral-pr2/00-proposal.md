# Proposal: Crisis-Path Transactional Atomicity (#86 PR-2)

## Intent

`handle_crisis_path/9` (lib/alethea/jobs/telegram_message_worker.ex:557-651) is non-atomic. The `:crisis_detected` PubSub broadcast (582-601) fires BEFORE the crisis outbound `save_telegram_message` (603-631). A failure after broadcast but at/before the outbound save leaves a fabricated crisis alert on `psychologist:alerts` with no backing record — and no atomic rollback of the earlier `urgent_intervention` flip or the persisted `ai_diagnoses` row. Steps 1 (`update_patient`) and 2 (`save_ai_diagnosis`) are still BARE `=` matches (only step 4 was hardened in PR-1 R2 / 7bb409d), so a failure there raises a raw `MatchError` that can leak PHI. This is the final piece closing #86 (R1-W4 carry-forward).

## Scope

### In Scope
- Wrap steps 1-4 in ONE `Repo.transaction`, mirroring the shape at `persist_and_enqueue_outbound` (259-283).
- Convert steps 1, 2, 4 to `with` clauses feeding one `else {:error, r} -> Repo.rollback(r)` branch (NEW error handling for steps 1-2).
- Move broadcast + `enqueue_outbound(lane: :crisis)` OUTSIDE, strictly post-commit. On `{:ok, outbound}` → broadcast → enqueue → Logger.warning → `:ok`. On `{:error, reason}` → `raise "...#{AletheaJobs.SafeReason.for_log(reason)}"` (NOT inspect), no broadcast, no enqueue.
- R3 acceptance test (central deliverable): force `save_ai_diagnosis` failure via `perform/1`, asserting (a) zero rows persisted, (b) raised error carries NO PHI (only SafeReason field keys), (c) `refute_receive {:crisis_detected, _}`, (d) `refute_enqueued(worker: Alethea.Jobs.TelegramOutboundWorker)`.
- One-line test helper `setup_bound_patient_with_blank_crisis_message/1` (crisis_message: `""` → `ai_response: ""` → fails `validate_required`).

### Out of Scope
- `current_open_session/1`, the stale `@moduledoc` (51-59).
- The `inspect(reason)` bare matches in the other 4 workers (separate PHI-hardening PR).
- No migration / schema change. No shared helper extraction.

## Capabilities

### New Capabilities
None.

### Modified Capabilities
None (behavior-hardening refactor; no requirement-level spec exists in `openspec/specs/`).

## Approach

Transaction wrap of steps 1-4 + post-commit reorder of steps 5-6 + zero-mock R3 test. Forcing mechanism: professional `crisis_message: ""` → Elixir `||` does not fall through on `""` → `ai_response: ""` → deterministic `{:error, %Ecto.Changeset{}}` from `save_ai_diagnosis`, no Mox seam, no production churn.

## Affected Areas

| Area | Impact | Description |
|------|--------|-------------|
| `lib/alethea/jobs/telegram_message_worker.ex` (557-651) | Modified | Transaction wrap + post-commit reorder |
| `test/.../telegram_message_worker_test.exs` (describe @862) | Modified | R3 test + blank-crisis helper |

## Risks

| Risk | Likelihood | Mitigation |
|------|------------|------------|
| Broadcast reorder read as scope creep | Med | Required for post-commit correctness — a broadcast must never precede its commit; documented as core, not creep |
| Re-indent inflates raw diff (steps 1-4 gain 1-2 levels) | High | ~60 re-indented lines counted as remove+add; total ~150-180, still well under 400; single PR remains correct |
| `inspect(changeset)` accidentally in raise | Low | Use `SafeReason.for_log/1` exclusively; R3 asserts absence of PHI |

## Rollback Plan

Single non-chained PR to `main`. Revert the one merge commit — restores prior flat 6-step body. No migration, no data backfill, no schema state to unwind.

## Dependencies

- `AletheaJobs.SafeReason.for_log/1` (existing).
- Existing test plumbing `setup_bound_patient_with_crisis_message/1`.

## Success Criteria

- [ ] Steps 1-4 execute inside one `Repo.transaction`; broadcast + enqueue are strictly post-commit.
- [ ] R3 test passes: zero rows, PHI-free raise, `refute_receive`, `refute_enqueued`.
- [ ] Existing crisis-branch tests (@862) stay green.
- [ ] `mix precommit` clean; diff under 400 lines; single PR "Closes #86".
