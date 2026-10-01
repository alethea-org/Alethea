# Tasks: Continue from a previous E-O-R-C version (#365)

## Review Workload Forecast

| Field | Value |
|-------|-------|
| Estimated changed lines | ~370 (130 prod + 240 tests) |
| 400-line budget risk | Medium |
| Chained PRs recommended | No |
| Suggested split | Single PR `feat/365-continue-from-version` → `origin/main` |
| Delivery strategy | single-pr (split not deliverable, design §Forecast) |
| Chain strategy | size-exception (fallback only, after trim lever 4.1) |

Decision needed before apply: No
Chained PRs recommended: No
Chain strategy: size-exception
400-line budget risk: Medium

### Suggested Work Units

| Unit | Goal | Likely PR | Focused test command | Runtime harness | Rollback boundary |
|------|------|-----------|----------------------|-----------------|-------------------|
| 1 | Request/confirm/cancel continuation | PR 1 | `mix test test/alethea_web/live/target_behavior_live/review_test.exs` | LiveView tests (real autosave via `:sys.get_state`) | Revert PR; `review.ex` + `review_test.exs` only |

Files: `lib/alethea_web/live/target_behavior_live/review.ex` (R), `test/alethea_web/live/target_behavior_live/review_test.exs` (T). All code verbatim from design §Interfaces/Contracts.

## Phase 1: Refactors (zero behavior change)

- [x] 1.1 Baseline: run focused test file; record green + pre-existing warnings. NOTE: baseline compile (unmodified, before any edit in this session) actually has 4 pre-existing `clinical_record.ex` warnings (same "clause cannot match" family) at lines 1256, 1377, 1473, 1549 — not 2. Verified via `mix compile --warnings-as-errors --force` on this branch before touching any file. `clinical_record.ex` is out of scope for #365 and untouched by this change. 120/120 tests passed.
- [x] 1.2 R: `assign(:continue_confirmation_pending, false)` after :173.
- [x] 1.3 R: extract `schedule_functional_analysis_autosave/2` (AD1); `change_functional_analysis` `true` branch (:756-762) calls it; form assign :741-746, tombstone :749, `params_equal?` :752 untouched.
- [x] 1.4 R: add `put_selected_version/3` (AD6); replace assign pairs :900-902, :920-922, :928-930; clause 1 :889-896 unedited.
- [x] 1.5 GREEN: existing autosave + #364 tests pass unchanged (120/120).

## Phase 2: Core logic (RED → GREEN)

- [x] 2.1 T: new describe "continue from a previous E-O-R-C version (GitHub #365)" after :2216; reuse `review_path/2`, `persist_draft!/4`, `version_count/0`, `eorc_params/1`, `field_view_id/1`.
- [x] 2.2 RED: blank draft → immediate apply (no confirmation, DB == version after `:sys.get_state`, flash, `version_count` unchanged) [C2,C5,C7]. Confirmed RED before implementation (button did not exist).
- [x] 2.3 RED: content → confirmation with "Versión N", continue button hidden, DB unchanged [C3,C1]. Confirmed RED alongside 2.2.
- [x] 2.4 R: `continuation_blocker/1` (L5/AD3-AD5 cond, exact flash), `working_form_blank?/1` (AD8).
- [x] 2.5 R: `apply_version_continuation/1` (L3 re-fetch; ok / `:unauthorized` → `redirect_to_patients` / other → flash + `relist_version_summaries/1`; AD2 always schedules; AD9 `v.version_number`).
- [x] 2.6 R: events `request_`/`confirm_`/`cancel_continue_from_version` after select clauses per design dispatch table; confirm checks pending `== true` first (AD7).
- [x] 2.7 R: template block after meta row with design's six ids, verbatim HEEx.
- [x] 2.8 GREEN: 2.2–2.3 (122/122 passed).

## Phase 3: Scenario tests (RED → GREEN each)

- [x] 3.1 Confirm: real autosave path, view gone, form shows copy [C4,C5].
- [x] 3.2 Cancel: confirmation gone, panel kept, DB/form unchanged [C6].
- [x] 3.3 `:conflict` via `:sys.replace_state`: request + forged confirm → flash, no write [C8].
- [x] 3.4 `:saving`/`:save_failed` + queued stale edit → DB == version after flush [C8, AD2].
- [x] 3.5 Deletion race (`Retention.legally_delete_record` between request and confirm) → flash, option gone, no protected text [C4].
- [x] 3.6 Unauthorized at confirm → redirect, no copy (spec scenario; not in design table). Simulated by reassigning `patient.professional_id` to another professional between request and confirm, then restoring it (`Ecto.Changeset.force_change/3` required — plain `change/2` against the test's stale in-memory `patient` struct produced an empty changeset no-op on the restore).
- [x] 3.7 Forged events, table-driven (mirror #364 :2162-2179): confirm without request, no selection, tombstoned, generation pending → DB + `autosave_seq` unchanged [C10].
- [x] 3.8 Selection change (working draft / other version) clears pending; later forged confirm writes nothing [C9].
- [x] 3.9 AC5 reload: fresh `live/2` shows copy; reopened version shows original body [C7].

All 11 new-describe tests GREEN (120 pre-existing + 11 new = 131/131 passed).

## Phase 4: Size check and verification

- [x] 4.1 `git diff --stat origin/main`. Trim lever applied (3.7 forged events table-driven, mirroring #364). Final scope-correct diff (`review.ex` + `review_test.exs` only, excluding pre-existing SDD docs and the pre-existing untracked `.gga`): 190+17 (review.ex) + 582+0 (review_test.exs) = 789 changed lines — over the 400-line budget and over the ~370 forecast (test scenarios grew from an estimated ~240 to 582 lines to cover all 9 Testing-Strategy rows + table-driven forged block). Per tasks.md's own pre-declared `Chain strategy: size-exception (fallback only, after trim lever 4.1)` and the orchestrator-provided context (`Delivery: SINGLE PR — design.md determined a split is not deliverable`), proceeding under the pre-authorized `size:exception` fallback. Flagged to orchestrator in apply report rather than silently absorbed.
- [x] 4.2 `mix compile --warnings-as-errors --force` → diffed warning locations (file:line) against the true pre-edit baseline (captured on this branch before any edit in this session): identical set, zero new warnings. NOTE: baseline is actually 4 pre-existing `clinical_record.ex` warnings (lines 1256, 1377, 1473, 1549), not the 2 stated in the task prompt — see 1.1 note. `clinical_record.ex` untouched by this change either way.
- [x] 4.3 `mix format --check-formatted` → clean after `mix format` on the 2 touched files. Full `mix test` was intentionally NOT run per the orchestrator's testing protocol ("run focused tests as you go; do NOT run the full suite yourself at the end") — only the focused file (131/131) was run.
- [x] 4.4 Diff scope confirmed: only `review.ex` + `review_test.exs` modified by this apply batch; no domain/schema files touched (`tasks.md` self-tracking and pre-existing SDD docs/`​.gga` are out of this accounting).
