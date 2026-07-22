# Proposal: Telegram Session Lifecycle — Session Association

**Source:** alethea-org/Alethea#85 · Base: main (contains #84) · Store: hybrid · Strict TDD (`mix test`)

## Intent

Telegram messages are persisted session-less: `TelegramMessageWorker` never associates a `session_id`, so inbound/outbound rows cannot be grouped into therapeutic sessions, summarized, or trended. WhatsApp already does this via `SessionManager.current_open_session/1`. This change gives Telegram the same session grouping so clinical continuity works across both channels.

## Scope

### In Scope
- Fetch `SessionManager.current_open_session(legacy_patient.id)` ONCE in `process_bound_message`, after `legacy_patient` resolves, before the #84 `Repo.transaction`.
- Thread `session.id` (plain value) into 3 save sites: (1) shared inbound `save_telegram_message`, (2) safe-path outbound in `persist_and_enqueue_outbound`, (3) crisis-path outbound in `handle_crisis_path`.
- Tests: same-session on two messages; new session after explicit `SessionManager.close_session/1`; `session_id` present on inbound AND outbound rows.

### Out of Scope (deferred to #86)
- Scheduling any Telegram `SessionTimeoutWorker` / automatic inactivity auto-close.
- Channel-neutralization of the WhatsApp-specific `SessionTimeoutWorker`.
- Session summaries, trends, goodbye routing.
- Pre-existing duplicate `telegram_message_id` MatchError (leave untouched).
- Stale crisis-branch `@moduledoc` (NotImplementedError) — drift note only, optional one-liner.

## Capabilities

### New Capabilities
- `telegram-session-association`: inbound and outbound Telegram messages are associated with the patient's current open therapeutic session; window grouping is validated by explicit close, not automatic timeout.

### Modified Capabilities
- None.

## Approach

Single fetch + thread (Option B). `current_open_session/1` is a pure "open row" lookup with no time logic, so it opens-or-reuses one session; call it once and pass `session.id` as a plain arg to the three saves. No nested SessionManager call inside the #84 transaction (avoids advisory-lock reentrancy). `save_telegram_message/6` already accepts `session_id`; `Message` schema already has the assoc — no context/schema plumbing. #85 does open/renew + threading ONLY; automatic auto-close is #86. Tests simulate an elapsed window with `close_session/1`.

## Affected Areas

| Area | Impact | Description |
|------|--------|-------------|
| `lib/alethea/jobs/telegram_message_worker.ex` | Modified | Single fetch + thread `session.id` into 3 saves |
| `test/alethea/jobs/telegram_message_worker_test.exs` | Modified | Net-new session-membership tests |

## Risks

| Risk | Likelihood | Mitigation |
|------|------------|------------|
| No auto-close → sessions never expire on Telegram until #86 | Med | Explicit #85/#86 boundary; PR states auto-close not live |
| Nested SessionManager call deadlocks #84 transaction | Low | Fetch once before transaction; pass plain value |
| Net-new worker-level session test patterns | Low | Mirror inbound/outbound assertions; close via `close_session/1` |

## Rollback Plan

Revert the single worker commit. Threading is additive (`session_id` default `nil`); no migration, no schema change — reverting restores session-less behavior with zero data impact.

## Dependencies

- #84 (safe-path `Repo.transaction`) — already on main.

## Success Criteria

- [ ] Inbound + safe-path + crisis-path outbound Telegram Messages carry `session_id`.
- [ ] Two messages within one open session share the same `session_id`.
- [ ] A message after explicit `close_session/1` gets a new `session_id`.
- [ ] `mix test` green; no timeout worker scheduled by Telegram path.
