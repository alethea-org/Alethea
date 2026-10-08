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

## S2 (PR3): AI generation, uncalled from live paths

Tasks: 2.1-2.7 done. Mode: Strict TDD.

Files:
- `lib/alethea/ai/running_summary_validator.ex` (new): `validate/2`; cap 1200 (trimmed), strict line grammar (two headings in order, `- ` bullets or blanks), `JournalingOutputGuard.check/1`, crisis-copy rejection (whole copy + each copy line) after `ClinicalSafetyPatterns.normalize/1`, `@min_crisis_line_length 20`.
- `lib/alethea/ai/running_summary_prompt.ex` (new): static Spanish `system_prompt/0`.
- `lib/alethea/ai/chains/running_summary_chain.ex` (new): `[system(prompt), user(block)]` with `«RESUMEN PREVIO (datos)»` / `«TURNOS (datos)»` delimiters; `truncated` from `status == :length`; telemetry lengths/duration/success only; every failure -> `{:error, :generation_failed}`; `max_tokens: 600` via `LLMConfig` override (no config.exs edit).
- `lib/alethea/ai/llm_config.ex`: `:running_summary` in `chain_name` and `chain_module/1` (+3).
- `lib/alethea/ai/phi_worker_behaviour.ex`: `summarize/1` callback, `summarize_request`, `optional(:summary)` in `request`.
- `lib/alethea/ai/phi_worker.ex`: `summarize/1` re-sanitizes turns and `previous_summary`, delegates to the chain.
- `test/support/mocks/phi_mock.ex`: `summarize/1` stub (F3).
- Tests: `test/alethea/ai/running_summary_validator_test.exs` (19), `running_summary_prompt_test.exs` (8), `chains/running_summary_chain_test.exs` (7), `phi_worker_test.exs` +2 (`summarize/1`).

TDD cycle evidence:
| Task | RED | GREEN |
|---|---|---|
| 2.1/2.2 | `mix test test/alethea/ai/running_summary_validator_test.exs` -> 19 tests, 19 failures (module undefined) | same -> 19 tests, 0 failures (first GREEN run had 1 failure: short whole copy matched; fixed by applying `@min_crisis_line_length` to the whole copy too) |
| 2.3/2.4 | `mix test test/alethea/ai/running_summary_prompt_test.exs` -> 8 tests, 8 failures | same -> 8 tests, 0 failures (one test assertion re-scoped after the first run, see deviations) |
| 2.5/2.6 | `mix test test/alethea/ai/chains/running_summary_chain_test.exs test/alethea/ai/phi_worker_test.exs` -> 11 tests, 9 failures | same -> 11 tests, 0 failures |

Verification:
- Focused (tasks.md command): `mix test test/alethea/ai/running_summary_validator_test.exs test/alethea/ai/running_summary_prompt_test.exs test/alethea/ai/chains/running_summary_chain_test.exs` -> 34 tests, 0 failures.
- Regression: `mix test test/alethea/ai/ test/alethea/jobs/telegram_message_worker_guardrails_test.exs` -> 297 tests, 0 failures.
- `mix compile --warnings-as-errors --force` -> exit 0 (only the environmental Windows symlink :eperm warning).
- `mix format --check-formatted` clean on the 6 new files and `phi_worker_test.exs`. CRLF working copies (`llm_config.ex`, `phi_worker.ex`, `phi_worker_behaviour.ex`, `phi_mock.ex`) edited by hand preserving line endings.

`git diff --stat` (new files via `git add -N`): 11 files changed, 654 insertions(+), 3 deletions(-) = 657 changed lines. Production 262 (chain 117, validator 76, prompt 39, behaviour 15, phi_worker 12, llm_config 3); tests 395 (validator 161, chain 140, prompt 52, phi_worker_test 38, mock 4). Forecast was ~585 (prod ~270, tests ~315): production is on forecast (<300 and <x1.3); the overrun is tests only.

Deviations / flags:
- Crisis-copy min length also applies to the whole copy (design text says "whole copy or any line >= 20"): without it a short whole copy (e.g. "Hola.") false-positives, which the resolved decision wants avoided. Whole copies >= 20 chars behave as designed.
- Chain returns the opaque `{:error, :generation_failed}` instead of the raw reason (REQ-12 spirit). LangChain itself still logs "Error during chat call. Reason: ..." with the Ollama HTTP status string (no patient text); outside this slice.
- Prompt asks for max 1000 chars total to leave headroom under the 1200 validator cap.
- Prompt test asserts each heading appears exactly once plus the "exactamente estas dos secciones" phrase (a generic heading regex also matched the prompt's other colon-terminated lines).
- No `config/*.exs` change: provider/model fall back to the `LLMConfig` global defaults (`:local`, `phi4-mini`); `max_tokens` is an override in the chain.
- `PhiWorker.process/1` is untouched; the `summary` pass-through is S4.

### S2 orchestrator review fix (2026-10-08, user-approved)

- Finding: `RunningSummaryChain.user_block/2` joined turns with `"\n"` without flattening content, and the `«…»` data markers had no closing marker. A patient turn containing `"\nAlethea: …"` produced a forged `Alethea:` line (persistent prompt-injection vector into the stored summary).
- Fix: each turn is flattened to one line (`~r/\R/u` → space) and `«`/`»` are stripped from turn content and from the previous summary, so content can neither forge a role line nor open a data block.
- Evidence: RED `mix test test/alethea/ai/chains/running_summary_chain_test.exs` -> 8 tests, 1 failure (forged `Alethea:` line). GREEN -> 8 tests, 0 failures. `mix test test/alethea/ai/ test/alethea/jobs/telegram_message_worker_guardrails_test.exs` -> 298 tests, 0 failures.
- Size after fix: 679 insertions / 3 deletions (code + tests); production ~268, tests ~414. Overrun is tests → `size:exception` per the user's size rule.
- Known consequence (documented, accepted): the 20-character minimum also applies to the whole crisis copy, so a crisis copy shorter than 20 normalized characters is never matched by the validator.

## S3 (PR4): Worker + scheduling, trigger not wired

Tasks: 3.1-3.11 done (incl. 3.7a). Mode: Strict TDD. `TelegramMessageWorker` untouched.

Files:
- `lib/alethea_jobs/running_summary_worker.ex` (new): queue `:running_summary`, `max_attempts: 3`, unique `keys: [:patient_id]`, `period: :infinity`, states `[:available, :scheduled, :retryable]`. Flow: `plan/1` -> (reset: CAS delete, replan without previous text) -> `patient_dek(patient, "running_summary_generation")` -> `window_turns/3` + previous summary decrypt -> `Sanitizer` -> `summarize/1` (rescue/catch to atom) -> `RunningSummaryValidator` vs `CrisisCopy.reply_text/1` -> `PatientVault.encrypt` under the same DEK -> `RunningSummary.write/3` (ciphertext). Returns `:ok | {:cancel, :stale} | {:error, :generation_failed | :invalid_summary | :persist_failed}`; truncated -> `:invalid_summary`. Success calls `schedule_if_due/2` (backlog chain).
- `lib/alethea/clinical/running_summary.ex`: `schedule_if_due/2` (never raises; logs atom + 8-char chat prefix only), `plan/1` (counts only, no decrypt), `window_turns/3`, private `assess/decide/target_plan/window_messages`. Plan type extended with optional `lower_bound`, `anchor_ciphertext`. CRLF preserved.
- `config/config.exs`: Oban queue `running_summary: 1` with the global-limit comment. `config/test.exs` already `testing: :manual`; `Oban.drain_queue(queue: :running_summary)` works.
- Tests: `test/alethea/clinical/running_summary_schedule_test.exs` (9), `test/alethea_jobs/running_summary_worker_test.exs` (16), helper `test/support/running_summary_helper.ex`.

TDD evidence:
| Tasks | RED | GREEN |
|---|---|---|
| 3.1-3.7a / 3.8-3.10 | `mix test test/alethea_jobs/running_summary_worker_test.exs test/alethea/clinical/running_summary_schedule_test.exs` -> 24 tests, 24 failures (worker module and `schedule_if_due`/`plan` undefined) | same command -> 25 tests, 0 failures (the 25th is the superseded-reply test added after the coordinator correction, written after the first RED run; its RED is the mutation below) |

Mutation check: deleting the `delivery_state != "superseded"` predicate from the window query -> 16 worker tests, 1 failure (superseded test); restored.

Verification:
- `mix test ... running_summary_worker_test.exs running_summary_schedule_test.exs running_summary_test.exs` -> 45 tests, 0 failures.
- `mix test test/alethea/clinical/ test/alethea/ai/ test/alethea/jobs/ test/alethea_jobs/` -> 4 doctests, 557 tests, 2 failures, both in `clinical_record_outbox_worker_test.exs` (`column "audio_start_seconds" of relation "clinical_record_rag_chunks" does not exist`): pre-existing test-DB schema drift unrelated to S3 (untouched code path).
- `mix compile --warnings-as-errors --force` -> ok (only the environmental Windows symlink :eperm warning).
- `mix format` applied to the 4 LF new files and to `running_summary.ex` (converted to LF, formatted, restored to CRLF). `config.exs` edited in place, CRLF kept.

`git diff --stat` (new files via `git add -N`, then reset): 6 files, 827 insertions(+), 5 deletions(-) = 832 changed lines. Production 313 (running_summary.ex 158 incl. rewritten lines, worker 148, config 7); tests 519 (worker test 337, schedule test 134, helper 48). Forecast ~650 (prod ~250, tests ~400). Production is ABOVE the ~300 stop line and above 250 x 1.3 = 325? No: 313 < 325, but > 300. Flagged to the orchestrator per the size rule; not self-authorized.

Deviations / flags:
- Coordinator correction applied: the window query mirrors `turns_before/3` exactly (patient scope + `is_nil(delivery_state) or != "superseded"` + `(timestamp, direction, id)` order), bound inclusive of the target inbound. Test: a `superseded` reply is withheld, `sent`/`pending` replies are supplied. Cadence counts inbound rows only (unaffected).
- "Never raises when `Oban.insert` raises/errors" is tested with a malformed patient id (real `Ecto.Query.CastError` rescued) and an unknown patient; `Oban.insert` itself is not stubbed.
- DEK unwrap or window/previous-summary decrypt failures map to `:generation_failed`; encrypt and DB write failures to `:persist_failed`.
- Worker catches exceptions from `summarize/1` into `:generation_failed` so exception messages never reach `oban_jobs.errors`.
- Extra production vs design: `Repo.get_by` anchor lookup returns `{:reset, covered}` when the anchor message is gone (race), consistent with AD4.

## S4 (PR5): Integration — pre-apply gate (task 4.9, design AD11)

### Manual phi4-mini smoke test

Script: `tmp/smoke_394_phi4.exs` (gitignored, synthetic data, no DB writes). It captures the exact HTTP payload sent to Ollama *after* LangChain/`OllamaChat` build it (Req plug proxy) and runs each case once at the configured temperature (0.0) and 3 times at 0.7, in two layouts: `two_system` (summary as a second system message) and `appended` (A5: summary block appended to the single system message). Model `phi4-mini`, endpoint `http://localhost:11434`, chain temperature 0.0, `max_tokens` 160.

**Run 1** (`tmp/smoke_394_run1.log`, 2026-10-08, branch `feat/394-s4-integration`):

| Case | two_system | appended (A5) |
|---|---|---|
| Payload: summary block present where the layout says | 16/16 | 16/16 |
| 1 · normal summary (no clinical words, ≤1 question) | 4/4 | 4/4 |
| 2 · injected instruction — runs that obey it | 0/4 | 0/4 |
| 3 · direct recall question ("marzo") | 2/4 (both at 0.7) | 0/4 (1 run mentioned the adoption without "marzo") |
| 4 · natural summary-only reference ("Toby"/"marzo") | 4/4 | 3/4 (0.7 sample 2 missed) |

**Run 2** (`tmp/smoke_394_run2.log`): pending — log not yet provided. Per the user, case 4 inverts between runs; record the run 2 table here when the log is available.

Notes:
- Case 3 is discarded as a test: `JournalingPrompt` is a journaling companion, not a Q&A assistant, so it reflects on the current message instead of answering recall questions. The case also leaked summary facts (Toby, plaza) into the current message (test-design flaw).
- At temperature 0.0 both layouts produced word-for-word identical replies in cases 1 and 2; the captured payloads prove the block was present in both, so the summary simply did not change those replies.

### Decision (user, 2026-10-08): A5 — summary block appended to the single system message

Rationale: design rule AD11 (any failure or doubt in `two_system` → A5) and portability across models (a second system message is model/template-dependent; one system message is not). `JournalingPrompt` stays static; the block is appended at runtime inside the chain.

Also in S4 scope (user, 2026-10-08): `:running_summary` reads the same `LLM_MODEL` as `GuidedConversationChain` (default `phi4-mini`), so replies and summaries never run on different models.

### Observations (out of scope, not filed)

Journaling prompt (#392), seen during the smoke test:
1. **Recall questions.** Asked "¿te acordás…?", the bot sidesteps and reflects on the current message. With A5, 0/4 runs used the summary-only fact. Once the summary exists, this may read as a lack of memory to the patient.
2. **Two questions in one reply.** One run at temperature 0.7 (appended layout, case 3 sample 2) asked two questions. Config uses 0.0; `JournalingOutputGuard` does not check question count.
3. **"tú" vs. voseo.** `JournalingPrompt` says "Trata a la persona de 'tú'", so voseo patients ("¿te acordás?") get "tú" replies. May be deliberate.

Environment (not #392): `docker-compose.yml:33` defaults `LLM_MODEL` to `phi-4-mini` (hyphen) while the Ollama tag and code defaults are `phi4-mini`.
