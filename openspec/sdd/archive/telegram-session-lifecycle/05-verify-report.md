```yaml
schema: gentle-ai.verify-result/v1
evidence_revision: sha256:31dc20c06981ceea5d257d51f736c2e81ed52d0ab0b4f14294b87a37441c95af
verdict: pass_with_warnings
blockers: 0
critical_findings: 0
requirements: 8/8
scenarios: 9/10
test_command: mix test test/alethea/jobs/telegram_message_worker_test.exs && mix test test/alethea/clinical/session_manager_test.exs
test_exit_code: 0
test_output_hash: sha256:79b62ae0457c043669f7a46ce21e9d7696640da46d69eac3b9844825021621b6
build_command: mix precommit
build_exit_code: 0
build_output_hash: sha256:da0c77a76baac452b7552e956731edca69d6a5b88c766e646d400fa12a695116
```

# Verify report — telegram-session-lifecycle (#85)

**Verdict:** PASS WITH WARNINGS  
**Date:** 2026-07-22  
**Implementation commit:** 5fc134d  
**Mode:** Strict TDD

## Summary

- 0 CRITICAL / 3 WARNING / 2 SUGGESTION
- The worker implements Option B correctly: one `current_open_session/1` call occurs after legacy-patient resolution and before the #84 transaction, and the resulting id is threaded into inbound, safe outbound, and crisis outbound persistence in the correct sixth argument position.
- All focused, SessionManager, and full precommit executions pass. The verdict is qualified because the spec's exact-once-call condition is established statically rather than by a call-count test, the inactivity-window scenario is only partially covered, and the crisis branch remains non-atomic with respect to its outbound persistence.

## Completeness

| Metric | Value |
|---|---:|
| Requirements | 8/8 implemented |
| Scenarios | 9/10 runtime-compliant; 1/10 partial |
| Task checkboxes | 17/17 checked |
| Task phases | 9/9 complete |
| Changed test layer | Integration: 5 new tests in 1 file |
| Coverage | Not run — no changed-file coverage capability was provided |

## Requirement-by-requirement validation

### Requirement: Inbound Session Association
- Scenario: Non-crisis inbound opens or renews a session → **WARNING** — Worker resolves the legacy patient, calls `SessionManager.current_open_session(legacy_patient.id)` once at `lib/alethea/jobs/telegram_message_worker.ex:132-134`, and passes `session.id` as the sixth argument at lines 136-144. Runtime test `reuses the same open session for consecutive inbound messages` drives `perform/1` twice and asserts non-nil/equal ids at `test/alethea/jobs/telegram_message_worker_test.exs:234-258`. However, the test does not instrument or assert an exact call count; exact-once is proven only by static source inspection (the worker contains one call site).

### Requirement: Safe-Path Outbound Session Association
- Scenario: Safe-path outbound shares the inbound session → **PASS** — `session.id` enters `handle_safe_path/7` at worker lines 148-158, is forwarded to `persist_and_enqueue_outbound/7` at lines 203-211, and is passed as the sixth `save_telegram_message/6` argument at lines 245-253. Test `persists safe-path outbound in the same session as inbound` asserts both ids are non-nil and equal through `perform/1` at test lines 367-386. Focused suite passed.

### Requirement: Crisis-Path Outbound Session Association
- Scenario: Crisis outbound shares the inbound session → **PASS** — `session.id` enters `handle_crisis_path/9` at worker lines 160-171 and is passed as the sixth save argument at lines 546-555. Test `persists crisis-path outbound in the same session as inbound` drives `perform/1` and asserts equality at test lines 683-704. Focused suite passed.

### Requirement: Session Grouping Within an Open Window
- Scenario: Two messages while session is open → **PASS** — The two-perform integration test at test lines 234-258 proves reuse. `SessionManager.current_open_session/1` serializes per patient with `pg_advisory_xact_lock`, selects an existing open session, and creates only when absent (`lib/alethea/clinical/session_manager.ex:12-43`). Its focused suite also confirms existing-open reuse.

### Requirement: New Session After Explicit Close
- Scenario: Message after explicit close starts a new session → **PASS** — Test lines 409-444 get the worker-created open session, assert its id matches the first inbound row, close it via `SessionManager.close_session/1`, then perform a distinct second job and assert a new non-nil id. DataCase sandbox isolation prevents cross-test leakage; SessionManager's own create/reuse/close tests also pass.
- Scenario: No auto-close performed by the Telegram path → **WARNING** — No `SessionTimeoutWorker` reference exists in the worker, and test lines 446-458 proves no timeout job is enqueued after a safe-path perform. The scenario's stronger precondition, “open past any hypothetical inactivity window,” is not simulated, and the crisis path is not included in this guard test. Static source plus `current_open_session/1` having no staleness logic support the behavior, but runtime coverage is partial.

### Requirement: Encryption Boundary Preserved
- Scenario: Session threading does not alter encryption → **PASS** — `Clinical.save_telegram_message/6` forwards `session_id` as the seventh positional argument to `save_message/8` (`lib/alethea/clinical.ex:134-153`). `save_message/8` encrypts only `text` through `PatientVault.encrypt/2` and stores `session_id` separately in attrs (`clinical.ex:38-47`). `Message` models `session` as a normal association and casts `session_id` separately from `encrypted_content` (`lib/alethea/clinical/message.ex:19-26,34-47`). Runtime worker tests persist non-nil session metadata through this path, while existing tests decrypt outbound content.

### Requirement: No Timeout Worker Scheduled
- Scenario: No timeout job enqueued → **PASS** — Test `does not enqueue a SessionTimeoutWorker` uses `%Oban.Job{} |> perform()` and `refute_enqueued(worker: AletheaJobs.SessionTimeoutWorker)` at test lines 446-458. Source search finds no timeout-worker scheduling in `TelegramMessageWorker`.

### Requirement: Session Membership Test Entry Point
- Scenario: Test asserts via perform/1 → **PASS** — All five new tests call `TelegramMessageWorker.perform(%Oban.Job{args: ...})`; no private helper is invoked. The relevant calls are at test lines 243-244, 373, 422/434, 455, and 692.

## Behavioral compliance matrix

| Requirement | Scenario | Runtime evidence | Result |
|---|---|---|---|
| Inbound association | Non-crisis inbound opens/reuses session | Worker test: consecutive inbound messages | ⚠️ PARTIAL — exact call count not instrumented |
| Safe outbound | Outbound equals inbound session | Worker test: safe outbound membership | ✅ COMPLIANT |
| Crisis outbound | Crisis outbound equals inbound session | Worker test: crisis outbound membership | ✅ COMPLIANT |
| Open-window grouping | Two inbound messages share id | Worker test: consecutive inbound messages | ✅ COMPLIANT |
| Explicit close | New id after close | Worker test: explicit close | ✅ COMPLIANT |
| No auto-close | Reuse without close and no timeout job | Reuse test + timeout guard, but no elapsed-window setup | ⚠️ PARTIAL |
| Encryption boundary | Encrypted content + plaintext session metadata | Worker persistence tests + existing decrypt assertions | ✅ COMPLIANT |
| No timeout worker | No job enqueued | Worker timeout guard | ✅ COMPLIANT |
| Test entry point | Assertions via perform/1 | All five new tests | ✅ COMPLIANT |

## Task-by-task validation

### Phase 1 — RED: Inbound Session Association
- Status: **COMPLETE**
- Evidence: New two-perform test at test lines 234-258 matches task 1.1. Apply observation #61 records the RED state as 36/37 passing with `first_session_id == nil`; current test passes.

### Phase 2 — GREEN: Inbound Session Association
- Status: **COMPLETE**
- Evidence: Alias at worker line 71; single fetch at line 134; sixth argument at line 143. Focused worker suite: 41 passed.

### Phase 3 — RED: Safe-Path Outbound Session Association
- Status: **COMPLETE**
- Evidence: New safe outbound test at test lines 367-386. Observation #61 records RED as 37/38 passing with outbound `session_id == nil`.

### Phase 4 — GREEN: Safe-Path Outbound Session Association
- Status: **COMPLETE**
- Evidence: `handle_safe_path/7` at worker lines 176-184, `persist_and_enqueue_outbound/7` at lines 223-231, and sixth save argument at line 252. The #84 rollback and PHI-redaction tests remain present at test lines 541-623 and pass in the focused suite.

### Phase 5 — RED: Crisis-Path Outbound Session Association
- Status: **COMPLETE**
- Evidence: New crisis membership test at test lines 683-704. Observation #61 records RED as 38/39 passing with outbound nil versus inbound session id.

### Phase 6 — GREEN: Crisis-Path Outbound Session Association
- Status: **COMPLETE**
- Evidence: `handle_crisis_path/9` at worker lines 500-510 and sixth save argument at line 554. Existing crisis branch and escalation tests pass in the 41-test focused run.

### Phase 7 — Session Window Grouping + No-Auto-Close Guard
- Status: **COMPLETE**
- Evidence: Explicit-close test at test lines 409-444 and timeout guard at lines 446-458 both pass. The elapsed-inactivity wording remains only partially exercised, recorded as a warning above.

### Phase 8 — Refactor / Cleanup
- Status: **COMPLETE**
- Evidence: Commit diff modifies only alias/fetch/argument threading in production code; #84 transaction body and safe-error redaction remain structurally unchanged. Duplicate Telegram id still returns a changeset error and produces the pre-existing worker `MatchError` (`lib/alethea/clinical.ex:74-80`; test lines 468-496). Optional stale moduledoc cleanup was explicitly skipped as allowed. `mix precommit` passed.

### Phase 9 — PR Notes
- Status: **COMPLETE**
- Evidence: Apply observation #61 records the commit/PR boundary note that automatic inactivity close is deferred to #86. No implementation of timeout scheduling exists.

## Design coherence

| Decision | Status | Evidence |
|---|---|---|
| Option B: single fetch + thread | Followed | Worker lines 132-170; only one `current_open_session` call site |
| Fetch outside #84 transaction | Followed | Fetch at line 134; transaction begins at line 244 |
| Pass session id as plain value | Followed | Private arity bumps and sixth save arguments at lines 143, 252, 554 |
| Include crisis outbound | Followed | Worker lines 500-555; passing crisis test |
| No timeout worker | Followed | No worker reference; passing enqueue guard |
| Preserve encryption boundary | Followed | `clinical.ex:38-47,134-153`; `message.ex:19-26,34-47` |
| Preserve #84 rollback/redaction | Followed | Commit diff changes only outbound save's new sixth argument inside transaction |
| Preserve duplicate MatchError | Followed | No change to error matching; regression test passes |

## TDD Compliance

| Check | Result | Details |
|---|---|---|
| TDD evidence reported | ✅ | Engram apply observation #61 contains a TDD Cycle Evidence table |
| All behavior tasks have tests | ✅ | 5 new worker integration tests cover phases 1, 3, 5, and 7 |
| RED confirmed | ✅ | Apply evidence records the expected failing values before implementation |
| GREEN confirmed | ✅ | 41 focused tests and 6 SessionManager tests pass now |
| Triangulation adequate | ⚠️ | Safe/crisis/open/close boundaries vary, but exact call count and elapsed-inactivity precondition are not directly instrumented |
| Safety net for modified file | ✅ | Apply evidence records 36 existing focused tests before changes |

**TDD Compliance:** 5/6 checks fully passed.

## Test Layer Distribution

| Layer | New tests | Files | Tool |
|---|---:|---:|---|
| Unit | 0 | 0 | ExUnit |
| Integration | 5 | 1 | ExUnit + DataCase + Oban.Testing + Mox |
| E2E | 0 | 0 | Not applicable |
| **Total** | **5** | **1** | |

## Changed File Coverage

Coverage analysis skipped — no coverage tool/capability was supplied for changed-file line and branch coverage.

## Assertion Quality

**Assertion quality:** All five new tests invoke production code and assert persisted/enqueued outcomes. No tautologies, ghost loops, type-only assertions, or private-helper-only tests were found. Two scenario-specific coverage limitations are reported as warnings rather than assertion defects.

## Quality Metrics

- **Compile/lint/format:** `mix precommit` exited 0. It emitted pre-existing test warnings outside the changed files.
- **Type checker:** No separate type checker configured/provided.
- **Runtime logs:** The full suite emitted existing expected error logs, including an Oban telemetry handler error outside this change; no test failed.

## CRITICAL findings

- None.

## WARNING findings

1. **`test/alethea/jobs/telegram_message_worker_test.exs:234-258` — exact-once SessionManager call is not runtime-asserted.** The spec explicitly requires exactly one call per bound, non-empty perform. Static inspection confirms one call site at worker line 134 and no calls in either branch, but a regression adding a second call could escape these tests as long as the same session is returned. Recommendation: introduce an injectable SessionManager behavior or telemetry seam and assert one call per perform.
2. **`test/alethea/jobs/telegram_message_worker_test.exs:446-458` — inactivity/no-auto-close scenario is only partially exercised.** The test proves no timeout job is enqueued after a safe message, but does not age the session and does not run the crisis path. Recommendation: set `started_at` to an old timestamp, run another perform, assert reuse, and parameterize safe/crisis variants for timeout-enqueue absence.
3. **`lib/alethea/jobs/telegram_message_worker.ex:513-567` — crisis outbound persistence remains non-atomic with preceding crisis side effects.** Urgent-intervention update, diagnosis save, PubSub broadcast, outbound Message save, and enqueue occur sequentially without a transaction. A failure after the diagnosis/broadcast but before outbound completion can leave partial state, and an Oban retry then collides on the already-persisted inbound Telegram id. This is pre-existing and outside #85's declared scope, so it does not block session threading, but the new session association does not mitigate it. Recommendation: address crisis-path idempotency/atomicity in a dedicated change before production reliance.

## SUGGESTION findings

1. **`test/alethea/jobs/telegram_message_worker_test.exs:430-432` — the explicit-close test calls `current_open_session/1` a second time to retrieve the session.** The equality assertion makes the test sound, but loading `Session` directly by `first_inbound.session_id` would isolate `close_session/1` and avoid exercising the creation/reuse function during setup for a scenario whose subject is the subsequent worker call.
2. **`lib/alethea/jobs/telegram_message_worker.ex:20,29,51-59` — stale moduledoc claims `/7` and an unimplemented crisis branch.** The implementation uses `save_telegram_message/6`, and crisis behavior is present. Recommendation: update the documentation in a cleanup-only commit so operational readers are not misled.

## Retry, rollback, and lock analysis

- `current_open_session/1` owns a short `Repo.transaction`; its advisory lock is transaction-scoped and released on commit/rollback. It returns a materialized session after the transaction, so no lock or transaction leaks into worker processing.
- It is called before inbound persistence and before the #84 safe-outbound transaction. If the worker fails after opening a session but before saving inbound, an empty open session remains and is reused on retry. This matches the accepted design behavior and does not create duplicate open sessions under concurrent calls because the advisory lock serializes the lookup/create sequence.
- Safe-path outbound Message and AI diagnosis remain atomic inside the existing transaction. Inbound persistence intentionally remains outside. If safe outbound fails, the open session and inbound row remain; a retry fails earlier on the duplicate `telegram_message_id` MatchError, a pre-existing limitation explicitly out of scope. Session reuse does not compound this into a new session; it reuses the same open session.
- Crisis outbound is not atomic with inbound or crisis side effects; see WARNING 3.

## Test run evidence

- `mix test test/alethea/jobs/telegram_message_worker_test.exs` → exit 0; **41 passed**; output SHA-256 `b24ab6c3aeab12748d8b6ade51c227544d96e2adf1ad110d7d73e42e496bc084`.
- `mix test test/alethea/clinical/session_manager_test.exs` → exit 0; **6 passed**; output SHA-256 `b4854a68fdd946856c78197c41978041d48a3bbb9f8bf009887e4413db822c40`.
- Combined focused evidence hash (exact concatenation of the two captured outputs) → SHA-256 `79b62ae0457c043669f7a46ce21e9d7696640da46d69eac3b9844825021621b6`.
- `mix precommit` → exit 0; **574 passed (2 doctests, 572 tests), 5 skipped**; output SHA-256 `da0c77a76baac452b7552e956731edca69d6a5b88c766e646d400fa12a695116`.

## Notes for judgment-day

- Stress crisis-path partial failure after urgent flag/diagnosis/broadcast but before outbound enqueue; verify whether retry behavior can recover or only hits the duplicate inbound MatchError.
- Stress safe-path failure after inbound commit: the #84 outbound transaction rolls back correctly, but retry currently appears unable to advance because the duplicate inbound insert fails first.
- Exercise concurrent performs for the same patient and confirm the advisory-lock key strategy (`:erlang.phash2(patient_id)`) cannot produce clinically meaningful cross-patient contention or duplicate open sessions.
- Verify no external caller or future branch bypasses `process_bound_message/6`; exact-once is structurally true today but not protected by a runtime call-count assertion.
- Verify crisis and safe no-timeout behavior with an artificially old open session, not only a freshly created one.
