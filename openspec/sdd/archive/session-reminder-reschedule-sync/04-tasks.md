# Tasks — session-reminder-reschedule-sync (#102)

**Delivery:** single PR (~40-70 authored lines). **400-line budget risk: Low.** No chaining. Strict TDD (RED → GREEN → refactor).

## T1 — RED · `test/alethea_jobs/session_reminder_worker_test.exs` [x]
Add `describe "cancel_pending/1"`:
- (a) happy path: enqueue a real `SessionReminderWorker` job (future `scheduled_at`, args with `patient_id`) for patient A → `cancel_pending(A.id)` → assert `Oban.Job.state == "cancelled"`, returns `{:ok, 1}`.
- (b) scoping: enqueue for A + B → `cancel_pending(A.id)` → A cancelled, B still `"scheduled"`.
- (c) worker-string pin: assert the enqueued job's `worker` field literal-equals `"AletheaJobs.SessionReminderWorker"`.
Confirm RED (`UndefinedFunctionError`). Blocks T2.
**DONE** — RED confirmed: 3 failures (`UndefinedFunctionError`); (c) passed trivially (doesn't call `cancel_pending/1`).

## T2 — GREEN · `lib/alethea_jobs/session_reminder_worker.ex` [x]
Implement `cancel_pending/1` per locked design (`import Ecto.Query`, direct `Oban.cancel_all_jobs/1`, no mockable wrapper — D3). Run T1 green.
**DONE** — GREEN: 8/8 in `session_reminder_worker_test.exs`. **@spec narrowed to `{:ok, non_neg_integer()} | ` DROPPED `{:error, term()}`** — see Deviation note below.

## T3 — RED (scenario coverage) · same describe block [x]
Add the *"No pending reminder exists"* case: `cancel_pending/1` on a patient with no job → no error, no state change for others. (Authored with the T1 batch.)
**DONE** — included in the T1 batch; passes with T2's implementation.

## T4 — RED · `test/alethea_web/live/dashboard_live_test.exs` [x]
New real-mode (`use_mock_data: false`) test: build a real patient (mirror `insert_legacy_patient` from `telegram_message_worker_reminder_test.exs` — professional + KEK + `Accounts.create_patient`), enqueue a `SessionReminderWorker` job, render `DashboardLive`, fire `save_session_schedule`, assert the job is cancelled AND the success flash is present. Confirm RED (call site not wired). Depends on T2.
**DONE** — RED confirmed: job state stayed `"scheduled"` (assertion failure), flash passed.

## T5 — GREEN · `lib/alethea_web/live/dashboard_live.ex` (~:146-156) [x]
In the `{:ok, updated_patient}` branch only (mock branch `:130-144` untouched): after `Accounts.update_patient_session_schedule/3` succeeds, best-effort cancel call, then proceed to the existing flash/assign flow unconditionally. Add `require Logger` if absent. Depends on T4.
**DONE** — implemented as `try/rescue` instead of the locked `case {:ok,_}/{:error,_}` snippet — see Deviation note below. GREEN: 7/8 (1 skip, pre-existing) in `dashboard_live_test.exs`.

## T6 — OPTIONAL · best-effort error path [ ]
`ExUnit.CaptureLog` around a forced `{:error, reason}` branch. Oban OSS `cancel_all_jobs/1` has no injectable failure mode (D3) — may be untestable; if skipped, note as accepted gap for the reviewer, not a blocker.
**SKIPPED** — accepted gap per D3/T6, confirmed untestable (see Deviation note: the `{:error, _}` shape is now known to be statically unreachable, not merely hard to trigger).

## T7 — FINAL · `mix precommit` green [x]
compile `--warnings-as-errors`, `format`, full test. Gate for PR.
**DONE** — `mix precommit` exit 0: 576 passed (6 doctests, 570 tests), 5 skipped (pre-existing skips, unrelated to this change).

## Deviation from locked design (D3 code shape)

Elixir 1.20's set-theoretic type checker (`mix compile --warnings-as-errors`) proved the `{:error, reason}` branch in the locked D3 snippet is **statically unreachable**, not just hard to trigger in tests:
- `Oban.cancel_all_jobs/1`'s own `@spec` (Oban 2.22, `deps/oban/lib/oban.ex:1475`) is `{:ok, non_neg_integer()}` — no error union.
- Its `Engine.cancel_all_jobs/2` callback contract (`deps/oban/lib/oban/engine.ex:137`) is `{:ok, [map()]}` — also no error union. A genuine failure (e.g. DB down) raises, it never returns an error tuple.

Fix applied (functionally equivalent intent, compiles clean):
- `AletheaJobs.SessionReminderWorker.cancel_pending/1` `@spec` narrowed to `{:ok, non_neg_integer()}` (matches actual Oban contract).
- `DashboardLive`'s call site uses `try/rescue` instead of `case {:ok,_}/{:error,_}` — genuinely catches exceptions (the only real failure mode) and still logs + never breaks the save UX, satisfying spec scenario "no error is raised to the caller."
- This also confirms T6 was correctly marked optional/likely-skip by the design: the error path is not just "OSS has no injectable failure mode," it is compiler-proven dead code for the tuple shape.

## Ordering
Strict chain: T1 → T2 → T4 → T5 → T7. T3 rides with T1. T6 the only independently assignable task.

## Review Workload Forecast
- Changed lines: ~40-70 authored (400-budget risk **Low**).
- Files: 2 source (`session_reminder_worker.ex`, `dashboard_live.ex`) + 2 test files.
- Reviewer note: T1c worker-string literal is a silent fail-open pin (renaming the worker breaks cancellation with no compile error) — call out in the PR.
- No migration, no schema, no new config.
