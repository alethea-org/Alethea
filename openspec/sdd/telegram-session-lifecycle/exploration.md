# Exploration — telegram-session-lifecycle

**Source issue:** alethea-org/Alethea#85 — "Telegram session lifecycle: group messages into therapeutic sessions"
**Artifact store:** hybrid (mirrored to Engram `sdd/telegram-session-lifecycle/explore`)
**Strict TDD:** active — `mix test`. Base: main (contains #84).

## Key finding

`Alethea.Clinical.SessionManager.current_open_session/1` (lib/alethea/clinical/session_manager.ex:12-43) is a **pure "is there an open row" lookup with NO time-based freshness check**. It wraps a `Repo.transaction` + Postgres advisory lock keyed on `:erlang.phash2(patient_id)`, queries `patient_id == ^id and status == "open" limit 1`, and if none exists inserts a new open Session. There is **no staleness/timestamp filter** — any `status: "open"` row is returned regardless of age. `patient_id` is the LEGACY `Alethea.Accounts.Patient.id`, not the foundation UUID. `close_session/1` sets `status: "closed"`, `closed_at: now`.

**Consequence:** the "active window"/"inactivity timeout" is NOT a SessionManager concept. Closing a stale session only happens when `SessionTimeoutWorker` fires and sets `status: "closed"`.

## Reference pattern — WhatsApp `AletheaJobs.ProcessMessageWorker`

- Line 91: `{:ok, session} = SessionManager.current_open_session(patient.id)` — fetched once per perform, before crisis/safe branching; reused for inbound + outbound `save_message/8`.
- After every inbound save (safe AND crisis), calls `schedule_session_timeout(session, patient, phone)`: inserts a `SessionTimeoutWorker` job `scheduled_at: now + 30min` with Oban `unique` + `replace: [:scheduled_at]` — so each new message PUSHES the close-timer out 30 min. **This is the real window-renewal mechanism.** Without it, a session never closes.

## SessionTimeoutWorker (AletleaJobs.SessionTimeoutWorker)

`perform/1` pattern-matches `%{"session_id", "patient_id", "phone" => phone}` — **hardcoded to `phone` + `whatsapp_client().send_message/2`** for the goodbye (line 59). Closes session, generates summary/trends (RoBERTa + SessionSummaryChain), sends goodbye. NOT channel-neutral — this is #86's territory (channel-neutral goodbye + summary). Cannot be reused as-is for Telegram (would crash on arg pattern or call the wrong adapter).

## Telegram safe path (post-#84) — injection points

`Alethea.Jobs.TelegramMessageWorker`:
- `process_bound_message/5` (~110-162): resolves `legacy_patient` at line 131, then a SINGLE shared inbound save for both branches: `{:ok, inbound} = Clinical.save_telegram_message(foundation_patient, text, "inbound", "spontaneous", to_string(telegram_message_id))`.
  → INJECT: `SessionManager.current_open_session(legacy_patient.id)` right after line 132 (legacy_patient already resolved), pass `session.id` as the 6th arg.
- `handle_safe_path/6` → `persist_and_enqueue_outbound/6` (~202): outbound save is inside the #84 `Repo.transaction` (221-237).
  → INJECT: thread `session.id` (fetched ONCE at top, not re-fetched) through as a new arg to the outbound `save_telegram_message`.
- `handle_crisis_path/8` (~477): ALSO persists an outbound Message (523-530) — unlike WhatsApp crisis. Needs `session.id` threaded too if crisis outbound should carry session association (open question for propose).

## Clinical plumbing already ready

`save_telegram_message(foundation_patient, text, direction, behavior_type, telegram_message_id, session_id \\ nil)` already accepts `session_id` and forwards to `save_message/8`, which puts `session_id` into insert attrs unconditionally. `Message` schema has `belongs_to(:session, ...)` and `:session_id` in the cast list. So NO context plumbing needed — just have the worker pass the value.

## Encryption

`save_message/8` routes through `get_dek` + `PatientVault.encrypt/2`; `session_id` is plaintext row metadata alongside `patient_id`, not inside the encrypted payload. Threading it does not touch the encryption path. Patient-level encryption preserved.

## SCOPE BOUNDARY — decision for propose (Option A vs B)

AC "a message after the inactivity window starts a new session" REQUIRES something to close the stale session, but `current_open_session` has no time logic — closing only via `SessionTimeoutWorker` (WhatsApp-specific, #86's territory).

- **Option A** — #85 also schedules a Telegram-flavored timeout now, accepting it will misfire (wrong send adapter / arg mismatch) until #86 generalizes the close flow. End-to-end window behavior sooner, but a known landmine.
- **Option B (recommended)** — #85 does open/renew fetch + `session_id` threading only; no timeout scheduling. Tests validate window grouping by calling `SessionManager.close_session/1` directly to simulate an elapsed window; PR states automatic Telegram auto-close is not live until #86. Clean scope, no landmine, matches the literal #85/#86 split.

Secondary: crisis-path outbound (`handle_crisis_path` 523-530) also calls `save_telegram_message` — AC has no safe-path qualifier, so crisis outbound likely needs `session.id` too (low cost, same single fetch). Confirm in propose.

Ordering: no conflict with #84 `Repo.transaction` — call `current_open_session` ONCE before the transaction, pass `session.id` as a plain value; no nested SessionManager call inside the outbound transaction.

## Test seams

- `test/alethea/clinical/session_manager_test.exs` — unit tests open/renew/close; NO time-elapsed test exists.
- `test/alethea_jobs/process_message_worker_test.exs` — asserts ZERO session membership (grep "session" = 0). So there is NO existing worker-level "same/different session_id" test to mirror; this is net-new test surface.
- `test/alethea/jobs/telegram_message_worker_test.exs` — DataCase + Oban.Testing + Mox (PhiWorkerMock, Client.Fake), `%Oban.Job{args} |> perform()`, FoundationTestHelper. Add here: (a) same-session-on-two-messages, (b) new-session-after-explicit-close (via SessionManager.close_session/1), (c) session_id present on both inbound and outbound rows.

## Risks

1. Scope-boundary A vs B must be resolved before tasks or the "inactivity window" AC is under-covered.
2. SessionTimeoutWorker reuse-as-is for Telegram misfires on phone/whatsapp_client assumptions.
3. Pre-existing MatchError on duplicate telegram_message_id (Oban retry-eligible) — untouched, will still surface; don't "fix" as a side effect.
4. Stale @moduledoc in telegram_message_worker.ex claims crisis branch raises NotImplementedError; it does not — doc drift, one-line fix note.
5. No existing worker-level session-membership test — net-new patterns needed.

**Ready for proposal:** yes (after A/B + crisis-outbound resolved).
