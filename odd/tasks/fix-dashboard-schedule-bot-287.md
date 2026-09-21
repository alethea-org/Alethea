# fix-dashboard-schedule-bot-287

Issue: alethea-org/Alethea#287 — Fallas en Dashboard al guardar horario de sesión y mensajes de bot.
Branch: `fix/dashboard-schedule-bot-287` (from origin/main @ bd76704)

## Acceptance criteria

1. `save_session_schedule` never crashes on empty/invalid time input; uses `Time.from_iso8601/1` and returns an error flash.
2. Saving a schedule recalculates `:by_day` immediately (patient moves in the week agenda without reload).
3. Bot settings `<details>` section keeps its open state across message updates (socket-bound open state).
4. Clear visual feedback when updating welcome/crisis messages (structured forms via `to_form`, flash, persisted value re-render).

## Tasks

- [x] T1 — Harden `save_session_schedule`: safe day/time parsing (`Integer.parse`, `Time.from_iso8601/1`), error flash instead of `ArgumentError`; fix time input to render empty (not `"-"`) when `session_time` is nil.
- [x] T2 — Recompute `assign(:by_day, by_day(patients))` in both mock and real success branches.
- [x] T3 — Socket-bound bot settings disclosure: `@bot_settings_open` assign, `toggle-bot-settings` event, `open={@bot_settings_open}` + summary id/hook in template.
- [x] T4 — Structured message forms: `to_form` assigns (`:crisis_form`, `:welcome_form`), `<.input type="textarea">`, rebuild form assigns after save so the saved value re-renders.
- [x] T5 — Tests: empty/invalid time → error flash, no crash; by_day relocation in week picker; settings stay open after submit; welcome/crisis feedback + persisted value.
- [ ] T6 — Verification: focused `mix test test/alethea_web/live/dashboard_live_test.exs`, then full `mix precommit`; native review under RDD.

## Edit surfaces

- `lib/alethea_web/live/dashboard_live.ex`
- `lib/alethea_web/live/dashboard_live.html.heex`
- `test/alethea_web/live/dashboard_live_test.exs`

## Notes

- Time input `<input type="time">` submits `"HH:MM"`; current code does `Time.from_iso8601!(time <> ":00")`. Keep `<> ":00"` fallback but try plain `Time.from_iso8601/1` first.
- Mock patient `p1` (Lucca) has `session_day_of_week: 1`; mock `p2` day 3, `p3` day 5 (useful for by_day test).
- Week agenda columns are 7 sibling `.ptc-day` divs (Lun=1..Dom=7) inside `.ptc-week`.
- Existing handlers `save_crisis_message`/`save_welcome_message` keep their param shape `%{"crisis_message" => msg}` / `%{"welcome_message" => msg}` (root-level anonymous forms).
- Editorial CSS only (`priv/static/assets/css/editorial.css`) — no CSS framework; `<.input>` wrapper classes may paint nothing, pass `class="text-input text-input--multiline"` explicitly.

## Verification evidence

- Focused: `mix test test/alethea_web/live/dashboard_live_test.exs` — 33 passed, 1 skipped, 0 failures.
- Full: `mix precommit` — 1312 tests + 6 doctests passed, 5 skipped, 0 failures.
- LSP: changed Elixir files — 0 diagnostics at warning-or-higher severity.
- Runtime harness: covered by `Phoenix.LiveViewTest` form submits and DOM assertions; no separate browser harness is configured for this work unit.
- Rollback boundary: revert the DashboardLive handler/form-state changes, matching HEEx form/disclosure changes, and the issue #287 regression tests together; no schema, migration, dependency, or cross-context behavior is included.

## Review status

- Native RDD review: pending after work-unit commit.

## Commits

| Task | Commit | Branch |
| ---- | ------ | ------ |
| T1–T5 | (pending) | fix/dashboard-schedule-bot-287 |
