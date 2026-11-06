# Issue 450 — Trigger reactivo cooldown, fire-once and limits

Parent PRD #435. Branch `feat/450-reactive-trigger-limits` from origin/main `d13f9d4`, worktree `C:/Users/teofu/Code/Alethea-450`.
Owner-only access and content-free audit on every mutation, as in the rest of `Alethea.Triggers`.

## Specs

- S1 (issue): "The professional can edit a reactive trigger's cooldown and mark it as fire-once (deactivates after the first firing)."
- S2 (issue acceptance): "A fire-once trigger fires once and then is inactive."
- S3 (issue): "Editing the condition resets the cooldown." Acceptance: "After a condition edit, the trigger can fire immediately."
- S4 (issue): "At most 20 active reactive triggers per patient (global configuration)." Acceptance: "Creating or activating a 21st reactive trigger is rejected with a clear message."
- S5 (PRD #435): "Every create, edit, pause and resume of a trigger to be recorded in the audit log" and "Access is scoped to the patient's owning professional."
- S6 (PRD #435, US7): "each reactive trigger to have a cooldown (24h by default, editable)".

## Design decisions

- D1: fire-once is a new `fire_once` boolean (NOT NULL, default false). A fire-once firing sets status `inactive` in the same locked transaction as the firing, with audit `trigger_deactivated_fire_once`.
- D2: the cooldown reset is a new nullable `cooldown_reset_at` column. Firings at or before it do not count towards the cooldown. Firing history is never deleted (PRD US19 source-anchored history).
- D3: editing a reactive condition, cooldown or fire-once keeps the approved text (it is drafted from the instruction, not the condition). Audit `trigger_updated`.
- D4: the limit is `config :alethea, :max_active_reactive_triggers, 20`, enforced on create, activate and resume, serialized by a `FOR UPDATE` lock on the patient row. Error `{:error, :reactive_limit_reached}`; UI message: "Este paciente ya tiene 20 triggers reactivos activos. Desactiva uno antes de crear o activar otro."

## Tasks

- [x] T1 S1,S2,S6 — migration `fire_once` + `cooldown_reset_at`; schema; create accepts `cooldown_hours`/`fire_once`; firing deactivates fire-once trigger. Route: worker mw54d6qz-2-repp. Commit: domain
- [x] T2 S1,S3,S5 — `update_reactive_trigger/4` (condition, cooldown_hours, fire_once), cooldown reset honored by `eligible_reactive_triggers/2` and `fire_reactive_trigger/3`. Route: worker mw54d6qz-2-repp. Commit: domain
- [x] T3 S4,S5 — active reactive limit on create/activate/resume. Route: worker mw54d6qz-2-repp. Commit: domain
- [x] T4 S1-S4 — LiveView: cooldown/fire-once inputs, reactive edit form, limit message. Route: worker mw54mwd8-3-p9lw. Commit: ui
- [x] T5 — verification (Risk items 1 migration, 4 concurrency → independent verify), `mix precommit`. Route: gentle-ai-verify mw54ws75-4-tcfz. Commit: fix

## Log

- L1 (user, 2026-11-06): "que tal empezar por la ##435" → chose sub-issue "#450 cooldown, fire-once y límites"; working tree: "Worktree aparte".
- L2 (evidence, 2026-11-06): T1 RED compile error `unknown key :fire_once`; T2 RED 8/12 `UndefinedFunctionError update_reactive_trigger/4`; T3 RED 5/19. GREEN: reactive_limits_test 19/0; test/alethea/triggers/ + telegram_burst_reply_worker_test 133/0 (re-run by parent); compile --warnings-as-errors clean. Postgres container alethea-db-1 recreated with user approval on existing volume alethea_postgres_data.
- L3 (evidence, 2026-11-06): T4 RED 6/13 new LiveView tests; GREEN triggers LiveView tests (reactive, live, management, dashboard summary) 54/0 re-run by parent. Worker's `mix format` on a CRLF working copy reflowed unrelated HEEx; parent reverted the 19 whitespace-only hunks (origin/main file passes --check-formatted via stdin) and normalized to LF.
- L4 (evidence, 2026-11-06): verifier verdicts S1-S6 pass. Full suite 6 doctests, 2804 tests, 8 failures (all test/alethea/release_test.exs Windows/POSIX release-script baseline, not touched by this branch), 5 skipped; compile --warnings-as-errors and deps.unlock --check-unused exit 0; stdin format check exit 0 on all changed files.
- L5 (fix, 2026-11-06): verifier finding 1 (medium, deadlock: activate/resume locked trigger then patient, burst reply worker locks patient then trigger) fixed by locking the patient row first in activate_trigger/resume_trigger. Finding 2 (crafted save_reactive_edit with no open edit crashed the LiveView) fixed with RED FunctionClauseError -> GREEN; triggers context + worker + LiveView tests 188/0. Open, not fixed: finding 3 (low) two firings possible within the same second as a condition edit; finding 4 (info) no concurrent-create test at the limit.
- L6 (evidence, 2026-11-06): re-verifier mw558t12-5-96oc on c56c254: S1-S6 pass; findings 1 (deadlock) and 2 (nil-edit crash) resolved, no remaining trigger-then-patient lock path. Migration rollback --step 1 and migrate exit 0 on alethea_test_issue450. compile --warnings-as-errors exit 0; full suite 6 doctests, 2805 tests, 8 failures (all test/alethea/release_test.exs baseline), 5 skipped; stdin format check exit 0 on 7 files. New low: save_reactive_edit without "edit_reactive" key raises FunctionClauseError (LiveView crash only). Info, pre-existing: pause_active_triggers_for_crisis locks several trigger rows without ORDER BY on crisis replay paths.
