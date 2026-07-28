# Design: session-timeout-channel-neutral (#86)

## Technical Approach

Two independent PRs. **PR-1 (Goal 1)**: make `SessionTimeoutWorker` channel-neutral by threading `channel` + routing identifiers through Oban job args (exploration Approach 3 — no migration, no `SessionManager`/`Session` touch), then enqueue the timeout from `telegram_message_worker.ex` after the inbound save. **PR-2 (Goal 2)**: wrap the three crisis writes in one `Repo.transaction`, move broadcast + enqueue strictly post-commit. PR-2 touches a different function (`handle_crisis_path/9`) and is independent of PR-1.

## Architecture Decisions

| Decision | Choice | Rejected alternatives | Rationale |
|----------|--------|-----------------------|-----------|
| Channel dispatch | Thread `channel` + `chat_id`/`chat_id_hash` via Oban args at enqueue | (a) new `channel` column; (b) reverse legacy→foundation lookup | Raw `chat_id` is never persisted at rest (only HMAC hash); only args can carry it. Column/lookup cannot supply the send target and would force `SessionManager` changes the fixed decisions forbid. |
| Goodbye delivery (Telegram) | Enqueue `TelegramOutboundWorker` (safe lane) directly from the timeout worker | Call `Telegram.Client` inline | Matches existing outbound pattern (Pacer rate-limit, retry, dead-letter). `perform/1` reads only `chat_id`/`chat_id_hash`/`body` — no persisted Message row needed, so no outbound Message is saved for the goodbye. |
| WhatsApp back-compat | Absent `channel` + present `phone` → default `"whatsapp"` | Require `channel` everywhere | Preserves the exact `%{session_id,patient_id,phone}` args shape; the 2 existing worker tests stay green unmodified. |
| Crisis atomicity | Single `Repo.transaction` for update_patient + save_ai_diagnosis + crisis-outbound save; side effects post-commit | Leave sequence as-is | Mirrors the safe-path fix at `persist_and_enqueue_outbound` (#84). Closes R1-W4: no fabricated broadcast/alert without a backing outbound row. |

## Data Flow

PR-1 close flow (unchanged core, channel-dispatched send):

    perform(args) → resolve channel → run_close_flow (close → decrypt → sanitize
      → RoBERTa → save_trends → summary → save_summary) → send_goodbye/2:
        whatsapp → whatsapp_client().send_message(phone, msg)
        telegram → Oban.insert(TelegramOutboundWorker, %{chat_id, chat_id_hash, body})

PR-2 crisis (reordered):

    Repo.transaction( update_patient → save_ai_diagnosis → save crisis outbound )
      └ {:ok,_} → PubSub broadcast → enqueue_outbound(lane: :crisis)
      └ {:error,r} → raise safe_reason(r)   # no broadcast, no enqueue

## File Changes

| File | Action | Description |
|------|--------|-------------|
| `lib/alethea_jobs/session_timeout_worker.ex` | Modify | `perform/1` accepts both arg shapes; extract `send_goodbye/2` channel switch; `run_close_flow` returns the send target instead of hardcoding `phone`. Optional: add `telegram_client`/outbound enqueue helper. |
| `lib/alethea/jobs/telegram_message_worker.ex` | Modify | PR-1: enqueue timeout after inbound save (post line 151, one call site — both branches). PR-2: transaction wrap of `handle_crisis_path/9` (521-578) + post-commit reorder. Optional: fix stale `@moduledoc` (51-59). |
| `lib/alethea_jobs/process_message_worker.ex` | Unchanged | WhatsApp `schedule_session_timeout` args stay valid via default. |
| `test/alethea_jobs/session_timeout_worker_test.exs` | Preserve + add | 2 existing tests unmodified; add Telegram goodbye + channel-dispatch tests. |
| `test/alethea/jobs/telegram_message_worker_test.exs` | Modify | Replace `refute_enqueued` (446-458) with `assert_enqueued` + renewal (`replace: [:scheduled_at]`) coverage; add R3 crisis-failure test. |

## Interfaces / Contracts

Telegram timeout args (enqueued in `process_bound_message`, mirroring WhatsApp's Oban options — `unique: [fields: [:args]]`, `Oban.insert!(replace: [:scheduled_at])`, `scheduled_at: now + 30 min`):

    %{session_id: session.id, patient_id: legacy_patient.id,
      channel: "telegram", chat_id: chat_id, chat_id_hash: chat_id_hash}

`patient_id` is the **legacy** id (`run_close_flow` calls `Accounts.get_patient!/1` + legacy DEK). The goodbye `TelegramOutboundWorker` enqueue passes `patient_id: nil` (nil-safe dead-letter path; goodbye is non-crisis) — foundation UUID is not threaded to keep args minimal.

## Testing Strategy

| Layer | What | Approach |
|-------|------|----------|
| Unit (worker) | WhatsApp default (no channel) still sends via `whatsapp_client` | 2 existing tests unchanged |
| Unit (worker) | Telegram channel closes session, saves summary/trends, enqueues `TelegramOutboundWorker` goodbye | Mox/fake client; `assert_enqueued` |
| Integration | Timeout enqueued after Telegram inbound (safe + crisis); renewal upserts `scheduled_at` | Replace 446-458 with `assert_enqueued` + renewal |
| Integration (R3) | Force diagnosis changeset invalid inside crisis txn via `perform/1`: assert (a) patient flag not flipped / no diagnosis row / 0 crisis-outbound rows, (b) no PHI in raise, (c) crisis PubSub did NOT fire, (d) refute enqueue | Subscribe `psychologist:alerts`, `refute_receive`; `refute_enqueued` |

Strict TDD: RED before each change; every AI-pipeline touch keeps the sentiment regression test.

## Threat Matrix

N/A — no routing, shell, subprocess, VCS/PR automation, executable-file classification, or process-integration boundary. Change is intra-app Oban/Ecto wiring.

## Migration / Rollout

No migration required (no schema/column change). Two independent PRs → revert either commit independently.

## Open Questions

- [ ] Confirm goodbye outbound `patient_id: nil` is acceptable (vs threading foundation UUID for dead-letter correlation). Default: nil.

## Accepted / Deferred Risks

- **R1-W1 staleness race** goes live for Telegram once the worker fires (a late inbound may attach to an already-closed session, silently excluded from that summary). ACCEPTED/DEFERRED — mirrors WhatsApp's pre-existing accepted race; blast radius = one late message, no crash/corruption. Do **not** change `current_open_session/1`.
- **Broadcast reorder** to post-commit is a required Goal-2 sequencing change (was pre-outbound-save), not scope creep.
- **Duplicate `telegram_message_id` MatchError** (pre-existing) is untouched — the inbound save sits outside both the timeout enqueue and the crisis transaction. Worker idempotency ("skip if closed") plus crisis rollback-on-failure keep retries safe.
