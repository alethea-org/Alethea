# Design: Telegram Session Lifecycle — Session Association

**Source:** alethea-org/Alethea#85 · Base: main (contains #84) · Store: hybrid · Strict TDD (`mix test`)

## Technical Approach

Option B (single fetch + thread). Fetch the patient's current open session ONCE per `perform/1` inside `process_bound_message/5`, then pass the plain `session.id` value into all three `save_telegram_message` sites (inbound, safe-path outbound, crisis-path outbound). No context, schema, or migration change — `Clinical.save_telegram_message/6` and `Message` already accept/persist `session_id`.

## Architecture Decisions

### Decision: Single fetch before the #84 transaction

**Choice:** Call `SessionManager.current_open_session(legacy_patient.id)` once, after `legacy_patient` resolves (worker line 132) and BEFORE the inbound save and the #84 `Repo.transaction` (lines 221-237). Pass `session.id` as a plain integer/uuid.
**Alternatives considered:** Fetch inside `persist_and_enqueue_outbound` (nested inside the transaction).
**Rationale:** `current_open_session/1` itself wraps a `Repo.transaction` + `pg_advisory_xact_lock`. Calling it inside the #84 transaction risks advisory-lock reentrancy / nested-transaction coupling. Fetching once outside and threading a plain value avoids that entirely and matches the WhatsApp `ProcessMessageWorker` pattern (fetch once, reuse for inbound + outbound).

### Decision: Thread session.id to crisis outbound too

**Choice:** Crisis-path outbound Message also carries `session.id`.
**Alternatives considered:** Only safe-path outbound.
**Rationale:** AC has no safe-path qualifier; crisis outbound is a real clinical row and must group into the same session. Zero extra cost — same single fetch.

### Decision: No timeout worker (defer to #86)

**Choice:** #85 does open/renew + threading only; no `SessionTimeoutWorker` scheduling. Window grouping validated by explicit `SessionManager.close_session/1` in tests.
**Rationale:** `current_open_session/1` has no staleness logic; auto-close is the WhatsApp-specific, phone/whatsapp_client-coupled `SessionTimeoutWorker` — #86's territory. Keeps scope clean, no misfire landmine.

## Data Flow

    perform → process_bound_message
       └─ legacy_patient resolved (line 132)
          └─ {:ok, session} = SessionManager.current_open_session(legacy_patient.id)   ← ONCE, outside txn
             ├─ inbound  save_telegram_message(..., session.id)
             ├─ safe:   handle_safe_path → persist_and_enqueue_outbound
             │            └─ Repo.transaction (#84) → save_telegram_message(..., session.id)  ← plain value only
             └─ crisis: handle_crisis_path → save_telegram_message(..., session.id)

## File Changes

| File | Action | Description |
|------|--------|-------------|
| `lib/alethea/jobs/telegram_message_worker.ex` | Modify | Add `alias Alethea.Clinical.SessionManager`; single fetch; thread `session.id` into 3 saves (arity bumps below) |
| `test/alethea/jobs/telegram_message_worker_test.exs` | Modify | Net-new session-membership tests (a/b/c) |

### Exact edits

1. **Alias:** extend to `alias Alethea.Clinical.SessionManager` (add line; `Clinical` alias stays).
2. **Fetch:** after `legacy_patient = Accounts.get_patient_with_professional(legacy_patient.id)` (line 132), before the inbound save, insert `{:ok, session} = SessionManager.current_open_session(legacy_patient.id)`.
3. **Inbound save:** add `session.id` as 6th arg to `save_telegram_message(foundation_patient, text, "inbound", "spontaneous", to_string(telegram_message_id), session.id)`.
4. **Safe branch call:** `handle_safe_path(foundation_patient, chat_id, chat_id_hash, hash_prefix, inbound, text, session.id)`.
5. **Crisis branch call:** `handle_crisis_path(foundation_patient, legacy_patient, chat_id, chat_id_hash, hash_prefix, inbound, level, triggers, session.id)`.

### Arity changes

| Function | Before | After |
|----------|--------|-------|
| `handle_safe_path/6` | `(fp, chat_id, hash, prefix, inbound, text)` | `/7` add `session_id`; forward to `persist_and_enqueue_outbound/7` |
| `persist_and_enqueue_outbound/6` | `(fp, chat_id, hash, prefix, chain_result, inbound_id)` | `/7` add `session_id`; pass as 6th arg to outbound `save_telegram_message` inside the txn |
| `handle_crisis_path/8` | `(fp, lp, chat_id, hash, prefix, inbound, level, triggers)` | `/9` add `session_id`; pass as 6th arg to crisis outbound `save_telegram_message` |

`Clinical.save_telegram_message/6` (`session_id \\ nil`, clinical.ex:134-140) already forwards to `save_message/8` → insert attrs; no context/schema change. `Message` has `belongs_to(:session)` + `:session_id` in cast.

## Interfaces / Contracts

No new public interface. `session.id` is a plain value threaded through private functions. No API/JSON contract change.

## Testing Strategy

| Layer | What to Test | Approach |
|-------|-------------|----------|
| Integration (worker) | (a) same session on two messages | Two `perform/1` calls; `Repo` assert both inbound `Message` rows share equal non-nil `session_id` |
| Integration (worker) | (b) new session after close | `perform` → `SessionManager.close_session/1` → `perform`; assert second inbound `session_id` differs |
| Integration (worker) | (c) session_id on outbound | Safe-path: assert inbound + outbound rows carry `session_id`; crisis-path (CrisisMonitor `:crisis` fixture): assert crisis outbound carries it, via `Repo` |
| Guard | No auto-close scheduled | `refute_enqueued(worker: AletheaJobs.SessionTimeoutWorker)` |

Existing seam: `test/alethea/jobs/telegram_message_worker_test.exs` (DataCase + Oban.Testing + Mox PhiWorkerMock/Client.Fake + FoundationTestHelper). Net-new patterns — no worker-level session test to mirror.

## Threat Matrix

N/A — no routing, shell, subprocess, VCS/PR automation, executable-file classification, or process-integration boundary. Change is internal value threading within one Oban worker.

## Idempotency / Rollback

- **Single fetch outside the transaction:** if the #84 `Repo.transaction` rolls back, the inbound save and the session row are NOT unwound together with it — but `current_open_session/1` at worst created an *empty open* Session. An empty open session is harmless and is reused on Oban retry (`current_open_session` returns the same open row). No orphaned clinical content; explicitly acceptable.
- **Pre-existing duplicate `telegram_message_id` MatchError:** untouched. It still surfaces (Oban retry-eligible); not fixed here as a side effect. On retry the same open session is reused.
- **Encryption:** `session_id` is plaintext row metadata alongside `patient_id`; `get_dek`/`PatientVault.encrypt` path untouched. Patient-level encryption preserved.
- **Rollback plan:** revert the single worker commit; threading is additive (`session_id` default `nil`), no migration.

## Migration / Rollout

No migration required. Additive; no feature flag.

## Open Questions

- [ ] Optional one-line fix for stale `@moduledoc` (lines 51-59) claiming the crisis branch raises `NotImplementedError` — it does not (doc drift only). Non-blocking.
- [ ] Deferred #86 boundary: automatic Telegram auto-close / channel-neutral `SessionTimeoutWorker` — out of scope; PR must state auto-close is not live until #86.
