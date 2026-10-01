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

- [ ] 1.1 Baseline: run focused test file; record green + 2 pre-existing warnings (`clinical_record.ex:1473/1549`).
- [ ] 1.2 R: `assign(:continue_confirmation_pending, false)` after :173.
- [ ] 1.3 R: extract `schedule_functional_analysis_autosave/2` (AD1); `change_functional_analysis` `true` branch (:756-762) calls it; form assign :741-746, tombstone :749, `params_equal?` :752 untouched.
- [ ] 1.4 R: add `put_selected_version/3` (AD6); replace assign pairs :900-902, :920-922, :928-930; clause 1 :889-896 unedited.
- [ ] 1.5 GREEN: existing autosave + #364 tests pass unchanged.

## Phase 2: Core logic (RED → GREEN)

- [ ] 2.1 T: new describe "continue from a previous E-O-R-C version (GitHub #365)" after :2216; reuse `review_path/2`, `persist_draft!/4`, `version_count/0`, `eorc_params/1`, `field_view_id/1`.
- [ ] 2.2 RED: blank draft → immediate apply (no confirmation, DB == version after `:sys.get_state`, flash, `version_count` unchanged) [C2,C5,C7].
- [ ] 2.3 RED: content → confirmation with "Versión N", continue button hidden, DB unchanged [C3,C1].
- [ ] 2.4 R: `continuation_blocker/1` (L5/AD3-AD5 cond, exact flash), `working_form_blank?/1` (AD8).
- [ ] 2.5 R: `apply_version_continuation/1` (L3 re-fetch; ok / `:unauthorized` → `redirect_to_patients` / other → flash + `relist_version_summaries/1`; AD2 always schedules; AD9 `v.version_number`).
- [ ] 2.6 R: events `request_`/`confirm_`/`cancel_continue_from_version` after :934 per design dispatch table; confirm checks pending `== true` first (AD7).
- [ ] 2.7 R: template block after :2592 with design's six ids, verbatim HEEx.
- [ ] 2.8 GREEN: 2.2–2.3.

## Phase 3: Scenario tests (RED → GREEN each)

- [ ] 3.1 Confirm: real autosave path, view gone, form shows copy [C4,C5].
- [ ] 3.2 Cancel: confirmation gone, panel kept, DB/form unchanged [C6].
- [ ] 3.3 `:conflict` via `:sys.replace_state`: request + forged confirm → flash, no write [C8].
- [ ] 3.4 `:saving`/`:save_failed` + queued stale edit → DB == version after flush [C8, AD2].
- [ ] 3.5 Deletion race (`Retention.legally_delete_record` between request and confirm) → flash, option gone, no protected text [C4].
- [ ] 3.6 Unauthorized at confirm → redirect, no copy (spec scenario; not in design table).
- [ ] 3.7 Forged events, table-driven (mirror #364 :2162-2179): confirm without request, no selection, tombstoned, generation pending → DB + `autosave_seq` unchanged [C10].
- [ ] 3.8 Selection change (working draft / other version) clears pending; later forged confirm writes nothing [C9].
- [ ] 3.9 AC5 reload: fresh `live/2` shows copy; reopened version shows original body [C7].

## Phase 4: Size check and verification

- [ ] 4.1 `git diff --stat origin/main`; if >400, trim first: consolidate 3.3/3.7/3.8 forged cases into table-driven tests before any `size:exception`.
- [ ] 4.2 `mix compile --warnings-as-errors --force` → zero NEW warnings beyond the 2 pre-existing.
- [ ] 4.3 `mix format --check-formatted`; full `mix test`.
- [ ] 4.4 Diff scope: only `review.ex` + `review_test.exs`; no domain/schema files.
