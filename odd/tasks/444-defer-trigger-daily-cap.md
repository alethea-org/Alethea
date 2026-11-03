# Issue #444 — Defer active triggers and cap daily sends
Objective: implement #444 on `feat/444-defer-trigger-daily-cap`, based on `663cb9013461a5efaa693d3dcb3df513509645e8`.
Delivery: auto-chain, feature-branch-chain (human selected); forecast ~480 authored changed lines in two coherent units. Runner: focused `mix test` files and `mix precommit`. No push, PR creation, or merge authorized.

## Specs
S1. "If a journaling session is open when a Trigger activo is due (pending burst reply or session not timed out), defer the send until the session closes, at most 1h, then send anyway." Check worker public interface for pending replies, non-timed-out sessions, closure, and one-hour boundary; verify no premature side effects and preserved recurrence/idempotency.
S2. "Cap active sends to 5 per patient per day (global configuration)." Check configurable limit, active-only per-patient daily counting, day boundary, and concurrent attempts.
S3. "A due firing during an open session is sent after the session closes, or after 1h at the latest." Check before/exactly at one hour and closure using worker perform and outbound jobs; preserve crisis protection.
S4. "The sixth send of the day for a patient is not sent and is recorded as skipped in the history." Check no outbound message/job for sixth send, truthful skipped history without message link, idempotent retry, and recurrence advancement.

## Tasks
- T1 | S1,S3 | inline: runtime rejected writer launch and explicitly instructed inline execution without retry | done | Implemented bounded session deferral with tests/docs. RED: 4/6 fail as expected; focused GREEN and full suite exit 0 (2609 passed, 5 skipped). Commit fa7c525daddd60089a082710a656e9969fdec14e; native medium, reviewDue=false (under_budget).
- T2 | S2,S4 | delegated: gentle-ai-worker (runtime context backstop), after T1 | done | Cap/history including DST regression verified. Writer focused 65/precommit 2621 pass (5 skipped); parent cap 8 pass; independent recheck mw18rfhv-5-dqbj RESOLVED, 8 pass, no missing proof. Commit pending below. Risk: item 4 (concurrent daily send accounting).
- T3 | S1-S4 | parent plus gentle-ai-verify for named high-risk unit | in_progress | Functional verification and precommit passed; commit T2 and assess its range, native review only when due, then close tracking. No publishing authorized.

## Log
L1. User request verbatim: "hagamos la issue [Feature]: Defer Trigger activo during open sessions and cap daily sends #444"
L2. Issue #444 body verbatim:
> ## Parent
>
> #435
>
> ## What to build
>
> - If a journaling session is open when a Trigger activo is due (pending burst reply or session not timed out), defer the send until the session closes, at most 1h, then send anyway.
> - Cap active sends to 5 per patient per day (global configuration).
>
> ## Acceptance criteria
>
> - A due firing during an open session is sent after the session closes, or after 1h at the latest.
> - The sixth send of the day for a patient is not sent and is recorded as skipped in the history.
>
> ## Blocked by
>
> - #440
L3. #440 is closed. Previous #443 is merged as PR #473. Fetched origin/main, confirmed prior HEAD is its ancestor, and created the clean feature branch at 663cb9013461a5efaa693d3dcb3df513509645e8. RDD is on globally.
L4. Explorer mapped worker, firing schema, history LiveView, session manager, and patient conversation lock. Parent spot-checked worker/schema/session manager. Explorer's exact inactivity threshold and suggested helpers remain hypotheses for writer verification, not established facts. Preserve crisis precedence, approval revision, recurrence, duplicate-firing uniqueness, content-free auditing, and existing lock ordering.
L5. User instruction verbatim: "Review the delivered subagent output and continue."
L6. Delivery choice verbatim: "Cadena sobre rama de feature (recomendado)". Chaining choice is feature-branch-chain; publish only with separate human authorization. Forecast ~480 lines, boundaries T1 deferral then T2 daily cap/history (tests/docs stay with each behavior). Parent handles branch/commits; workers do not commit.
L8. Writer T1 launch was refused by runtime admission despite the declared feature document; runtime instructed inline execution without retry. No writer edits occurred. T1 remains in progress, with no completed checks. Engram mirror save succeeded (5699); readback tool rejected its advertised observation_id schema, so memory readback is unavailable, not proven synchronized.
L7. Implementation interpretations: poll with bounded snooze (not later than original due time + 1h); retain original scheduled_at while deferred; skipped occurrences are consumed rather than retried next day; daily limit uses patient's local calendar day, never individual trigger timezone; cap is serialization order, no priority system. These follow issue scope and existing schedule model; no extra product feature is introduced.
L9. T1 complete: `mix test test/alethea_jobs/active_trigger_deferral_test.exs` RED exit 2, four expected missing-deferral failures; two guards passed. GREEN: `mix format lib/alethea_jobs/active_trigger_worker.ex test/alethea_jobs/active_trigger_deferral_test.exs && mix test test/alethea_jobs/active_trigger_worker_test.exs test/alethea_jobs/active_trigger_deferral_test.exs test/alethea/triggers_test.exs && mix test` exit 0; full result 2609 passed, 5 skipped. Existing suite emits expected simulated service errors and sandbox disconnect logs. `git diff --check` passed. Risk: none for T1 (worker-local deferral; no shared helper or lock change). No separate verifier required. Preliminary ASSESS unassessable because new files were untracked. Committed ASSESS at base 663cb9013461a5efaa693d3dcb3df513509645e8: medium, 199 authored changed lines, reviewDue=false (under_budget). No review started. Whitespace EOF check initially failed in tracking only, then was fixed before commit. Next unit base is fa7c525daddd60089a082710a656e9969fdec14e.
L10. T2 writer mw17kmyu-2-h21r returned completed: RED cap/concurrency/schema/history failures observed, GREEN 64 focused tests; mix precommit exit 0, 2620 passed including 6 doctests, 5 skipped. Parent independently ran daily-cap/deferral/history files: 31 passed, exit 0. Assessment escalated item 4 and requires independent verifier; native assessment remains unassessable until new files are declared/committed. Verifier mw18960d-3-08ad is running; parent flagged potential DST midnight gap end-boundary truncation for reproduction. T2 remains in progress, not accepted yet.
L11. T2 authored size exceeds initial forecast (tracked diff alone 554 lines, plus new 344-line test and migration). Writer summary omitted untracked files from its count. Feature-branch-chain choice is retained, no publishing authorized. Keep the coherent cap/schema/history/tests unit together rather than split tests away from behavior; report honest review workload.
L12. Independent verifier mw18960d-3-08ad: 64 focused tests pass, migration down/up probe passes on isolated test DB. S1/S3/S4 pass; S2 blocked by deterministic DST gap: end-of-day selects 23:59:59.999999 then truncates to 23:59:59, omitting a firing at the last second of 2026-09-05 America/Santiago (2026-09-06T03:59:59Z); count returns 4 instead of 5. One bounded correction dispatched to existing writer as mw18f2c9-4-apvb, limited to context/helper regression/docs; require RED then GREEN and precommit, then blocker-only verifier recheck. Ambiguous midnight advisory not adopted: consistent earliest midnight on both adjacent boundaries is correct and avoids overlapping days. No broader sweep or scope expansion.
L13. Correction mw18f2c9-4-apvb returned completed: regression RED exit 2 (end boundary 03:59:59Z instead of 04:00Z); GREEN cap 8 tests, focused 65 tests, precommit 2621 passed incl. 6 doctests and 5 skipped. Helper now shares first valid instant for gap boundaries and earliest instant for ambiguous midnight; unused boundary arg removed. Parent spot-check cap file: 8 passed, exit 0. Blocker-only independent recheck mw18rfhv-5-dqbj launched; no final acceptance yet.
L14. Independent recheck mw18rfhv-5-dqbj returned RESOLVED: inspected gap helper, ran cap file with 8 passing tests, confirmed prior-day count 5 and next-day count 0, no missing proof. T2 accepted, T3 now in progress. S1-S4 have verified outcomes. Full precommit result for corrected source: 2621 passed including 6 doctests, 5 skipped; no browser session run (history behavior covered by LiveView tests). No changes to pre-existing shared helpers; no CLI differential applicable.
