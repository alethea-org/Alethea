```yaml
schema: gentle-ai.verify-result/v1
evidence_revision: sha256:b056b445742e80cd1a4af7227795fc8241122d025aa772ed4b68d634aee8ef6c
verdict: fail
blockers: 1
critical_findings: 1
requirements: 3/4
scenarios: 6/7
test_command: mix precommit
test_exit_code: 0
test_output_hash: sha256:07d917ec353a4dbfe3a98b321f0112a0800cab340a9e2daef3e2e5cb388fa920
build_command: mix compile --warnings-as-errors
build_exit_code: 0
build_output_hash: sha256:62ac10239807a71149064330c2cfc045f7688ae6bf5d9baefd67a2452e47789a
```

# Verify report — session-timeout-channel-neutral (#86) PR-1

**Verdict:** FAIL
**Date:** 2026-07-22
**Implementation commit:** 44841ed
**PR scope:** Goal 1 (Channel-Neutral SessionTimeoutWorker + Telegram enqueue)
**Out of scope for this verify:** PR-2 (Crisis-Path Transactional Atomicity)
**Mode:** Strict TDD

## Summary

- 1 CRITICAL / 6 WARNING / 1 SUGGESTION
- The successful paths are implemented coherently: Telegram timeout args round-trip through Oban as string-keyed JSON, the worker closes through the shared summary/trends pipeline, Telegram goodbye dispatch enqueues the expected outbound worker, legacy WhatsApp calls remain compatible, and one Telegram enqueue call site covers safe and crisis branches. All focused and full test commands pass.
- Verification nevertheless FAILS because the required renewal invariant is false after the worker's 40-minute uniqueness window. A runtime probe reproduced two still-scheduled timeout rows with identical args after the original row's `inserted_at` aged 41 minutes; the committed renewal test only proves immediate deduplication and does not assert a pushed-out `scheduled_at`.
- The retrieved spec contains 7 requirements and 12 scenarios in total. PR-1 scope is 4 requirements and 7 scenarios; PR-2's remaining 3 requirements and 5 scenarios were not evaluated.

## Completeness

| Metric | Value |
|---|---:|
| PR-1 task checkboxes in `tasks.md` | 18 |
| Empirically complete | 17 |
| Partial | 1 (`3.3`, renewal coverage/behavior) |
| Missed | 0 |
| Source checkboxes marked complete | 0/18 (artifact drift; see WARNING-6) |
| Scoped requirements complete | 3/4 |
| Scoped scenarios compliant | 6/7 |

The implementation commit changes 4 files with 325 insertions and 8 deletions: 333 authored changed lines, within the 400-line review budget. `git diff --check 44841ed^ 44841ed` passed.

## Requirement-by-requirement validation

### Requirement: Channel-Neutral Timeout Dispatch

- Scenario: Telegram session times out → **PASS** — `SessionTimeoutWorker.perform/1` matches Oban's string-keyed Telegram shape (`lib/alethea_jobs/session_timeout_worker.ex:38-58`), runs the shared close/summary/trends pipeline (`:82-108`), and dispatches through `TelegramOutboundWorker` (`:124-138`). The Telegram test executes the complete flow and verifies the enqueued `chat_id`, `chat_id_hash`, `patient_id: nil`, and goodbye body (`test/alethea_jobs/session_timeout_worker_test.exs:147-194`). The focused suite passed 4/4.
- Scenario: Session already closed (idempotency) → **PASS** — the Telegram clause returns `:ok` before analysis or delivery (`session_timeout_worker.ex:47-57`). The test explicitly sets zero-call expectations for RoBERTa, summary generation, and WhatsApp, and refutes Telegram enqueue (`session_timeout_worker_test.exs:196-220`).

### Requirement: WhatsApp Backward Compatibility

- Scenario: Legacy WhatsApp args, no channel key → **PASS** — the legacy clause accepts string-keyed `session_id`, `patient_id`, and `phone`; `Map.get(args, "channel", "whatsapp")` defaults an absent key to WhatsApp (`session_timeout_worker.ex:64-80`). The existing success test passes this exact legacy shape and verifies the WhatsApp goodbye plus persisted close/trends/summary (`session_timeout_worker_test.exs:57-101`).
- Scenario: Existing WhatsApp tests remain green → **PASS** — the commit diff adds only a Telegram alias before the old tests and a new describe block after them; the bodies of the two pre-existing tests (`session_timeout_worker_test.exs:57-118`) are bit-for-bit unchanged. Both passed within the 4-test focused run.

### Requirement: Telegram Timeout Job Args

- Scenario: Telegram job carries routing identifiers → **PASS** — `schedule_telegram_session_timeout/4` builds atom-keyed input args containing `channel`, `chat_id`, and `chat_id_hash` (`lib/alethea/jobs/telegram_message_worker.ex:341-354`); Oban persists and rehydrates them as string-keyed JSON. The safe-path test reads the stored `Oban.Job` and asserts all three fields plus binary session/patient identifiers (`test/alethea/jobs/telegram_message_worker_test.exs:446-471`).

### Requirement: Telegram Timeout Enqueue On Inbound Save

- Scenario: Safe-path message renews timeout → **CRITICAL** — immediate deduplication works, but the stated invariant does not hold for every inbound message. `SessionTimeoutWorker` uses `unique: [fields: [:args], period: 40 * 60]` without `timestamp: :scheduled_at` (`session_timeout_worker.ex:2-5`), so Oban 2.22.1 applies the period to `inserted_at`. The committed test (`telegram_message_worker_test.exs:495-544`) asserts only one row and stable args for two immediate calls; it never asserts that `scheduled_at` moved. A runtime probe showed:
  - within the uniqueness window: second insert `conflict?: true`, count = 1, and `scheduled_at` was replaced;
  - after aging the original row's `inserted_at` by 41 minutes while leaving it scheduled in the future: next insert `conflict?: false`, count = 2.
  This violates `spec.md:53-59` and can produce two close jobs during a long conversation after an earlier renewal pushes the first timeout beyond the original uniqueness horizon. Fix the uniqueness policy (for example, evaluate against `scheduled_at`, or use an infinite period limited to incomplete states) and add a runtime test that crosses the 40-minute boundary while asserting both row count and a strictly later `scheduled_at`.
- Scenario: Crisis-path message also enqueues/renews timeout → **PASS** — the only production call is immediately after successful inbound persistence and before `CrisisMonitor.detect/1` (`telegram_message_worker.ex:136-173`); grep found one call plus one definition. The crisis test passes and verifies the persisted Telegram routing args (`telegram_message_worker_test.exs:473-493`). This validates enqueue coverage; the same uniqueness-horizon defect applies to renewal on either branch.

## Spec compliance matrix

| Requirement | Scenario | Runtime evidence | Result |
|---|---|---|---|
| Channel-Neutral Timeout Dispatch | Telegram session times out | `session_timeout_worker_test.exs:147-194` | PASS |
| Channel-Neutral Timeout Dispatch | Session already closed | `session_timeout_worker_test.exs:196-220` | PASS |
| WhatsApp Backward Compatibility | Legacy args without channel | `session_timeout_worker_test.exs:57-101` | PASS |
| WhatsApp Backward Compatibility | Existing tests unmodified | Git diff + focused suite | PASS |
| Telegram Timeout Job Args | Routing identifiers persisted | `telegram_message_worker_test.exs:446-471` | PASS |
| Telegram Timeout Enqueue On Inbound Save | Safe-path renewal | Focused test + 41-minute runtime probe | **FAILING** |
| Telegram Timeout Enqueue On Inbound Save | Crisis enqueue/renew | `telegram_message_worker_test.exs:473-493` | PASS for enqueue; renewal inherits the failing horizon |

**Compliance summary:** 6/7 scoped scenarios compliant; 3/4 scoped requirements complete.

## Task-by-task validation

### Phase 1 — RED: SessionTimeoutWorker channel-dispatch tests

- Status: **COMPLETE**
- 1.1 COMPLETE — Telegram outbound enqueue test exists at `session_timeout_worker_test.exs:147-194` and passes.
- 1.2 COMPLETE — closed-session Telegram short-circuit test exists at `:196-220` and passes.
- 1.3 COMPLETE by recorded TDD evidence — apply-progress records the expected pre-implementation `FunctionClauseError`; the tests exist and are GREEN now. Historical RED cannot be re-executed against the current commit without reconstructing the intermediate worktree.

### Phase 2 — GREEN: `session_timeout_worker.ex`

- Status: **COMPLETE WITH WARNINGS**
- 2.1 COMPLETE — both string-keyed arg shapes are accepted (`session_timeout_worker.ex:38-80`); absent channel defaults to WhatsApp. Present `nil` does not default; see WARNING-3.
- 2.2 COMPLETE — `run_close_flow/3` delegates delivery to `send_goodbye/2` (`:82-108`).
- 2.3 COMPLETE — WhatsApp and Telegram dispatch branches exist (`:124-143`), and the Telegram job shape is accepted by `TelegramOutboundWorker.perform/1` (`lib/alethea/jobs/telegram_outbound_worker.ex:72-95`).
- 2.4 COMPLETE — focused worker suite passed 4 tests; the two pre-existing test bodies are unchanged.

### Phase 3 — RED: Telegram enqueue-on-inbound-save tests

- Status: **PARTIAL**
- 3.1 COMPLETE — the former `refute_enqueued` test was replaced with positive safe-path routing assertions (`telegram_message_worker_test.exs:446-471`).
- 3.2 COMPLETE — crisis-path enqueue test exists and passes (`:473-493`).
- 3.3 PARTIAL — an immediate duplicate-count test exists and passes (`:495-544`), but it does not assert `scheduled_at` replacement and does not cover the 40-minute uniqueness boundary. The runtime probe proves the required long-session behavior is currently false.

### Phase 4 — GREEN: `telegram_message_worker.ex`

- Status: **COMPLETE WITH CRITICAL DEFECT**
- 4.1 COMPLETE structurally — helper args, 30-minute schedule, and `replace: [:scheduled_at]` match the task (`telegram_message_worker.ex:341-354`). The worker-level uniqueness period makes the broader renewal requirement fail.
- 4.2 COMPLETE — exactly one call appears at `:169`, after successful inbound save and before the safe/crisis split at `:173`.
- 4.3 COMPLETE as command execution — all 43 tests in the file pass; GREEN does not cure the missing boundary assertion.

### Phase 5 — REFACTOR

- Status: **COMPLETE**
- 5.1 COMPLETE — the Telegram helper keeps its own 30-minute calculation and mirrors the unmodified WhatsApp helper at `lib/alethea_jobs/process_message_worker.ex:218-226`; no shared helper was introduced.
- 5.2 COMPLETE — dispatch helpers are colocated and no dead production branch was found. The defensive unknown-channel branch has unsafe success semantics; see WARNING-3.

### Phase 6 — Verification

- Status: **COMPLETE**
- 6.1 COMPLETE — 4 passed.
- 6.2 COMPLETE — 43 passed (not 46; see WARNING-6).
- 6.3 COMPLETE — `mix precommit` passed 578 tests with 5 skipped.

## TDD compliance

| Check | Result | Details |
|---|---|---|
| TDD evidence reported | PASS | Apply-progress contains a RED/GREEN/REFACTOR/VERIFY table. |
| Behavioral work units have tests | PASS | 2/2 work units have focused test files. |
| RED test files exist | PASS | 2/2 files verified; historical failure modes recorded in apply-progress. |
| GREEN confirmed | PASS | 47/47 tests across the two focused files pass now. |
| Triangulation adequate | **FAIL** | Safe/crisis/closed variants exist, but renewal lacks the required 40-minute boundary and `scheduled_at` assertion. |
| Safety net for modified files | PASS | Apply-progress reports 2 + 41 baseline tests; Git diff confirms the two original WhatsApp tests were not edited. |

**TDD compliance:** 5/6 checks passed. The missing renewal triangulation is the same CRITICAL finding, not a second finding.

## Test layer distribution

| Layer | Tests | Files | Tools |
|---|---:|---:|---|
| Unit | 0 | 0 | — |
| Integration | 47 | 2 | ExUnit, Ecto sandbox, Oban.Testing, Mox |
| E2E | 0 | 0 | — |
| **Total focused suites** | **47** | **2** | |

The PR adds or replaces 5 targeted integration cases (2 timeout-worker cases and 3 Telegram inbound cases). No browser/E2E layer is relevant to these Oban workers.

## Changed file coverage

Coverage analysis skipped — no coverage dependency or configured coverage command was found.

## Assertion quality

| File | Line | Assertion | Issue | Severity |
|---|---:|---|---|---|
| `test/alethea/jobs/telegram_message_worker_test.exs` | 519-543 | Row count remains 1; args unchanged | Test name claims timer renewal, but it never proves `scheduled_at` moved and cannot detect the 40-minute uniqueness expiry | CRITICAL |

No tautologies, ghost loops, or production-code-free assertions were found in the changed test portions. The CRITICAL assertion gap is the same renewal finding counted above.

## Design coherence

| Decision | Followed? | Evidence |
|---|---|---|
| Carry Telegram channel/routing via Oban args | Yes, with WARNING | `telegram_message_worker.ex:341-348`; raw `chat_id` persistence wording is inaccurate. |
| Telegram goodbye through `TelegramOutboundWorker` | Yes | `session_timeout_worker.ex:124-138`; focused test passes. |
| Legacy WhatsApp default | Yes, with WARNING | `session_timeout_worker.ex:64-80`; present `nil` is not normalized. |
| One enqueue site before safe/crisis split | Yes | One call at `telegram_message_worker.ex:169`; split starts at `:173`. |
| Keep WhatsApp scheduling local/unmodified | Yes | `process_message_worker.ex` has no commit diff. |
| No Session schema/manager change | Yes | `session_manager.ex` has no commit diff. |
| PR-2 transaction/reordering excluded | Yes | `handle_crisis_path/9` remains sequential; only the pre-existing safe-path transaction exists at `telegram_message_worker.ex:268-285`. |

## CRITICAL findings

1. **Renewal creates duplicate timeout jobs after the 40-minute inserted-at uniqueness window** — `lib/alethea_jobs/session_timeout_worker.ex:2-5`, `lib/alethea/jobs/telegram_message_worker.ex:341-354`, `test/alethea/jobs/telegram_message_worker_test.exs:495-544`.
   - Oban reports the active uniqueness config as `timestamp: :inserted_at`, `period: 2400`, `fields: [:args]`.
   - Runtime proof: immediate renewal conflicts and keeps one row; after the original `inserted_at` is 41 minutes old while its renewed timeout remains scheduled in the future, the next identical insert does not conflict and produces a second row.
   - Impact: a long Telegram conversation can have multiple active timeout jobs; the earlier one may close the session before the latest inbound's intended 30-minute inactivity window.
   - Required fix: align uniqueness with the scheduled timer's lifetime and add a boundary test that verifies one row and a strictly later `scheduled_at` after the original 40-minute horizon.

## WARNING findings

1. **Plaintext `chat_id` is persisted at rest in Oban despite comments claiming it is not** — `session_timeout_worker.ex:27-31`, `telegram_message_worker.ex:153-160,342-348`. Oban stores args in `oban_jobs.args` JSONB; `TelegramOutboundWorker` itself documents this intentional PHI surface at `telegram_outbound_worker.ex:41-48`. This follows the chosen design and is not a functional blocker, but the threat model/comments must say “not persisted in clinical tables” rather than “never persisted at rest,” and review must confirm DB encryption, access, pruning, and error/log redaction controls.
2. **Telegram goodbye jobs use `patient_id: nil`** — `session_timeout_worker.ex:130-135`. `TelegramOutboundWorker` accepts it via `Map.get/3` (`telegram_outbound_worker.ex:87-95`), so the shape is valid, but any goodbye dead-letter loses direct patient correlation. This is explicitly the unresolved design default (`design.md:48,71`) and should be consciously accepted or replaced with the foundation UUID.
3. **Present `channel: nil` or an unknown channel is treated as successful message loss** — `session_timeout_worker.ex:72,124-153`. `Map.get/3` defaults only when the key is absent; `nil` reaches the fallback, which logs and returns `:ok` after the session is closed. Current callers do not emit this shape, so it is non-blocking, but normalize/validate the dispatch target before mutating session state and fail malformed jobs rather than acknowledging them.
4. **A transient Telegram goodbye enqueue failure is not recoverable by the timeout retry** — the session closes at `session_timeout_worker.ex:85`, enqueue occurs at `:130-136`, and a retry then exits through the closed-session guard at `:49-50`. Therefore an `Oban.insert!` failure can permanently omit the goodbye. The existing WhatsApp close flow already has partial-failure limitations, but the new Telegram branch should use an outbox/idempotent delivery marker or otherwise make delivery retryable after close.
5. **Stale crisis `@moduledoc`** — `telegram_message_worker.ex:51-59` still says the crisis branch is out of scope and raises `NotImplementedError`, while the branch is implemented. This is documentation drift only and can be corrected in PR-2/refactor work.
6. **Planning/TDD traceability is stale** — every PR-1 checkbox in `tasks.md:40-68` remains unchecked, and apply-progress claims the Telegram worker suite reached 46 tests even though replacing one test with three changes 41 to 43; the current run confirms 43. Implementation was independently inspected, so this is not a code blocker, but the artifact should not claim 46 or leave completed work unchecked.

## SUGGESTION findings

1. **Add one serialized-args delivery test** — after asserting the Telegram goodbye job in `session_timeout_worker_test.exs:178-193`, execute `TelegramOutboundWorker.perform/1` against the Fake client. That would prove the exact persisted args—including omitted `lane`, omitted `message_id`, and `patient_id: nil`—survive the complete outbound boundary, not merely job construction.

## Test run evidence

| Command | Exit | Result | Output SHA-256 |
|---|---:|---|---|
| `mix test test/alethea_jobs/session_timeout_worker_test.exs` | 0 | 4 passed | `72359e682da96c2366b0c012e724dd2793ce0aa27bd19ac4ddea703e3f88e9f3` |
| `mix test test/alethea/jobs/telegram_message_worker_test.exs` | 0 | 43 passed | `f702328503674082282d25804e9b870139f6c7495a4651f879bd14294e75a57d` |
| `mix test test/alethea/jobs/telegram_message_worker_test.exs:495` | 0 | 1 passed, 42 excluded | `a42ae5a12f5fd3f61277dea0fc88799ab2caff1cb8ac1d7f26bd522fba52a1c5` |
| Renewal horizon probe | 0 | count 1 inside window; count 2 after 41-minute `inserted_at` age | `149bd1016838072577dcf3b10a64978d3742f4282a31bf4558aa0eef7233d033` |
| `mix precommit` | 0 | 578 passed (2 doctests + 576 tests), 5 skipped | `07d917ec353a4dbfe3a98b321f0112a0800cab340a9e2daef3e2e5cb388fa920` |
| `mix compile --warnings-as-errors` | 0 | Compiling 2 files | `62ac10239807a71149064330c2cfc045f7688ae6bf5d9baefd67a2452e47789a` |

`mix precommit` emitted pre-existing test warnings/noise, including an `Alethea.ObanTelemetry.handle_stop/4` handler error that detached the handler, but exited 0 with the expected test totals. No source file was modified by precommit; post-run Git status showed only the pre-existing untracked `.codegraph/` directory.

## Quality metrics

- **Compiler:** PASS — `mix compile --warnings-as-errors` exited 0.
- **Formatter/dependency check:** PASS as part of `mix precommit`; Git remained unchanged.
- **Static type checker:** not separately configured.
- **Coverage:** not configured.

## Preserved-code and scope checks

- The inbound PHI-safe `safe_reason/1` wrapper remains at `telegram_message_worker.ex:136-151`, with the helper at `:307-316`; commit diff shows no change.
- The crisis outbound PHI-safe wrapper remains at `telegram_message_worker.ex:592-617`; commit diff shows no change.
- `handle_crisis_path/9` was not wrapped in a transaction. The only `Repo.transaction` occurrence is the pre-existing safe-path transaction (`:268-285`).
- `lib/alethea_jobs/process_message_worker.ex`, `lib/alethea/jobs/telegram_outbound_worker.ex`, and `lib/alethea/clinical/session_manager.ex` have no diff in commit `44841ed`.
- No `AletheaWeb` dependency was added under `lib/alethea_jobs/`.

## Out-of-scope confirmation (PR-2 items NOT verified here)

- `Repo.transaction` wrap in `handle_crisis_path/9`: PR-2 work, not in this PR.
- R3 crisis persistence failure test: PR-2 work, not in this PR.
- PubSub reordering: PR-2 work, not in this PR.

## Notes for judgment-day

- Reproduce and prioritize the 40-minute uniqueness-horizon defect; verify the selected fix against Oban 2.22.1's `timestamp`, `states`, and replacement semantics.
- Review the plaintext `chat_id` stored in both timeout and outbound Oban args as a bounded PHI-at-rest surface: DB privileges, encryption, retention/pruning, telemetry, error serialization, and admin query access.
- Force `TelegramOutboundWorker` insertion failure after successful close and confirm the goodbye is permanently skipped on retry; decide whether this reliability gap is acceptable.
- Exercise legacy args with absent channel, `channel: nil`, unknown channel, and mixed Telegram+phone shapes. Current valid callers are safe, but malformed jobs can close without delivery.
- Confirm whether `patient_id: nil` is an explicit product/operations acceptance or whether the foundation UUID should be threaded for dead-letter correlation.
- Re-check exactly-one call-site coverage after any PR-2 control-flow/transaction edits.

## Canonical verification-evidence preimage

The exact bytes below hash to `sha256:b056b445742e80cd1a4af7227795fc8241122d025aa772ed4b68d634aee8ef6c` and are preserved for downstream final-verification routing:

```text
schema=gentle-ai.verification-evidence/v1
change=session-timeout-channel-neutral
scope=PR-1 Goal 1 Channel-Neutral SessionTimeoutWorker
verification_date=2026-07-22
implementation_commit=44841ed
implementation_diff_sha256=96f771176cb6124ac2c0ea8ee681f0c897c44c122a31804edc6ce38aacad9f3d
context_sha256=acfe7f4244d771dc1baa91ba18ab50d63b773e397776c1bb706ad166b240988d
proposal_sha256=d965da5eb75bc61086c19fe9060e90ddd00d65e55c0b38a8bf52023abf47607f
spec_sha256=d811c6609c0e7aae3860912ed4fd4dc85941cceed2240d38b20ef0ace4669fe9
design_sha256=9bc36371100643d073c742b8ed01e1d31a76df986538ef2eb2c307aef55971aa
tasks_sha256=8647a1ae66a53ed8e64dd1c0be24a939573d78a8e6d3a946d92ac8f2818cd75c
focused_test_1_command=mix test test/alethea_jobs/session_timeout_worker_test.exs
focused_test_1_exit_code=0
focused_test_1_result=4 passed
focused_test_1_output_sha256=72359e682da96c2366b0c012e724dd2793ce0aa27bd19ac4ddea703e3f88e9f3
focused_test_2_command=mix test test/alethea/jobs/telegram_message_worker_test.exs
focused_test_2_exit_code=0
focused_test_2_result=43 passed
focused_test_2_output_sha256=f702328503674082282d25804e9b870139f6c7495a4651f879bd14294e75a57d
renewal_test_command=mix test test/alethea/jobs/telegram_message_worker_test.exs:495
renewal_test_exit_code=0
renewal_test_result=1 passed, 42 excluded
renewal_test_output_sha256=a42ae5a12f5fd3f61277dea0fc88799ab2caff1cb8ac1d7f26bd522fba52a1c5
renewal_horizon_probe_exit_code=0
renewal_horizon_probe_result=within window conflict true count 1; after inserted_at age 41 minutes conflict false count 2
renewal_horizon_probe_output_sha256=149bd1016838072577dcf3b10a64978d3742f4282a31bf4558aa0eef7233d033
test_command=mix precommit
test_exit_code=0
test_result=578 passed (2 doctests, 576 tests), 5 skipped
test_output_sha256=07d917ec353a4dbfe3a98b321f0112a0800cab340a9e2daef3e2e5cb388fa920
build_command=mix compile --warnings-as-errors
build_exit_code=0
build_result=Compiling 2 files (.ex)
build_output_sha256=62ac10239807a71149064330c2cfc045f7688ae6bf5d9baefd67a2452e47789a
requirements_complete=3/4
scenarios_compliant=6/7
critical_findings=1
verdict=fail
```

## Final verdict

**FAIL.** The green suite validates the immediate paths, but the required renewal behavior fails under a realistic long-session boundary and the committed test does not cover that boundary. PR-1 should not pass verification until uniqueness is tied to the active scheduled timer (or otherwise guaranteed for the full incomplete-job lifetime) and the corrected behavior is proven at runtime.
