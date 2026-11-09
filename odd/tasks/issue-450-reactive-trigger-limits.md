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
- S7 (user, manual test): "Los botones "Activos", "Reactivos" e "Historial" no siguen la estética en general de la UI, quiero que arregles eso." Each tab must show only its own panel (pre-existing bug: `.hidden`, `.tabs` and `.button-tab` are not defined in the stylesheet; reuse `.review-tabs` / `.review-tab--active`).
- S8 (user decision "Botón por pestaña"): each tab lists its triggers and has a "Nuevo trigger activo" / "Nuevo trigger reactivo" button that expands the creation form (collapsed by default).

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
- [x] T6 S7,S8 — triggers page tabs with `.review-tabs`, real panel hiding, per-tab "Nuevo trigger" button. Route: worker mw59zea5-7-2sfv. Commit: tabs
- [~] T7 (skipped by user) — local testing setup: Ollama (LLM_MODEL) + real Telegram bot via docs/main-demo-operator-guide.md (user-owned bot token). Route: inline/user. Commit: docs (no code)

## Log

- L1 (user, 2026-11-06): "que tal empezar por la ##435" → chose sub-issue "#450 cooldown, fire-once y límites"; working tree: "Worktree aparte".
- L2 (evidence, 2026-11-06): T1 RED compile error `unknown key :fire_once`; T2 RED 8/12 `UndefinedFunctionError update_reactive_trigger/4`; T3 RED 5/19. GREEN: reactive_limits_test 19/0; test/alethea/triggers/ + telegram_burst_reply_worker_test 133/0 (re-run by parent); compile --warnings-as-errors clean. Postgres container alethea-db-1 recreated with user approval on existing volume alethea_postgres_data.
- L3 (evidence, 2026-11-06): T4 RED 6/13 new LiveView tests; GREEN triggers LiveView tests (reactive, live, management, dashboard summary) 54/0 re-run by parent. Worker's `mix format` on a CRLF working copy reflowed unrelated HEEx; parent reverted the 19 whitespace-only hunks (origin/main file passes --check-formatted via stdin) and normalized to LF.
- L4 (evidence, 2026-11-06): verifier verdicts S1-S6 pass. Full suite 6 doctests, 2804 tests, 8 failures (all test/alethea/release_test.exs Windows/POSIX release-script baseline, not touched by this branch), 5 skipped; compile --warnings-as-errors and deps.unlock --check-unused exit 0; stdin format check exit 0 on all changed files.
- L5 (fix, 2026-11-06): verifier finding 1 (medium, deadlock: activate/resume locked trigger then patient, burst reply worker locks patient then trigger) fixed by locking the patient row first in activate_trigger/resume_trigger. Finding 2 (crafted save_reactive_edit with no open edit crashed the LiveView) fixed with RED FunctionClauseError -> GREEN; triggers context + worker + LiveView tests 188/0. Open, not fixed: finding 3 (low) two firings possible within the same second as a condition edit; finding 4 (info) no concurrent-create test at the limit.
- L6 (evidence, 2026-11-06): re-verifier mw558t12-5-96oc on c56c254: S1-S6 pass; findings 1 (deadlock) and 2 (nil-edit crash) resolved, no remaining trigger-then-patient lock path. Migration rollback --step 1 and migrate exit 0 on alethea_test_issue450. compile --warnings-as-errors exit 0; full suite 6 doctests, 2805 tests, 8 failures (all test/alethea/release_test.exs baseline), 5 skipped; stdin format check exit 0 on 7 files. New low: save_reactive_edit without "edit_reactive" key raises FunctionClauseError (LiveView crash only). Info, pre-existing: pause_active_triggers_for_crisis locks several trigger rows without ORDER BY on crisis replay paths.
- L7 (user, 2026-11-06, manual test): tabs off-style; "me muestra la sección "Nuevo trigger activo" y debajo la de "Nuevo trigger reactivo""; no "Guardar trigger" without an LLM; simulate script failed with `"1"` (needs the trigger UUID). Decisions: fix tabs "Sí, en esta rama"; alta "Botón por pestaña"; preview "Ollama local"; Telegram "Sí, ahora". Verified: tabs/panels come from 04409c3 (#440/#442) and cd18fab (#448), not #450.
- L8 (evidence, 2026-11-06): T6 RED 20/37 (no new-trigger buttons, panels not hidden); GREEN triggers LiveView tests 58/0 re-run by parent; no whitespace-only hunks. Panels use the HTML `hidden` attribute (not `:if`) so LiveView stream items survive tab switches.
- L9 (user decision, 2026-11-06): "Neon, reemplazando el bot" for local Telegram testing. Shared Neon dev DB migrated from 20261001132114 to 20261106151907 (all pending main migrations + #450). Team bot row foundation_bot_configs env dev (alethea_dev_bot) backed up as ciphertext to %TEMP%/f450/neon_foundation_bot_configs_backup.json before the user's bootstrap overwrites it; restore after testing.
- L10 (user, 2026-11-08): T7 manual test "Ya la hice y anduvo". Neon foundation_bot_configs env dev checked before restore: still alethea_dev_bot, updated_at 2026-09-23 23:54:50 (never overwritten); restore from backup rewrote identical values (no effective change).
- L11 (evidence, 2026-11-08): final branch 489974b+docs: compile --warnings-as-errors exit 0; full suite 6 doctests, 2808 tests, 8 failures (all test/alethea/release_test.exs Windows/POSIX baseline), 5 skipped.
- L12 (user correction, 2026-11-08): "No hice realmente la prueba manual, quiero que me guies a hacerla ahora". L10's manual-test claim is void; T7 reopened.
- L13 (user decision, 2026-11-08): "Hace el push y PR no más". T7 manual Telegram test skipped; PR relies on automated tests and verifier evidence (L4-L6, L8, L11).
- L14 (evidence, 2026-11-09): user "Restaura no más el bot del equipo en Neon". Neon foundation_bot_configs env dev restored from backup: before alethea_dev_teo_bot (2026-11-08 22:57:26), after alethea_dev_bot (2026-09-23 23:54:50). Manual Telegram test not completed.
