Closes #85.

## What

Associates inbound and outbound Telegram `Message` rows with the patient's current open therapeutic `Session` — mirroring the WhatsApp channel's behavior, so the clinical transcript of a patient's Telegram journaling is grouped into the same session row the WhatsApp path already uses.

Single `SessionManager.current_open_session(legacy_patient.id)` call per `perform/1` (outside the #84 `Repo.transaction`), with the returned `session.id` threaded through three save sites:

- **Inbound** `Clinical.save_telegram_message/6` (inbound direction)
- **Safe-path outbound** `Clinical.save_telegram_message/6` inside the #84 transaction (arity bumped on `handle_safe_path/6 → /7` and `persist_and_enqueue_outbound/6 → /7`)
- **Crisis-path outbound** `Clinical.save_telegram_message/6` (`handle_crisis_path/8 → /9`)

No schema change, no migration, no new Oban worker. `Clinical.save_telegram_message/6` already accepted `session_id \ nil` from a previous change; this PR just passes a real value.

### OpenSpec artifacts (linked for reviewer)

- `openspec/sdd/telegram-session-lifecycle/proposal.md`
- `openspec/sdd/telegram-session-lifecycle/spec.md` (8 requirements, scenarios)
- `openspec/sdd/telegram-session-lifecycle/design.md` (Option B scope, idempotency/rollback analysis)
- `openspec/sdd/telegram-session-lifecycle/tasks.md` (9 Strict-TDD phases)
- `openspec/sdd/telegram-session-lifecycle/verify-report.md` (PASS WITH WARNINGS, 0 CRITICAL)
- `openspec/sdd/telegram-session-lifecycle/judgment-round{1,2,3}.md` are stored in Engram (not in repo) — search `sdd/telegram-session-lifecycle/judgment-round*`.

## Why

Without session association, the clinical RAG cannot answer "what did Juan journal this week on Telegram?" as part of the patient's session — each inbound was its own row with no clinical-continuity grouping. WhatsApp already had this (via its `ProcessMessageWorker`); Telegram needed the same to make the session boundary the unit of clinical continuity across channels.

## Out of scope (deferred, tracked)

**Automatic Telegram inactivity auto-close is NOT live in this PR.** That requires a channel-neutral `SessionTimeoutWorker` (deferred to #86). Until then, a Telegram session stays open until explicitly closed via `SessionManager.close_session/1`. This PR is open/renew + threading only; the commit body records this explicitly.

Pre-existing bare matches in the worker that #85 did not introduce and did not worsen (carried forward, follow-up PR candidate):

- `worker.ex:521-522` — `{:ok, _updated_patient} = Accounts.update_patient(...)` (no PHI in changeset)
- `worker.ex:525-530` — `{:ok, _diagnosis} = Clinical.save_ai_diagnosis(...)` (pre-existing; `ai_response: crisis_text` here is operator-authored `professional.crisis_message`, not patient-supplied PHI per this code path)
- `worker.ex:311-313, 374-376` — enqueue `inspect(reason)` sites (pre-existing)

The pre-existing duplicate `telegram_message_id` retry `MatchError` is **untouched** as required (out of scope; Oban retry behavior unchanged).

## Verification

- `mix precommit` → exit 0, **574 passed (2 doctests + 572 tests), 5 skipped** (compile `--warnings-as-errors` + format + full suite).
- Focused: `mix test test/alethea/jobs/telegram_message_worker_test.exs` → **41 passed** (36 pre-existing + 5 new).
- New tests assert (via `%Oban.Job{args: build_args(...)} |> TelegramMessageWorker.perform/1`):
  - Same `session_id` on two consecutive inbound messages (same-session reuse)
  - New `session_id` after explicit `SessionManager.close_session/1` (window reset)
  - Safe-path outbound `session_id` equals inbound `session_id`
  - Crisis-path outbound `session_id` equals inbound `session_id`
  - `refute_enqueued(worker: AletheaJobs.SessionTimeoutWorker)` guard
- `#84` `Repo.transaction` semantics, rollback tests, and PHI-redaction safe-path tests all still pass unmodified.
- `verify-report.md` confirms 0 CRITICAL across all 8 spec requirements and 9 scenarios; the 3 WARNINGs are documented and carried forward.

## Adversarial review (judgment-day) — APPROVED ✅

Two blind judges (sonnet) reviewed the diff; two bounded correction rounds were applied and re-verified.

### Round 1 — CRITICAL closed

The inbound save used a bare `{:ok, _} = Clinical.save_telegram_message(...)` match. On persistence failure the exception is `MatchError` with the Ecto.Changeset as its value; `inspect(%Ecto.Changeset{})` embeds the `changes` map. Before #85 the changeset carried `session_id: nil`; after #85 it carries the real session UUID. Oban captures the exception value into `oban_jobs.errors` and exception logs — clinical metadata leak to operational data.

Fixed in `285b14d`: case wrap + `raise` via the existing `safe_reason/1` helper (same helper used for the safe-path transaction error from #84). Updated the pre-existing `MatchError` failure-mode test to assert `RuntimeError` + the literal raise substring.

### Round 2 — same regression class on crisis outbound

The crisis outbound save at `worker.ex:554-562` is structurally identical to the inbound site — same bare match, same `Changeset`-with-`session_id` return path. #85 worsened it the same way it worsened the inbound (Judge B CRITICAL; Judge A explicitly disagreed; human escalated and decided fix).

Fixed in `7bb409d` with the same case wrap + `safe_reason/1`. Test strengthening: `test.exs:468-512` now pre-fetches the open session UUID and asserts `refute error.message =~ session_uuid` — runtime proof of absence, mirroring the sibling diagnosis-leak test at `test.exs:609-639` which uses `refute error.message =~ sentinel_reply`.

### Final verdict (Round 3)

0 CRITICAL. 4 WARNINGs carry-forward (concurrent close race, exact-once test gap, no-timeout crisis coverage, crisis path non-atomic — all pre-existing or coverage gaps). 1 suspect recorded: crisis-outbound failure-mode test still missing direct coverage (Judge B only). Pre-existing bare matches confirmed unchanged by both fix commits.

## Follow-ups (non-blocking, tracked separately)

1. Add crisis-outbound failure-mode test (mirror of `test.exs:468-512` in the crisis describe block `test.exs:647-883`) — closes the Round-3 suspect.
2. Audit the other crisis-path bare matches at `worker.ex:521-522` and `worker.ex:525-530` — wrap each in `safe_reason/1`-guarded case as a focused refactor PR.
3. Wrap the enqueue `inspect(reason)` sites at `worker.ex:311-313` and `worker.ex:374-376` with a `safe_reason/1` analog (they can include `Oban.Job` changesets with `args.body` for the safe path).
4. Add a runtime call-count assertion for `SessionManager.current_open_session/1` (Mox / Telemetry / inject) — closes the exact-once test gap.
5. #86 channel-neutral `SessionTimeoutWorker` — closes the concurrent close race, the no-timeout crisis coverage gap, and the crisis path non-atomic WARNING in one shot (atomic patient update + diagnosis + outbound save inside one transaction).

## Test counts

| Stage | Tests | Delta | Failures | Skipped |
|---|---|---|---|---|
| `main` (baseline, #84 merged) | 569 | — | 0 | 5 |
| Apply (`5fc134d`) | 574 | +5 | 0 | 5 |
| R1 fix (`285b14d`) | 574 | 0 (test refactor only) | 0 | 5 |
| R2 fix (`7bb409d`) | 574 | 0 (test strengthening only) | 0 | 5 |

## Files changed (cumulative diff vs `main`)

| File | Change |
|------|--------|
| `lib/alethea/jobs/telegram_message_worker.ex` | Add `SessionManager` alias; single `current_open_session/1` fetch outside the #84 transaction; thread `session.id` into 3 save sites; wrap inbound + crisis-outbound bare matches in `safe_reason/1`-guarded case (R1 + R2) |
| `test/alethea/jobs/telegram_message_worker_test.exs` | 5 net-new session-membership tests; update pre-existing failure-mode test twice (R1: `MatchError` → `RuntimeError`; R2: + `refute session_uuid`) |
| `openspec/sdd/telegram-session-lifecycle/{exploration,proposal,spec,design,tasks}.md` | Phase 0–4 SDD artifacts |
| `openspec/sdd/telegram-session-lifecycle/verify-report.md` | Phase 6 verify output |

Cumulative: 8 files, +819 / −35.

## Commits

```
7bb409d fix(worker): prevent changeset leak on crisis outbound persistence failure
285b14d fix(worker): prevent changeset leak on inbound persistence failure
2fa9dc6 docs(sdd): add telegram-session-lifecycle verify-report
5fc134d feat(worker): associate Telegram messages with sessions
09524e7 docs(sdd): add telegram-session-lifecycle planning artifacts (#85)
```
