```yaml
schema: gentle-ai.verify-result/v1
evidence_revision: sha256:0f7f4be83d3cb28a7d9ef8f850495bf766b820cfa35be38a9e93373167dba074
verdict: pass_with_warnings
blockers: 0
critical_findings: 0
requirements: 22/22
scenarios: 57/57
test_command: mix test test/alethea/* (all except release_test.exs) test/alethea_jobs/ test/config/
test_exit_code: 0
test_output_hash: sha256:05ad99391fe542aeabfaead6b101773b07e567824ab53a221299f1ff8d489ae4
build_command: mix compile --warnings-as-errors
build_exit_code: 0
build_output_hash: sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
```

## Verification Report (second pass)

**Change**: running-summary-394 (#394), complete chain S0..S4 + S4-provider-pin + S4-cloud-gate
**Version**: spec.md at e2510ee (22 requirements / 57 scenarios; counted with rg on the REQ and Scenario headings)
**Mode**: Strict TDD (mix test)
**Scope**: branch `feat/394-s4-integration` at `e2510ee` on main `72a2a2f`. Read-only; no production code or test touched. Only this report was written.

### Previous run (4256f75)
PASS WITH WARNINGS, W1-W6. Resolution:
- W1 ReleaseTest baseline: still open (same 8 Windows failures, see below).
- W2 A5 doc drift: resolved in spec.md:203, design.md:10 and :150, proposal.md:60, tasks.md:89. One stale snippet remains at design.md:130 (S-1 below).
- W3 REQ-13 audit wording: resolved at spec.md:235 (counts are per generate/3 or generate_burst/2 reply generation; the burst save path is outside the counts).
- W4 Provider pin missing from spec: resolved by REQ-22 (spec.md:341-362) and design.md:214. tasks.md still has no pin/REQ-22 row (W-A below).
- W5 REQ-17 wording: resolved at spec.md:288 (latest 10-aligned patient inbound; 12 inbounds rebuild to a row covering 10).
- W6 smoke run 2 has no log: unchanged, accepted and downgraded to SUGGESTION (the decision rests on AD11 and portability, not on counts).

### Completeness
All tasks 0.1-4.10 are `[x]` in tasks.md; 0 incomplete. Slices S0-S4, S4-provider-pin and S4-cloud-gate are recorded in apply-progress (lines 229-258).

### Build and tests
- `mix compile --warnings-as-errors`: exit 0, empty output (hash e3b0...b855). A forced recompile printed only the pre-existing Windows node_modules symlink eperm notice from Phoenix.LiveView.ColocatedJS (environmental, not a project warning).
- Requested command `mix test test/alethea/ test/alethea_jobs/ test/config/`: **6 doctests, 1803 tests, 8 failures, exit 2** (log hash `sha256:c9d2c903d477467ee43411dc5276cade566d9edfaed13f8b0d93ccfe2fcb0b54`). All 8 failures are `Alethea.ReleaseTest` "release overlays ..." (telegram_bootstrap, bin/release x3, migrate, server, bin/telegram_bootstrap; POSIX sh scripts under System.cmd on Windows). No other failure. Pre-existing: the file is untouched by the chain and the count equals the previous pass.
- Same suite excluding `release_test.exs`: **6 doctests, 1783 tests, 0 failures, exit 0** (log hash `sha256:05ad99391fe542aeabfaead6b101773b07e567824ab53a221299f1ff8d489ae4`). 1803 minus 20 release tests = 1783. Previous pass was 1796/1776; the +7 tests are the REQ-22 additions.

### REQ-22 (new) deep check
Gate: `lib/alethea/clinical/running_summary.ex:48` `enabled?` = `local_endpoint?() and local_replies?()`; `local_endpoint?` (`:77-82`) needs a non-blank binary `LLMConfig.get(:running_summary).endpoint_url`; `local_replies?` (`:84`) needs `LLMConfig.get(:guided_conversation).provider == :local`.

| Property | Evidence | Tests (passed) |
|---|---|---|
| No summary key in process/1 payload with chain :cloud + local endpoint + stored row | `lib/alethea/telegram/journaling_reply.ex:193` the `enabled?` check is the first clause of `load_summary/1`; the `:none` result leaves the request untouched (`:177-178`) | `test/alethea/jobs/telegram_message_worker_running_summary_test.exs:251` (keys sorted == [:history, :message_id, :sanitized_content]) |
| No PII_DECRYPT running_summary_loading | `enabled?` runs before `exists?` (`:196`) and `load_usable` (`:197`), so no DEK unwrap | same test: refute running_summary_loading in the audit delta |
| No RunningSummaryWorker job | `schedule_if_due/2` first clause `with true <- enabled?()` (`running_summary.ex:94`); call site `telegram_message_worker.ex:188`; the worker chained next batch (`running_summary_worker.ex:80`) goes through the same `schedule_if_due` | tg:263 "ten inbounds enqueue no summary job while replies use the hosted model"; `running_summary_schedule_test.exs:123,130` |
| Local mode unchanged | same payload test flips back to local | tg "the same stored summary is attached once replies are local again"; sched:118-120 |
| No endpoint -> disabled, boot log | `running_summary.ex:58-62` (no endpoint) and `:64-68` (hosted): distinct one-line messages with no patient data; called at `application.ex:14` | sched:119-137, 152, 162; tg:83 |
| Provider pin | `config/runtime.exs:350-359` provider `:local` plus model only if `ai_provider == :local and llm_model`; dev `:19-24`; no entry in `config.exs` | `test/config/production_runtime_config_test.exs:282,295,302,321,331` (321 asserts enabled? true for local, false for hosted and for hosted without endpoint) |

**Exhaustive reader audit** (rg for load_usable, exists?, RunningSummary., :summary, GuidedConversationChain.run, .process( over lib/):
- `load_usable/1`: defined `running_summary.ex:144`; sole caller `journaling_reply.ex:197`, behind the `enabled?` gate. `exists?/1`: sole caller `journaling_reply.ex:196`, behind the gate.
- The `summary:` key into `process/1` is set only at `journaling_reply.ex:175`; the only `ai_worker().process` call site is `journaling_reply.ex:108`.
- `GuidedConversationChain.run/1`: sole caller `phi_worker.ex:25`; `put_summary` (`:37`) reads only `request.summary`, which only `journaling_reply.ex:175` sets.
- Remaining `RunningSummary.*` callers (`running_summary_worker.ex:49-97`, `telegram_message_worker.ex:188`) are generation-side and call `RunningSummaryChain` (pinned `:local`), never the reply chain. A job enqueued before a config flip still only reaches the local chain.
- `lib/mix/tasks/alethea.demo.process.ex:35` `DemoProcessor.process/2` is an unrelated demo path with no summary key.

No other code path can send the stored summary to a hosted model.

### REQ-01..REQ-21 re-check
Lib changes since the previous pass are confined to `running_summary.ex` (enabled?, log_boot_status) and `journaling_reply.ex` (load_summary gate); the suite is green apart from ReleaseTest. Mapping and test lines are as in the previous report (not repeated).

| REQ | Result | REQ | Result | REQ | Result |
|---|---|---|---|---|---|
| 01 cadence | PASS | 09 retries | PASS | 17 reset (spec wording fixed) | PASS |
| 02 single summary | PASS | 10 optional key | PASS (now gated by REQ-22) | 18 test seam | PASS |
| 03 population parity | PASS | 11 data block (now unconditional) | PASS | 19 terminology | PASS (static) |
| 04 format/cap/guard | PASS | 12 opacity | PASS | 20 sanitized input | PASS |
| 05 crisis-copy rejection | PASS (accepted limitation) | 13 audit reasons (per-reply wording) | PASS | 21 tenant isolation | PASS |
| 06 CAS | PASS | 14 DEK confined | PASS | 22 no hosted model | PASS |
| 07 failure isolation | PASS | 15 no coupling | PASS | | |
| 08 encrypted row | PASS | 16 refactor neutral | PASS | | |

REQ-10 and REQ-13 positive tests still pass because the test default guided provider is local.

### Scope checks
- `git diff main...HEAD -U0 -- lib/alethea/clinical.ex`: hunks only at lines 1038 and 1051 (`patient_dek`); `list_conversation_turns/3` and `turns_before/3` untouched.
- `git diff --name-only main...HEAD` filtered for retention, outbox, rag, .env, journaling_prompt: empty. Added lib lines contain no Retention, Outbox, String.to_atom or Process.sleep.

### TDD compliance
apply-progress records RED/GREEN evidence for S4-provider-pin and S4-cloud-gate (line 258 and the preceding tables). REQ-22 tests are triangulated (hosted payload, local-again, ten inbounds, enabled? matrix, config matrix of three cases). 6/6 checks hold. Assertion quality: 0 findings; the hosted payload test asserts the exact key set and the audit delta.

### Issues
**CRITICAL (0)**: none.

**WARNING (3)**
- W-1 (was W1) Eight pre-existing `Alethea.ReleaseTest` failures on Windows; the chain touches no release file. Confirm on the Linux CI run before merge.
- W-A tasks.md has no row for S4-provider-pin / S4-cloud-gate and its coverage table (near tasks.md:121) has no REQ-22 line, although apply-progress records the work. Fix: add task rows and a REQ-22 coverage line.
- W-B spec.md:364 `#### Scenario: Professional change fails closed` (the third scenario of REQ-21) now sits under `### REQ-22` after the insertion at spec.md:341. Counts are unaffected (57) but the scenario is misattributed. Fix: move it above `### REQ-22`.

**SUGGESTION (6)**
- S-1 design.md:130 still shows the superseded second-system-message snippet with the old angle-bracket markers; mark it superseded like lines 10 and 150 (design.md:191 and exploration.md:74 also mention the old layout).
- S-2 (was W6) smoke run 2 has no log on disk (`tmp/smoke_394_phi4.exs` is gitignored); note it as non-reproducible in the PR.
- S-3 tasks.md Review Workload Forecast lacks S2/S3/S4/pin actuals.
- S-4 REQ-14 success-path log/telemetry cleanliness is asserted only on the failure path.
- S-5 Dev block of `config/runtime.exs:19-24` untested; REQ-19 has no automated check.
- S-6 `RunningSummaryWorker` logs the patient uuid on failure (`running_summary_worker.ex:85`); other paths use the redacted prefix.

### Verdict
**PASS WITH WARNINGS**. REQ-22 holds with runtime evidence and a closed reader audit; all 22 requirements and 57 scenarios are covered by passing tests (REQ-19 static); build clean; only the 8 known Windows ReleaseTest failures remain (suite minus that file: 1783 tests, 0 failures).
