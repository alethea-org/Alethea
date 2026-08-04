# Exploration — session-timeout-channel-neutral-pr2 (#86 PR-2)

**Source:** #86 PR-2 (final piece) — Crisis-Path Transactional Atomicity. Base: main @ 983541c (PR-1 merged + archived).
**Store:** hybrid (Engram `sdd/session-timeout-channel-neutral-pr2/explore`). Strict TDD (`mix test`).

## Current state — handle_crisis_path/9 (lib/alethea/jobs/telegram_message_worker.ex:557-651)

| Step | Lines | Call | Error handling today |
|---|---|---|---|
| 1. update_patient | 570-572 | `{:ok, _} = Accounts.update_patient(legacy_patient, %{urgent_intervention: true})` | BARE match — MatchError on failure, no SafeReason |
| 2. save_ai_diagnosis | 574-580 | `{:ok, _} = Clinical.save_ai_diagnosis(inbound.id, %{...})` | BARE match — same gap |
| 3. PubSub :crisis_detected broadcast | 582-601 | `Phoenix.PubSub.broadcast(...)` | fires BEFORE outbound save today (must reorder) |
| 4. crisis outbound save_telegram_message | 603-631 (case) | `Clinical.save_telegram_message(fp, crisis_text, "outbound", "crisis_bypass", nil, session_id)` | Already `case {:error, r} -> raise "...#{SafeReason.for_log(r)}"` (the 7bb409d / PR-1 R2 fix) |
| 5. enqueue_outbound(lane: :crisis) | 633-643 | | |
| 6. Logger.warning | 645-648 | | |
| return :ok | 650 | | |

**Reorder confirmed**: broadcast (step 3) runs BEFORE outbound save (step 4) today — opposite of post-commit. New order: `Repo.transaction(fn -> with step1, step2, step4 ... else {:error,r} -> Repo.rollback(r) end end)` → on `{:ok, outbound}`: broadcast → enqueue → Logger.warning → :ok; on `{:error, reason}`: `raise "...#{SafeReason.for_log(reason)}"`, no broadcast, no enqueue.

**Scope note**: PR-1 R2 (7bb409d) hardened ONLY step 4's error shape. Steps 1 & 2 are still bare `=` matches with zero PHI-safe handling. Wrapping steps 1-4 means all three become `with` clauses feeding one `{:error, r} -> Repo.rollback(r)` — NEW work on steps 1-2, not just a mechanical move.

## AletheaJobs.SafeReason.for_log/1 (lib/alethea_jobs/safe_reason.ex)
```
def for_log(%Ecto.Changeset{errors: errors}), do: errors |> Keyword.keys() |> Enum.uniq() |> inspect()
def for_log(reason), do: inspect(reason)
```
Right redactor: changeset → only failed-field-name keys (never changes/data). Non-changeset ({:error,:not_linked}, {:error,:legacy_not_found} from save_telegram_message) → inspect of a bare atom (no PHI). Use `SafeReason.for_log(reason)` in the raise (import/alias AletheaJobs.SafeReason).

## Clinical calls that can fail in the transaction (lib/alethea/clinical.ex)
- save_ai_diagnosis/2 (219-233): `%Diagnosis{} |> Diagnosis.changeset(attrs) |> Repo.insert()` → `{:ok, %Diagnosis{}} | {:error, %Ecto.Changeset{}}`.
- save_telegram_message/6 (134-161): → `{:ok, message} | {:error, :not_linked} | {:error, :legacy_not_found}`.
Both shapes handled by `with ... else {:error, r} -> Repo.rollback(r)` + SafeReason.

Alethea.AI.Diagnosis (lib/alethea/ai/diagnosis.ex): `field :ai_response, :string, redact: true`, `field :extracted_emotions, :map, redact: true`, `@derive {Inspect, except:[...]}`. changeset validates_required([:model_version, :extracted_emotions, :ai_response, :message_id]).

## R3 forcing mechanism (the central deliverable's "how") — RESOLVED
Crisis path builds diagnosis attrs INLINE, hardcoded (model_version: "crisis-bypass" literal; extracted_emotions always a map; ai_response = crisis_text = `legacy_patient.professional.crisis_message || default_crisis_support_message()`, worker.ex:658-664). NO Mox seam (unlike safe path's phi_worker()), and save_ai_diagnosis is a concrete call (not a port) so can't be stubbed.

**Deterministic, zero-mock mechanism (RECOMMENDED — Approach A)**: set the professional's `crisis_message` to `""` (empty string, NOT nil). Elixir `||` does NOT fall through on `""` (only nil/false), so `crisis_text = "" || default → ""`. Ecto `validate_required` treats `""` as blank for :string → `save_ai_diagnosis` returns `{:error, %Ecto.Changeset{}}` → deterministic failure, no mocking, no schema change, no production seam. Test plumbing already exists: `setup_bound_patient_with_crisis_message/1` (test:1555) sets the field via `Ecto.Changeset.change(%{crisis_message: cm}) |> Repo.update!()` (bypasses Professional.changeset which only requires email/full_name). Add a one-line `setup_bound_patient_with_blank_crisis_message/1, do: setup_bound_patient_with_crisis_message("")` (mirrors existing `_with_custom_crisis_message/1` at test:1551).

Rejected Approach B (introduce a Mox port for save_ai_diagnosis): production churn not authorized, expands blast radius past "different function, no shared helper", over-engineered for one negative test.

## Existing crisis tests (describe "perform/1 — crisis branch", test:862)
Tests at 894, 914, 937, 953, 976 (assert_receive {:crisis_detected,...}), 1010, 1032, 1047 (assert_enqueued), 1079 assert eventual state/messages, NOT step-internal ordering → moving broadcast to post-commit will NOT break them. Extend the describe block at 862 with the R3 test (mirrors the safe-path forcing-failure trio at 772-854).

## Size / PR
Forecast ~150-180 (worker ~90-110, test ~60-70), SINGLE PR, not chained (confirmed). RISK: wrapping the flat 6-step body in Repo.transaction re-indents steps 1-4 (~60 lines) 1-2 levels → git counts re-indent as removed+added, may push raw count at/above forecast. Still well under 400. Single PR remains correct.

## Decisions
No genuinely new architectural fork — all fixed decisions confirmed feasible. The R3 forcing mechanism (crisis_message: "") is a "how" implementation detail, not a re-opened "whether".

## Risks
- Diff-size inflation from mandatory re-indentation (still low 400-budget risk).
- Steps 1-2 currently bare matches (zero error handling) — PR-2 adds with-clause handling for both, core scope not surprise.
- Ecto's redact-aware Changeset Inspect likely already redacts ai_response from raw inspect(changeset) — secondary net, not a substitute for SafeReason.for_log (which never surfaces changes). Sanity-check at apply, not a blocker.
- No test-only forced-failure mechanism found for step 4 (save_telegram_message) — out of scope; R3 targets save_ai_diagnosis specifically.

**Ready for proposal:** yes.
