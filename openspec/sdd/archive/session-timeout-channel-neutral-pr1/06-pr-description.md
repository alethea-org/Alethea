Closes #86.

## What

Channel-neutral `SessionTimeoutWorker` that closes a therapeutic `Session` after 30 minutes of inactivity, dispatching the goodbye message by channel:

- **Legacy WhatsApp args shape** (`%{session_id, patient_id, phone}`) — defaults `channel: "whatsapp"`, unchanged behavior, calls `whatsapp_client().send_message/2`. The 2 pre-existing WhatsApp tests stay green unmodified.
- **New Telegram args shape** (`%{channel: "telegram", chat_id, chat_id_hash, session_id, patient_id}`) — calls `TelegramOutboundWorker.new(%{chat_id, chat_id_hash, body, patient_id: nil}) |> Oban.insert!()`.

Plus a new `schedule_telegram_session_timeout/4` helper in `TelegramMessageWorker` that schedules the timeout job once per `perform/1`, immediately after the successful inbound save. One call site covers both safe and crisis branches. Renewal via `replace: [scheduled: [:scheduled_at]]` passed to `Worker.new/2` (NOT to `Oban.insert/2` — silent no-op there). The renewal test now asserts `scheduled_at` strictly advances AND same `Oban.Job.id` (runtime proof of renewal), plus a boundary probe ages `inserted_at` by 41 minutes to prove uniqueness dedupe holds past the original 40-min window.

No schema change, no migration, no new column. Channel routing identifiers are carried in Oban args only.

### OpenSpec artifacts (linked for reviewer)

- `openspec/sdd/session-timeout-channel-exploration.md` — Phase 0 exploration (the channel-dispatch decision: Oban args, not migration)
- `openspec/sdd/session-timeout-channel-neutral/proposal.md`
- `openspec/sdd/session-timeout-channel-neutral/spec.md` (8 requirements with scenarios; PR-1 covers Req: Channel-Neutral Timeout Dispatch, WhatsApp Backward Compatibility, Telegram Timeout Job Args, Crisis-path message also enqueues/renews timeout, Existing WhatsApp tests remain green)
- `openspec/sdd/session-timeout-channel-neutral/design.md` (Approach 3: Oban args dispatch)
- `openspec/sdd/session-timeout-channel-neutral/tasks.md` (9 Strict-TDD phases for PR-1, then PR-2 for atomicity)
- `openspec/sdd/session-timeout-channel-neutral/verify-report.md` (PASS WITH WARNINGS, 0 CRITICAL after fix)

## Why

Without channel-neutral timeout dispatch, the Telegram patient channel had no way to auto-close a session after inactivity — a foundational requirement for session-bound clinical summaries. WhatsApp already had this (via `ProcessMessageWorker`); Telegram needed the same to make the session boundary the unit of clinical continuity across channels.

## Out of scope (deferred, tracked)

**PR-2 (separate PR branched off PR-1, target `main`):** Crisis-Path Transactional Atomicity — wrap `handle_crisis_path/9` steps in one `Repo.transaction` (patient update + diagnosis save + crisis outbound save), with PubSub broadcast and outbound enqueue strictly post-commit. Includes the R3 suspect crisis-persistence-failure test. The PR-2 branch will be `feat/session-timeout-channel-neutral-pr2` based on this PR's branch per `feature-branch-chain` strategy.

**Follow-ups (pre-existing, not blocking this PR):**

1. WhatsApp silent no-op at `lib/alethea_jobs/process_message_worker.ex:225` — same class of bug the R1 fix removed from `telegram_message_worker.ex` (pre-existing). One-line fix: `replace: [scheduled: [:scheduled_at]]` to `SessionTimeoutWorker.new/2`, drop from `Oban.insert!/2`.
2. `inspect(reason)` PHI surface on the remaining 11 sites — all pre-existing, all now trivial 1-line `SafeReason.for_log/1` swaps thanks to the shared module extracted in R2:
   - `lib/alethea_jobs/weekly_report_worker.ex:47` (same exact bug class — Clinical.save_summary changesets carry `summary_text`)
   - `lib/alethea_jobs/session_reminder_worker.ex:42,45` (line 42 is PERSISTED to audit_logs.details — DB exposure)
   - `lib/alethea_jobs/emotion_analysis_worker.ex:38,178`
   - `lib/alethea_jobs/process_message_worker.ex:66,141,146,153,162,204,212` (7 sites, WhatsApp pipeline)
   - `lib/alethea/jobs/telegram_outbound_worker.ex:233,244` (line 244 is PERSISTED to OutboundDeadLetter.last_error — DB exposure)
   - `lib/alethea/jobs/telegram_message_worker.ex:243,323,426`
3. `lib/alethea_jobs/session_timeout_worker.ex:124-125` short-circuits to `:ok` when `session.status == "closed"`, so a retry after `close_session` succeeded but `TelegramOutboundWorker.new |> Oban.insert!()` failed permanently loses the goodbye (carry-forward from verify WARNING #2).
4. `lib/alethea_jobs/session_timeout_worker.ex:271-280` catch-all branch logs warning + returns `:ok` for unknown channels; silently drops the goodbye for any new channel (carry-forward from verify WARNING #3, intentional design backstop).
5. Stale `@moduledoc` on `lib/alethea/jobs/telegram_message_worker.ex:51-59` claims the crisis branch "lands in PR #3b" — wrong, branch is implemented at lines 530-651 (carry-forward from verify WARNING #4, doc drift only).
6. `Oban.Plugins.Pruner` not configured — completed/failed `oban_jobs` rows (with `chat_id` plaintext in args) are retained indefinitely. Architectural gap: PG row-level privileges + TLS are operational, but there's no automatic purge.
7. Per-call PHI-safe pattern is fragile — future error sites must remember `SafeReason.for_log/1` AND `LogRedactor.redact/1` (different scopes). A global Logger backend or `Alethea.SafeLogger` wrapper would be more robust. Architectural follow-up.

## Verification

- `mix precommit` → exit 0, **597 passed (6 doctests + 591 tests), 5 skipped** (compile `--warnings-as-errors` + format + full suite)
- Focused: `mix test test/alethea_jobs/session_timeout_worker_test.exs` → **6 passed** (4 pre-existing WhatsApp + Telegram channel + 2 sentinel-based regression tests)
- Focused: `mix test test/alethea/jobs/telegram_message_worker_test.exs` → **44 passed** (41 pre-existing + 3 new enqueue tests including the strengthened renewal test + 41-min boundary probe)
- NEW: `mix test test/alethea_jobs/safe_reason_test.exs` → **16 passed** (sentinel-based contract tests)
- The 2 pre-existing WhatsApp tests in `session_timeout_worker_test.exs` stay green **unmodified** (Req: WhatsApp Backward Compatibility)
- `#84` PHI-redaction safe-path tests, `#85` R1/R2 strengthen tests (inbound persistence failure session-UUID leak at `test.exs:680-727`, diagnosis-save failure session-UUID leak at `test.exs:824-854`, crisis queue-full escalation at `test.exs:1131-1285`) all stay green — `telegram_message_worker.ex` refactor to use `SafeReason.for_log/1` is regression-free

## Adversarial review (3-opinion coverage) — APPROVED ✅

User explicitly requested 3 independent opinions (vs standard judgment-day's 2) for higher confidence. Two blind judgment-day judges + one `review-risk` bounded lens, both rounds:

### Round 1 — CRITICAL closed via R1 fix

Verify caught 1 CRITICAL: `unique: [fields: [:args], period: 40 * 60]` allowed duplicate timeout jobs after the 40-min window expired. The R1 fix changed it to `period: :infinity`. The fix agent also surfaced a **second silent bug** that the weak renewal test masked: the original `Oban.insert!(replace: [:scheduled_at])` was a no-op — `replace:` must be passed to `Worker.new/2` (where `Job.put_replace/3` stores it on the changeset). Pre-fix, `scheduled_at` never advanced on renewal (count stayed at 1 via uniqueness dedupe, but the timer was pinned). Fixed by `replace: [scheduled: [:scheduled_at]]` passed to `SessionTimeoutWorker.new/2`. The renewal test was strengthened to assert `scheduled_at` strictly advances AND same `Oban.Job.id` — would have failed without the fix.

### Round 2 — review-risk caught a new issue the 2 judgment-day judges missed

`review-risk` (the bounded lens, the 3rd opinion) caught that `lib/alethea_jobs/session_timeout_worker.ex:180` used bare `inspect(reason)` in the `Logger.error` call. If `save_summary` failed, `inspect(%Ecto.Changeset{})` would embed the `changes` map (including `summary_text` — AI-generated clinical summary = direct PHI). Same class of bug as the #85 R1 fix (PHI leak via Oban errors/logs on a Changeset error). The 2 judgment-day judges had approved R1 with this as a documented WARNING; the user decided R2 fix honors the catch.

R2 fix: extracted `safe_reason/1` (was a private helper in `telegram_message_worker.ex`) to shared module `AletheaJobs.SafeReason`. Applied at the previously-leaking site. Updated `telegram_message_worker.ex`'s 3 call sites to use the shared module. Tightened the `session_timeout_worker.ex` moduledoc to be honest about what IS and IS NOT protected (removed the aspirational "application-level LogRedactor on error serialization" and "Oban prune/retention" claims). Added 18 new tests including 2 sentinel-based regression tests (`@phi_sentinel "FAKE-CLINICAL-SUMMARY-MUST-NOT-LEAK-IN-LOGS-ABCD1234"` + `capture_log` + `refute log =~ @phi_sentinel`) that would FAIL without the fix.

### Final verdict (Round 2)

0 CRITICAL. All 3 opinions APPROVED. 9 carry-forward WARNINGs (all pre-existing, not regressed) documented as follow-ups.

## Follow-ups (non-blocking, tracked separately)

1-7: As listed in "Out of scope" above. The most impactful single follow-up is **#2** (the remaining 11 `inspect(reason)` sites, especially `weekly_report_worker.ex:47` which has the same exact bug class as the R2 fix and is a one-line swap to `SafeReason.for_log/1`).

## Test counts

| Stage | Tests | Delta | Failures | Skipped |
|---|---|---|---|---|
| `main` (baseline, #85 merged) | 569 | — | 0 | 5 |
| Apply (`44841ed`) | 578 | +9 | 0 | 5 |
| R1 fix (`f605d29`) | 579 | +1 (boundary probe) | 0 | 5 |
| R2 fix (`02c8230`) | 597 | +18 (16 SafeReason + 2 sentinel regression) | 0 | 5 |

## Files changed (cumulative diff vs `main`)

| File | Change |
|------|--------|
| `lib/alethea_jobs/safe_reason.ex` | NEW (94 lines) — extracted `SafeReason.for_log/1` with moduledoc, doctests |
| `lib/alethea_jobs/session_timeout_worker.ex` | Generalized `perform/1` to accept both legacy `%{phone}` and new `%{channel, chat_id, chat_id_hash}` shapes; added `send_goodbye/2` channel switch; tightened moduledoc; fixed `inspect(reason)` PHI leak via `SafeReason.for_log(reason)`; `unique: [period: :infinity]` |
| `lib/alethea/jobs/telegram_message_worker.ex` | Added `schedule_telegram_session_timeout/4` (one call site after inbound save covering both branches); replaced private `safe_reason/1` defs with shared `SafeReason.for_log/1` |
| `test/alethea_jobs/safe_reason_test.exs` | NEW (169 lines) — sentinel-based contract tests |
| `test/alethea_jobs/session_timeout_worker_test.exs` | Added 2 Telegram channel tests; added 2 sentinel-based regression tests; pre-existing 2 WhatsApp tests stay unmodified |
| `test/alethea/jobs/telegram_message_worker_test.exs` | Replaced `refute_enqueued` block from #85 with `assert_enqueued` for the new timeout dispatch; added crisis-path test; strengthened renewal test with `scheduled_at` advancement + same id assertion; added 41-min boundary probe test |
| `openspec/sdd/session-timeout-channel-neutral/{exploration,proposal,spec,design,tasks}.md` | Phase 0-4 SDD artifacts |
| `openspec/sdd/session-timeout-channel-neutral/verify-report.md` | Phase 6 verify output (PASS WITH WARNINGS, 0 CRITICAL after fix) |

## Commits (3)

```
02c8230 fix(jobs): extract safe_reason and stop leaking Changeset changes in session_timeout log
f605d29 fix(jobs): extend session-timeout uniqueness period and document chat_id persistence
44841ed feat(jobs): channel-neutral SessionTimeoutWorker with Telegram dispatch
```

## Compounding findings worth attention

- **3-opinion coverage caught 3 distinct bugs the single-apply perspective missed**: R1 uniqueness period (verify) + R1 silent `replace:` no-op (R1 fix surfaced) + R2 `inspect(reason)` PHI leak (R1 judgment-day's review-risk caught). Single-apply perspective missed all 3.
- **Per-call PHI-safe helpers are NOT a substitute for a global Logger backend.** The codebase has 2 patterns (`SafeReason.for_log/1` + `LogRedactor.prefix/1/redact/1`) but they're manually applied at specific sites. Future regressions can forget to use them. Architectural follow-up suggested (item #7 above).
- **Oban `replace:` option format**: `replace: [state: [field,...]]` (state-keyed keyword list) passed to `Worker.new/2`. The plain-list `replace: [:field]` passed to `Oban.insert/2` is silently ignored. Pattern is non-obvious; Oban's `put_replace/3` accepts both forms when passed to `new/2` but only the state-keyed form is explicit and unambiguous. Worth a comment in the Oban docs (out of our control).
