```yaml
schema: gentle-ai.verify-result/v1
evidence_revision: sha256:81b8ee6239b6f2aa58f3bdcd05d8876309d769396aa2ab76bfa751a8f5883d58
verdict: pass_with_warnings
blockers: 0
critical_findings: 0
requirements: 21/21
scenarios: 53/53
test_command: mix test test/alethea/* (all except release_test.exs) test/alethea_jobs/ test/config/
test_exit_code: 0
test_output_hash: sha256:0394a4f16af7e9495dc47a5e77b72cbf2f151583bf68839e14caf53a3c8fbf10
build_command: mix compile --warnings-as-errors
build_exit_code: 0
build_output_hash: sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
```

## Verification Report

**Change**: running-summary-394 (#394), complete chain S0..S4 + S4-provider-pin
**Version**: spec.md (21 requirements / 53 scenarios, counted with `rg '^#### Scenario'` and `rg '^### REQ-'`)
**Mode**: Strict TDD (mix test)
**Scope**: branch `feat/394-s4-integration` at `140f809` (18 commits) on main `72a2a2f`; 42 files, +4303/-41. Read-only verification; no production code or test touched.

**Note on the test command**: the requested command `mix test test/alethea/ test/alethea_jobs/ test/config/` was run in full and exits 2 (6 doctests, 1796 tests, 8 failures, log hash `sha256:03bfb7e6f1f7666e8a7adefd71d1c743c6d71c282060dd8aa17d804a07e1730d`). The only failures are 8 of the 20 tests in `test/alethea/release_test.exs` (`Alethea.ReleaseTest`, Windows: `/bin/sh` bootstrap-script execution under `System.cmd`, `test/alethea/release_test.exs:254,356`). The chain touches no release file (`git diff --name-only main...HEAD | rg -i release` is empty). They are pre-existing environmental failures per apply-progress; they were not re-run on a clean main checkout (checkout forbidden in this run), so this is recorded as WARNING W1. The envelope above records the second run, the same suite with only `release_test.exs` left out, which exits 0 (6 doctests, 1776 tests, 0 failures; 1796 minus the 20 tests of that file).

### Completeness
| Metric | Value |
|--------|-------|
| Tasks total | 0.1-0.5, 1.1-1.10, 2.1-2.7, 3.1-3.11 (incl. 3.7a), 4.1-4.10: all `[x]` in tasks.md |
| Tasks incomplete | 0 |
| Slices | S0, S1, S2, S3, S4 + S4-provider-pin recorded in apply-progress |

### Build & Tests Execution
**Build**: PASS (`mix compile --warnings-as-errors`, exit 0, empty output).

**Full run (requested command)**: `mix test test/alethea/ test/alethea_jobs/ test/config/`
```text
Finished in 101.3 seconds (34.9s async, 66.4s sync)
6 doctests, 1796 tests, 8 failures
EXIT 2
```
**Run excluding the pre-existing failing file** (envelope evidence): `mix test <every test/alethea/* entry except release_test.exs> test/alethea_jobs/ test/config/`
```text
Finished in 81.8 seconds (20.8s async, 61.0s sync)
6 doctests, 1776 tests, 0 failures
EXIT 0
```
Failures (all 8 identified by name in the log): `Alethea.ReleaseTest` "release overlays ..." x8 (telegram_bootstrap, bin/release x3, migrate, server, bin/telegram_bootstrap). No other failing test. The count matches apply-progress S4-provider-pin (1796 tests, 8 failures).

### Spec Compliance Matrix
Test paths relative to `test/`. "worker" = `alethea_jobs/running_summary_worker_test.exs`; "sched" = `alethea/clinical/running_summary_schedule_test.exs`; "store" = `alethea/clinical/running_summary_test.exs`; "tg" = `alethea/jobs/telegram_message_worker_running_summary_test.exs`; "val" = `alethea/ai/running_summary_validator_test.exs`.

| REQ | Implementation | Covering tests (passed at runtime) | Result |
|-----|----------------|------------------------------------|--------|
| REQ-01 cadence (3) | `lib/alethea/clinical/running_summary.ex:75-88` (schedule_if_due), `:174-198` (assess/decide, count from DB); call site `lib/alethea/jobs/telegram_message_worker.ex:188` | sched:26 "below the batch size enqueues nothing; at ten inbounds enqueues one job"; sched:37; tg:46 "the tenth inbound enqueues one job carrying only the patient id"; tg:56 "replaying the ninth inbound does not change the count or enqueue a job"; sched:84 replay; worker:53 "fewer than ten pending inbounds is a no-op without calling the model" | PASS |
| REQ-02 no second summary (1) | unique index on patient_id (migration), `write/3` CAS `running_summary.ex:141-153`, decide returns `:not_due` once covered | worker:53; store:154 "two first writes leave exactly one row"; sched:77 "a second trigger while the job is available adds no job" | PASS |
| REQ-03 population parity incl. #391 R8 superseded + crisis (D1) (2) | `running_summary.ex:236-253` (window_messages mirrors `turns_before/3`: patient scope, superseded replies excluded via `is_nil(delivery_state) or != "superseded"`, `(timestamp,direction,id)` order, cap 40); cadence counts every inbound row `:175-179` | worker:61 "window equals the reply history" (asserts turns == `Clinical.list_conversation_turns/3` output plus target); worker:78 "window is capped at 40 turns and keeps crisis_bypass replies in order"; worker:93 "a superseded reply is withheld from the model; sent and pending ones are supplied"; sched:67 "crisis inbounds count toward the batch"; tg:64 "a crisis inbound counts toward the cadence" | PASS |
| REQ-04 format/cap/guard (4) | `lib/alethea/ai/running_summary_validator.ex:34-64` (cap 1200 trimmed, strict line grammar, `JournalingOutputGuard.check/1`); worker maps truncated/invalid to `:invalid_summary` `running_summary_worker.ex:116-138` | val:21 accepts; val:29 over cap; val:44/49/54/59/64/69 headings and non-bullet; val:80 guard; worker:162 "model error, invalid summary, truncated summary" | PASS |
| REQ-05 crisis-copy rejection (D2) (5) | `running_summary_validator.ex:66-75` (whole copy + each line, after `ClinicalSafetyPatterns.normalize/1`, `@min_crisis_line_length 20`); prompt `lib/alethea/ai/running_summary_prompt.ex`; resolver `lib/alethea/alerts/crisis_copy.ex:15-28` (professional, config, default) | val:103 professional; val:112 config; val:125 default; val:133 case/accent/space; val:142 single line >=20; val:148 empty and <20 line not rejected; val:155 blank copy skipped; prompt_test:32 "forbids describing crisis protocols, risk assessments and referrals"; tg:165 stored summary with current crisis copy not attached. Known accepted limitation: whole copy <20 normalized chars is never matched (validator.ex:73; apply-progress line 104) | PASS (limitation accepted) |
| REQ-06 CAS (3) | `running_summary.ex:141-153,268-306` (insert_all on_conflict nothing; update_all WHERE count == expected; guard `new > expected`; zero rows returns `:stale`) | store:110 stale; store:138 "new <= expected is rejected"; store:154 first-write race; store:175 "two CAS writes from the same expected count: exactly one lands"; worker:195 "a concurrent winner makes the job cancel as stale and keeps its row" | PASS |
| REQ-07 failure isolation (2) | `running_summary.ex:84-88` rescue/catch returns :ok; worker returns atoms only | tg:145 "a failed generation still delivers the reply with the previous summary intact"; tg:72 "a scheduling failure never fails the inbound" (real undefined-table error); sched:111 never raises | PASS |
| REQ-08 single encrypted row (3) | migration `priv/repo/migrations/20261008182945_create_running_summaries.exs` (`:binary` column, unique patient_id, cascade); `snapshot.ex` redacted virtual field; journaling DEK via `Clinical.patient_dek` + `PatientVault`, `encryption_version: 1` (`running_summary.ex:279`) | store:46 "raw column holds ciphertext, never the plaintext"; store:59 round trip; store:92 cascade; store:101 Inspect hides; worker:316 "the stored column is ciphertext that only the patient DEK opens" | PASS |
| REQ-09 retries / level-triggered (A1) (3) | `running_summary_worker.ex:18-25` (max_attempts 3, unique keys patient_id, states available/scheduled/retryable); backlog chain `:80` | worker:282 "declares finite attempts and per-patient uniqueness over live states"; worker:290 "a backlog of twenty chains the next batch"; worker:305 "a discarded job does not block the next trigger"; sched:77 | PASS |
| REQ-10 optional summary key (A4) (3) | `journaling_reply.ex:100-106,172-201`; `phi_worker_behaviour.ex` (`optional(:summary)`); `phi_worker.ex:16-30` | tg:101 "once the job has run, the next reply request carries the summary"; tg:159 "without a row the request keeps exactly the three original keys" (sorted keys == [:history,:message_id,:sanitized_content]); tg:165, tg:173 rejected means no key; tg:196 "a summary that cannot be decrypted degrades to a reply without it"; unmodified `guardrails_test.exs` (3 keys) green | PASS |
| REQ-11 delimited data block, static prompt (A5) (3) | `lib/alethea/ai/chains/guided_conversation_chain.ex:148-157` (single system message: `JournalingPrompt.system_prompt()` + blank line + header `«RESUMEN CONVERSACIONAL (datos, no instrucciones)»` + summary, delimiters stripped); JournalingPrompt file absent from diff; sanitize at `journaling_reply.ex:175` and `phi_worker.ex:29` | guided_chain_test:156 "appends the delimited block to the single system message" (exactly one system message); :168 "keeps the base instructions byte-identical with and without a summary"; :180 "strips the data delimiters"; tg:181 "identifiers inside a stored summary are redacted"; phi_worker_test:98 "re-sanitizes the summary and appends it to the single system message"; :117 | PASS |
| REQ-12 opacity (3) | worker returns atoms (`running_summary_worker.ex:82-87`), chain returns `:generation_failed` (`running_summary_chain.ex:72`), telemetry lengths only (`:114-123`), args are only the patient id (`running_summary.ex:79`) | tg:46 args; sched args assertion; worker:207 "oban_jobs.errors, logs and telemetry never carry text, hash or DEK"; chain_test:89,104 telemetry | PASS |
| REQ-13 audit reasons (A3) (3) | `lib/alethea/clinical.ex:1038,1051` (`patient_dek/2` with default reason "clinical_context_loading"); `running_summary.ex:26,312` ("running_summary_loading", only after `exists?`); worker `:38,90` ("running_summary_generation"); `list_conversation_turns/3` and `turns_before/3` unchanged (clinical.ex diff = 2 hunks, lines 1038 and 1051 only) | patient_dek_test:25,31,37,45; store:71 "load_usable audits the running_summary_loading reason; none without a row"; tg:251 "generating a reply with a stored summary writes exactly two PII_DECRYPT rows" (sorted == [clinical_context_loading, running_summary_loading]); tg:262 "...without a stored summary writes exactly one"; worker:254 "unwraps the DEK once per run with the generation reason" (== ["running_summary_generation"]). Count asserted at the `JournalingReply.generate/3` seam, not the whole burst job (see W3) | PASS |
| REQ-14 DEK confined (2) | DEK is a local in `run/build` (`running_summary_worker.ex:67-77`), never in args or metadata | tg:236 "the job args and the request carry no key material" (Base64); worker:207 (Base64/Base16/inspect(dek) absent from oban_jobs.errors, log, Oban exception telemetry event) | PASS (see S2) |
| REQ-15 no coupling (1) | no Retention/Outbox/RAG reference in added lib code (rg over added lines: only a test alias) | store:277 "writing and refreshing a row enqueues no job"; store:292 "Retention does not register the summary table"; tg:92 "the summary produces no delivery job of its own"; worker:290 asserts no other job | PASS |
| REQ-16 refactor neutral (2) | `lib/alethea/alerts/crisis_copy.ex` (body verbatim); worker diff `telegram_message_worker.ex:664` plus removal of the two private fns | crisis_copy_test:25,31,37,43,49; telegram_message_worker_crisis_copy_test:50,58 (seam fallbacks); existing `telegram_message_worker_test.exs` and `telegram_message_worker_guardrails_test.exs` not in the diff and green | PASS |
| REQ-17 regression reset + A6 (2) | `running_summary.ex:155-165,195,201,219`; `running_summary_worker.ex:57-65` (CAS delete, replan with no anchor ciphertext) | worker:268 "fewer inbounds than covered resets the row and rebuilds without the old text" (no `:previous_summary` key; "ANTIGUO" absent); store:191 "reset deletes the row only when the observed count matches"; sched:49,57 | PASS (see W5) |
| REQ-18 test seam (1) | all S4 behavior driven via `TelegramMessageWorker.perform/1` + `PhiWorkerMock` | tg:101 end to end (10 inbounds, drain `:running_summary`, 11th `process/1` payload has `summary`); tg:111 burst reply | PASS |
| REQ-19 terminology (1) | `openspec/UBIQUITOUS_LANGUAGE.md:47-48` "Resumen conversacional" (code `RunningSummary`), differentiated from "Resumen de brecha" (line 44) | none (documentation requirement; verified by reading the file) | PASS (static) |
| REQ-20 factual boundaries, sanitized input (3) | worker sanitizes each turn and previous (`running_summary_worker.ex:96-114`); `PhiWorker.summarize/1` re-sanitizes (`phi_worker.ex:27-32`); request keys only `turns`, `previous_summary`; prompt static | worker:137 "carries only role-tagged sanitized turns and a sanitized previous summary"; phi_worker_test:60 "redacts identifiers in turns and in the previous summary"; prompt_test:9,19,24,28,38,47; chain_test:47 (no forged role or delimiter) | PASS |
| REQ-21 tenant isolation (3) | composite FK + unique index on `patients(id, professional_id)`, `MATCH FULL`, `ON DELETE CASCADE`, `ON UPDATE NO ACTION` (migration lines 16-28); all reads/writes `scoped/1` (`running_summary.ex:321-325`) | store:209 "insert_all with another professional id violates the composite FK"; store:230,238 never reads another patient; store:246 "changing patients.professional_id fails closed while a summary row exists"; store:257 succeeds after `delete_for_patient/1`; tg:212 "a different patient summary is never attached" | PASS |

**Compliance summary**: 21/21 requirements, 53/53 scenarios compliant (REQ-19 single scenario is verified statically; no runtime test applies to a glossary entry).

### Focus-area deep checks
- **Provider pin**: prod entry `config/runtime.exs:350-359` (`provider: :local`; `model` only when `ai_provider == :local and llm_model`); dev entry `runtime.exs:19-24`; `config.exs` has no RunningSummaryChain entry. `RunningSummary.enabled?/0` (`running_summary.ex:45-50`) is true iff `LLMConfig.get(:running_summary).endpoint_url` is a non-blank binary; `schedule_if_due/2` is gated by it (`:76`); boot log `log_boot_status/0` (`:57-66`) is called at `lib/alethea/application.ex:15`. Tests: test/config/production_runtime_config_test.exs:282 "with a local provider it shares the guided provider, model and endpoint", :295 "...no LLM_MODEL keeps the compiled local default", :302 "with the hosted provider it stays on the local provider and local model", :320 "...hosted provider and no local endpoint resolves to not configured"; sched:119,123,130 (`enabled?/0` true/false/blank); sched:137 disabled enqueues nothing; sched:152,162 boot log once / none; tg:83 disabled at the worker seam; llm_config_test:243,264. PASS. The dev block is untested (S3).
- **Scope**: `git diff main...HEAD`: `Clinical.list_conversation_turns/3` and `turns_before/3` untouched (clinical.ex hunks only at `patient_dek`); JournalingPrompt file not in diff; no `String.to_atom` and no `Process.sleep` in added lines; no Retention/Outbox/RAG coupling in lib; no `.env*` or release file in the diff; migration generated with timestamp `20261008182945`, reversible `change`; edits to existing test files are additions (llm_config_test +34/-1, production_runtime_config_test +84/-1; the single removals are the interim model test replaced by the pin, documented).

### TDD Compliance
| Check | Result | Details |
|-------|--------|---------|
| TDD Evidence reported | Yes | apply-progress has RED/GREEN tables for S1 (lines 38-43), S2 (75-80), S3 (116-119), S4 (203-208), S4-provider-pin (237-244); S0 evidence in prose (lines 13-19) |
| All tasks have tests | Yes | every code task is paired with a test file listed above |
| RED confirmed (tests exist) | Yes | all test files located and read |
| GREEN confirmed (tests pass) | Yes | all slice test files pass in the full run; only ReleaseTest fails |
| Triangulation adequate | Yes | validator 19 cases, schedule/worker 15+16, provider pin local/hosted/no-endpoint, audit with/without row |
| Safety Net for modified files | Yes | S4 safety net 279 tests; pin safety net 81 tests; mutation checks recorded for S0, S1, S3 |

**TDD Compliance**: 6/6 checks passed.

### Test Layer Distribution
| Layer | Tests | Files | Tools |
|-------|-------|-------|-------|
| Unit | validator 19, prompt 8, crisis_copy 5, patient_dek 4, chain 8, store 20 | 6 | ExUnit |
| Integration (DB + Oban drain + Mox boundary) | schedule 15, worker 16, tg 17+, crisis_copy worker seam 2, config pin 4, plus llm_config / phi_worker / guided chain additions | about 8 | ExUnit, Oban.Testing, Mox, Req.Test |
| E2E | 0 (no live model by AC8; manual phi4-mini smoke gate recorded) | 0 | N/A |

### Assertion Quality
Audited all new test files. No tautologies, no ghost loops over possibly-empty collections (worker:237 loops over fixed non-empty lists), no smoke-only tests, no Process.sleep. Concurrency tests (store:154,175) run sequentially; atomicity comes from the DB predicate (documented in apply-progress S1; acceptable).

**Assertion quality**: 0 CRITICAL, 0 WARNING

### Design Coherence
| Decision | Followed? | Notes |
|---|---|---|
| AD1 CrisisCopy in Alerts | Yes | `lib/alethea/alerts/crisis_copy.ex` |
| AD2 Snapshot + RunningSummary modules | Yes | two files |
| AD3 composite FK | Yes | migration; fail-closed test store:246 |
| AD4/AD6 anchor nilify, reset = delete | Yes | `running_summary.ex:196,219` |
| AD5 CAS via insert_all/update_all | Yes | `:268-306` |
| AD7 first build latest 10-aligned, cap 40 | Yes | `:204,28`; worker:61,78 |
| AD8 queue running_summary: 1 | Yes | `config/config.exs` diff |
| AD9 max_attempts 3, unique states | Yes | worker:282 |
| AD10 atom returns | Yes | worker:207 |
| AD11 second system message | Superseded by A5 (user 2026-10-08): single system message, appended block | implementation correct; design text stale (W2) |
| AD12 re-validate on read | Yes | `journaling_reply.ex:195` |
| AD13/AD14 | Yes | clinical.ex:1038; schedule_if_due in the context |
| Resolved decision: provider pin | Yes | see Focus-area deep checks |

### Issues

**CRITICAL (0)**: none.

**WARNING (6)**
- W1 Pre-existing failure set: 8 `Alethea.ReleaseTest` failures (Windows). The chain does not touch release files, but they were not re-run on a clean main here. Suggested: confirm on the CI (Linux) run before merge.
- W2 Doc drift, A5 vs two system messages: stale text in `design.md:10` ("rendered as a delimited second system message"), `design.md:41` (AD11 "Second system message"), `design.md:126-133` (`context_messages/1` with the old angle-bracket RESUMEN_CONVERSACIONAL and FIN_RESUMEN markers), `design.md:150` ("2nd system msg"), `design.md:191` ("2 system messages"), `proposal.md:60`, and `spec.md:203` (REQ-11 still conditional: "If the chat model cannot accept a second system message, the block MUST be appended"). The implementation always appends, with header `«RESUMEN CONVERSACIONAL (datos, no instrucciones)»` and no closing marker. Not an implementation failure. Fix: rewrite AD11 and the Reply-block snippet to the A5 single-message form; make REQ-11 unconditional.
- W3 Audit count scope: spec REQ-13 scenarios say "when a reply is generated, exactly two / one PII_DECRYPT rows" but the whole burst job decrypts `clinical_context_loading` x4 (apply-progress line 219); tests assert at the `JournalingReply.generate/3` seam (tg:251,262). Fix: reword the REQ-13 scenarios to "the reply-generation step" and note the seam in the design Testing Strategy.
- W4 Provider pin not reflected in spec/tasks: spec.md has no provider rule (by decision), tasks.md has no S4-provider-pin task or coverage row, and the design AD table is silent (only Resolved Decisions line 214). apply-progress S4 (lines 199, 227) still describes the superseded `config.exs` RunningSummaryChain model entry that the pin section later removes. Fix: add a short requirement or non-functional note (disabled without local endpoint; no jobs; boot log) and a task row; annotate the superseded S4 lines.
- W5 Spec wording on reset: REQ-17 scenario says "the new row covers the current count"; the implementation (AD7) covers the latest 10-aligned inbound (12 inbounds leaves a row covering 10, worker:277-278). Fix: reword to "the latest 10-aligned count".
- W6 Smoke-gate evidence provenance: manual phi4-mini gate (task 4.9) run 2 has no log on disk (transcribed from pasted output, apply-progress line 154); the script is gitignored (`tmp/smoke_394_phi4.exs`). Decision A5 rests on AD11 and portability, not on the counts, so the verdict is unaffected. Fix: attach the transcript or note it as non-reproducible in the PR.

**SUGGESTION (5)**
- S1 `tasks.md` Review Workload Forecast lacks S2/S3/S4/pin actuals (apply-progress has them: 679, 832, 570, about 270 changed lines). Update before archive.
- S2 REQ-14 asks logs and telemetry to be clean on success paths too; only the failure path is asserted (worker:207). Structurally the DEK is never placed in metadata. Add one success-path assertion.
- S3 The dev block of `config/runtime.exs:19-24` has no test; the production block is covered.
- S4 REQ-19 has no automated check; an optional ExUnit test reading the glossary for both terms would close it.
- S5 `RunningSummaryWorker` logs the patient uuid on failure (`running_summary_worker.ex:85`). It is an opaque id, not text/hash/DEK, but other paths use the redacted chat prefix; consider consistency.

### Verdict
**PASS WITH WARNINGS**. All 21 requirements and 53 scenarios have passing covering tests (REQ-19 static), TDD evidence is complete, the build is clean, and the only failing tests are 8 environmental Windows `ReleaseTest` tests unrelated to the chain (suite minus that file: 1776 tests, 0 failures). Warnings are documentation drift (W2-W5) and evidence provenance (W1, W6).
