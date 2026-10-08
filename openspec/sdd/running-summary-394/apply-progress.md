# Apply Progress: running-summary-394

## S0 (PR1): Crisis-copy resolver extraction

Tasks: 0.1, 0.2, 0.3, 0.4 (replaced, see deviations), 0.5 done.

Files:
- `lib/alethea/alerts/crisis_copy.ex` (new): `reply_text/1`, `default_support_message/0`, body verbatim from worker.
- `test/alethea/alerts/crisis_copy_test.exs` (new): 5 characterization tests (professional message, "" passthrough, app env, default, default fn).
- `test/alethea/jobs/telegram_message_worker_crisis_copy_test.exs` (new): 2 worker-seam tests through `perform/1` with a professional whose `crisis_message` is `nil` (config text; system default).
- `lib/alethea/jobs/telegram_message_worker.ex`: alias `CrisisCopy`, call `CrisisCopy.reply_text/1`, removed private resolver (+2/-19).

Evidence:
- RED: `mix test test/alethea/alerts/crisis_copy_test.exs` -> 5 tests, 5 failures (module missing).
- GREEN: `mix test test/alethea/alerts/crisis_copy_test.exs test/alethea/jobs/telegram_message_worker_crisis_copy_test.exs test/alethea/jobs/telegram_message_worker_test.exs` -> 56 tests, 0 failures.
- Worker-seam tests are characterization tests (green on first run). Mutation check: forcing a non-nil value ahead of the fallback chain in `CrisisCopy.reply_text/1` -> 2 tests, 2 failures; source restored and re-verified.
- `mix compile --warnings-as-errors --force` -> ok (only pre-existing Windows symlink :eperm LiveView warning, environmental).
- `mix format --check-formatted` on the 3 new files -> clean.
- Existing worker test file untouched.

Changed lines (code + tests): 236 insertions / 19 deletions — production ~32 lines (`crisis_copy.ex` + worker), tests ~185 lines. Above the S0 attempt cap of 150 because of the added worker-seam test file; within the 400-line review budget.

Deviations:
- 0.4 replaced (user, 2026-10-08): the original equality test (worker-resolved text == `CrisisCopy.reply_text/1`) is tautological after the extraction. Replaced by the worker-seam fallback tests above, which close design finding F2.
