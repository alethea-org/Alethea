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

## S1 (PR2): Storage, composite tenant FK, `patient_dek/2`, context API

Tasks: 1.1-1.10 done (1.10 gate flagged: size over budget, see below). Mode: Strict TDD.

Files:
- `priv/repo/migrations/20261008182945_create_running_summaries.exs` (new, via `mix ecto.gen.migration`): unique index `patients(id, professional_id)`; `running_summaries` with composite FK `MATCH FULL`, `ON DELETE CASCADE`, `ON UPDATE NO ACTION`; `encrypted_summary :binary`; unique `patient_id`; CHECK `covered_inbound_count > 0`; `covered_through_message_id` nilify FK.
- `lib/alethea/clinical.ex`: `patient_dek(patient, reason \ "clinical_context_loading") when is_binary(reason)`; only `details.reason` changed (+2/-2).
- `lib/alethea/clinical/running_summary/snapshot.ex` (new): schema, `@derive {Inspect, except: [:summary, :encrypted_summary]}`, redacted virtual `summary`, no changeset (no cast of programmatic fields).
- `lib/alethea/clinical/running_summary.ex` (new): `exists?/1`, `load_usable/1` (audit `running_summary_loading`, `:none` without DEK unwrap), `write/3` (CAS via `insert_all on_conflict: :nothing` / `update_all`), `reset/2`, `delete_for_patient/1`.
- `test/alethea/clinical_patient_dek_test.exs` (new, 4 tests), `test/alethea/clinical/running_summary_test.exs` (new, 20 tests).
- 1.9: `openspec/UBIQUITOUS_LANGUAGE.md` lines 44-48 already define "Resumen conversacional" (`RunningSummary`) and "Resumen de brecha"; no edit.

TDD cycle evidence:
| Task | RED | GREEN |
|---|---|---|
| 1.2/1.3 | `mix test test/alethea/clinical_patient_dek_test.exs` -> 4 tests, 3 failures (`patient_dek/2` undefined; default-reason test is a characterization and passed) | same command -> 4 tests, 0 failures |
| 1.4-1.7/1.8 | `mix test test/alethea/clinical/running_summary_test.exs` -> CompileError (`Snapshot` struct / `RunningSummary` undefined) | same command -> 20 tests, 0 failures |

Mutation check: dropping the professional scope in `scoped/1` and the CAS `where` in the incremental update -> 20 tests, 3 failures (stale, forged-professional, two-CAS); source restored, re-verified green.

Verification:
- Focused: `mix test test/alethea/clinical/running_summary_test.exs test/alethea/clinical_patient_dek_test.exs` -> 24 tests, 0 failures.
- Existing callers: `mix test test/alethea/clinical_test.exs test/alethea/jobs/` -> 158 tests, 0 failures.
- `mix compile --warnings-as-errors --force` -> ok (only the environmental Windows symlink :eperm LiveView warning).
- `mix ecto.migrate` -> `mix ecto.rollback --step 1` -> `mix ecto.migrate`: all clean (dev DB).
- `mix format --check-formatted` clean on the 5 new files. `lib/alethea/clinical.ex` fails the check only because the working copy is CRLF (pre-existing: HEAD version fails identically); edited by hand, 2 lines.

`git diff --stat` (new files via `git add -N`): 6 files changed, 576 insertions(+), 2 deletions(-) = 578 changed lines (prod 224, tests 352).

Deviations / flags:
- SIZE: 578 changed lines vs the ~380 forecast and the ~420 hard stop. Cause: formatter-expanded test file (304 lines) and an extra 48-line DEK test file. Not self-authorized as `size:exception`; orchestrator decides (trim tests, split, or accept).
- `write/3` returns `{:error, :persist_failed}` for `new <= expected` (design left this atom open) and for rescued DB errors.
- "Concurrent" CAS tests (2 first writes, 2 CAS from same expected) run sequentially against the DB; atomicity comes from the unique index / `WHERE` predicate, so the second call deterministically loses.
- Extra tests beyond tasks: forged-professional patient struct reads nothing; `load_usable` decrypt failure returns an atom error; `reset/2` CAS.
