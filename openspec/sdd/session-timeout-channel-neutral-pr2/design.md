# Design: Crisis-Path Transactional Atomicity (#86 PR-2)

## Technical Approach

Wrap `handle_crisis_path/9` steps 1-4 (`update_patient` -> `save_ai_diagnosis`
-> crisis outbound `save_telegram_message`) in ONE `Repo.transaction`, and move
the `:crisis_detected` broadcast + `enqueue_outbound(lane: :crisis)` +
`Logger.warning` to strictly post-commit. Mirror the shape already proven at
`persist_and_enqueue_outbound/9` (lib/alethea/jobs/telegram_message_worker.ex:268-285)
exactly — same `Repo.transaction(fn -> with ... else {:error, r} -> Repo.rollback(r) end end)`
followed by a `case` — but as a SEPARATE inline body, NO shared helper. The R3
acceptance test is the central deliverable: a zero-mock forced failure of
`save_ai_diagnosis` proving atomic rollback and PHI-safe raise.

Verification corrections vs. brief: `AletheaJobs.SafeReason` is ALREADY aliased
(worker.ex:75) — no new alias/import needed. Crisis diagnosis attrs use the
`response:` key inline; `Clinical.save_ai_diagnosis/2` (clinical.ex:227) maps
`:response` -> the `ai_response` field. `crisis_reply_text/1` (658-665) is
unchanged.

## Architecture Decisions

| Decision | Choice | Rejected | Rationale |
|---|---|---|---|
| Atomicity boundary | Single `Repo.transaction` over steps 1,2,4 | Flat sequential (today) | A post-broadcast failure today leaves a fabricated alert + orphaned `urgent_intervention` flip + orphaned `ai_diagnoses` row; rollback unwinds all three |
| Broadcast placement | Post-commit (after `{:ok, outbound}`) | Keep pre-outbound (today, 582-601) | A crisis alert must never precede its backing commit; reorder is CORE correctness, not scope creep |
| Steps 1-2 error handling | Convert bare `{:ok,_}=` to `with` clauses -> `Repo.rollback(r)` | Leave bare matches | Bare `MatchError` on step 1/2 leaks changeset PHI + is non-atomic; NEW hardening (PR-1 R2 only touched step 4) |
| Failure forcing (R3) | Professional `crisis_message: ""` -> `crisis_text: ""` -> `ai_response: ""` -> `validate_required` fail | Mox port for `save_ai_diagnosis` | Zero mock, zero production churn; `\|\|` does not fall through on `""` |
| Helper reuse | Inline body, no extraction | Shared helper w/ safe path | Different arity/steps; proposal forbids shared helper — keep blast radius minimal |

## Data Flow

Before (non-atomic, broadcast mid-sequence):

    update_patient(BARE) -> save_ai_diagnosis(BARE) -> BROADCAST -> outbound save(case/raise) -> enqueue -> log

After (atomic; broadcast post-commit):

    Repo.transaction:
      with {:ok,_}<-update_patient, {:ok,_}<-save_ai_diagnosis, {:ok,outbound}<-save_telegram_message -> outbound
      else {:error,r} -> Repo.rollback(r)
    case:
      {:ok,outbound} -> BROADCAST -> enqueue_outbound(lane: :crisis) -> Logger.warning -> :ok
      {:error,reason} -> raise "...#{SafeReason.for_log(reason)}"  (no broadcast, no enqueue)

The step-4 `case ... raise SafeReason.for_log` (7bb409d) collapses INTO the
`with`/rollback; the single raise now lives on the transaction's `{:error,_}`
branch — no double-raise. Inbound Message save happens BEFORE
`handle_crisis_path` (OUTSIDE the transaction) — an inbound row still exists on
crisis failure; R3 asserts only crisis-path writes.

## File Changes

| File | Action | Description |
|---|---|---|
| `lib/alethea/jobs/telegram_message_worker.ex` (557-651) | Modify | Transaction wrap of steps 1,2,4 + post-commit reorder of broadcast/enqueue/log; re-indent inflation ~60 lines |
| `test/alethea/jobs/telegram_message_worker_test.exs` (describe @862, helper @1551) | Modify | R3 test + `setup_bound_patient_with_blank_crisis_message/1` |

## Interfaces / Contracts

No public API change. Internal control-flow only. `SafeReason.for_log/1` on a
changeset yields `[:ai_response]` (failed field keys, never `changes`/`data`).

## Testing Strategy

| Layer | What | Approach |
|---|---|---|
| Unit (R3, central) | Crisis atomicity + PHI-safe raise | Via `perform/1`, zero-mock blank-crisis forcing |
| Regression | Crisis happy-path (894-1079) | Unchanged; assert eventual state, not step ordering -> survive reorder |

R3 test (new, in describe @862): setup
`setup_bound_patient_with_blank_crisis_message/1` (one-liner delegating to
`setup_bound_patient_with_crisis_message("")`, mirror @1551). Assertions via
`perform/1`:
- (a) reload Patient -> `refute urgent_intervention`; `Repo.aggregate` count
  `ai_diagnoses` == 0; crisis outbound Message (`direction: "outbound"` /
  `behavior_type: "crisis_bypass"`) count == 0.
- (b) `assert_raise` -> `refute error.message =~` crisis plaintext; message
  contains only `SafeReason` field-key output.
- (c) subscribe `"psychologist:alerts"` -> `refute_receive {:crisis_detected, _}`.
- (d) `refute_enqueued(worker: Alethea.Jobs.TelegramOutboundWorker)`.

Mirrors the safe-path forced-failure trio (772-854).

## Threat Matrix

N/A — no routing, shell, subprocess, VCS/PR automation, executable-file
classification, or process-integration boundary. PubSub broadcast + Oban
enqueue are in-process; no external command surface.

## Migration / Rollout

No migration required. Single non-chained PR to `main` ("Closes #86"). Revert
the one merge commit restores the prior flat 6-step body. Idempotency: the
transaction makes crisis retries safe (rollback on failure -> clean slate). The
pre-existing duplicate `telegram_message_id` `MatchError` is untouched (inbound
save is OUTSIDE this transaction). Forecast ~150-180 changed lines
(re-indent counted as remove+add), well under the 400 budget -> single PR.

## Open Questions

- [ ] Raise message wording now spans steps 1-2-4 (not only "crisis outbound").
      Recommend generalizing to e.g. "failed to persist crisis path
      (reason=#{SafeReason.for_log(reason)})". Non-blocking — R3 asserts only
      PHI-absence + SafeReason content, not exact prose.
