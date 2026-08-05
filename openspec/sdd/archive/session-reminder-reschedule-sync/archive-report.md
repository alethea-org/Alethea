# Archive Report — session-reminder-reschedule-sync (#102)

**Change:** cancel a stale Telegram session reminder when a patient's schedule changes (cancel-on-change).
**Issue:** alethea-org/Alethea#102 (CLOSED). Follow-up of #97.
**PR:** #105 (squash-merged to `main` as `e055d76`).
**Status:** ✅ shipped, verified, adversarially reviewed (3 judges), merged.
**Store:** hybrid (Engram topic keys `sdd/session-reminder-reschedule-sync/*`).

## What shipped

When a professional edited a patient's session schedule, the reminder already scheduled for the old session still fired ("tienes una sesión programada para mañana" for a moved session), and a second reminder later enqueued for the new day. This retires that staleness with a **cancel-only** fix:

- New `AletheaJobs.SessionReminderWorker.cancel_pending/1` cancels pending (`scheduled`/`available`/`retryable`) reminder jobs for a `patient_id` via `Oban.cancel_all_jobs/1` (Ecto query: worker-string pin + state filter + `fragment("args->>'patient_id' = ?")`).
- Called **best-effort** (`try/rescue`) from `AletheaWeb.DashboardLive` immediately after a successful `Accounts.update_patient_session_schedule/3`.
- No re-enqueue at schedule-change time — the plaintext Telegram `chat_id` is not in scope in the professional dashboard context (never at rest, one-way HMAC). The next inbound Telegram message re-enqueues for the new schedule via the unchanged `schedule_session_reminder/3` path.
- `Alethea.Accounts` stays **Oban-free** (the hexagonal boundary #97 established). The patient id matches with no mapping — the reminder args carry the legacy `Accounts.Patient` id, exactly what `DashboardLive` holds.

## Delivery

Single PR (~170 lines incl. tests). Full SDD cycle + apply run **inline on Opus** (ccm/MiniMax unavailable). Strict TDD. `mix precommit` green (577 passed) at merge.

**Deviation from the locked design (accepted):** `Oban.cancel_all_jobs/1` only returns `{:ok, non_neg_integer()}` (it raises on genuine failure), so the call site uses `try/rescue` rather than an `{:error, _}` `case` — Elixir 1.20's set-theoretic type checker proves the error clause statically unreachable. `@spec` narrowed accordingly. Same best-effort intent.

## Judgment Day (3 judges: jd-judge-a + jd-judge-b + review-risk)

- **0 CRITICAL / 0 SEVERE — nothing merge-blocking.** All three confirmed the id-match, query correctness, patient scoping, and non-vacuous tests.
- **Convergent finding (3/3) — fixed in-PR:** the cancel query filtered only `scheduled`/`available`, so a reminder that fired, raised, and was awaiting a retry (`max_attempts: 3`, state `retryable`) would survive and deliver the stale reminder. `retryable` was added to the filter (+ a regression test). `executing` intentionally excluded (an in-flight send cannot be recalled).
- **Defense-in-depth — added in-PR:** an `@doc` authorization note on `cancel_pending/1` — it scopes only by `patient_id`, so callers MUST pre-authorize the id (the sole caller resolves it via `Accounts.get_patient_for_professional/2`; no IDOR today).
- **Documented as accepted (not fixed):** a TOCTOU race (an inbound message reading the old schedule could enqueue a stale reminder just after cancel — self-heals on the next inbound); and no audit-trail row for the cancel (internal job cleanup, not a clinical-data access event).

## Follow-ups

- **#101** — patient-identity channel-neutralization (legacy WhatsApp schema strip) — still open, independent, larger.

## Feature status

Both #97 judgment-day follow-ups are now resolved (this #102 and the in-PR fix in #97 itself). The Telegram reminder story from PRD #83 is fully closed out; only the unrelated #101 schema strip remains.
