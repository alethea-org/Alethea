# Proposal: Telegram Patient Foundation

**Change:** `telegram-paciente-foundation`
**Status:** Draft (proposal phase)
**Owner:** Alethea engineering
**Depends on:** v2 foundation (`bootstrap-alethea-v2`, archived), ADR-004

---

## Why

Alethea's patient surface is Telegram by ADR-004, but **no Telegram gateway exists yet** — `foundation_patients.telegram_chat_id` is a column with no producer, no consumer, no encryption, and no onboarding. The patient cannot journal, cannot trigger crisis detection, and cannot feed the RAG. This slice closes that gap.

It is also the moment to **fix a security gap**: the WhatsApp stack HMAC-hashes `whatsapp_number` for lookup, but `telegram_chat_id` is currently stored un-encrypted and looked up by raw value. The foundation must not repeat that mistake — hashing is the first line of code, not a follow-up.

The architecture is well-known territory: the WhatsApp controller + worker + client are the reference implementation. Telegram is a **channel swap with stricter webhook auth**, not a greenfield system.

---

## What Changes

- New `AletheaWeb.TelegramWebhookController` (POST `/webhooks/telegram`) validating `X-Telegram-Bot-Api-Secret-Token`, fast-ack 200, enqueueing an Oban job.
- New `AletheaJobs.TelegramMessageWorker` (Oban, idempotent by `update_id`) that persists `Message`, runs RoBERTa emotion, calls LLM, applies crisis bypass, and sends a Telegram reply.
- New `Alethea.Telegram.Client` (Req-based, behind a behaviour, with a `Fake` adapter for tests) — structural twin of `Alethea.Whatsapp.Client`.
- Column rename `foundation_patients.telegram_chat_id` → `telegram_chat_id_hash`; HMAC-SHA256 with `psychologist_id` pepper; pepper sealed in `Alethea.Encryption.Vault`.
- New deep-link onboarding flow `t.me/<bot>?start=<token>` (ephemeral, single-use, short TTL, rate-limited); 6-digit code retained as fallback.
- Bot token sealed in `Alethea.Encryption.Vault`; distinct dev/test/prod entries.
- Outbound sends routed through an Oban queue with back-pressure, 429 retry, and a priority lane for crisis bypass.

---

## Decisions Encoded (locked — do not re-litigate in spec)

- **Q1 — Scope:** gateway + full primer clinical round-trip (RoBERTa + LLM reply + crisis bypass). Direct port of the WhatsApp `process_message_worker` flow.
- **Q2 — Onboarding:** deep link `t.me/<bot>?start=<token>` with ephemeral, single-use, short-TTL, rate-limited token. Six-digit code kept as fallback. Requires an `auth_codes` table or reuse of the existing v2 mechanism — **flag for spec**.
- **Q3 — Identity boundary:** `telegram_chat_id` MUST be HMAC-hashed before persistence and lookup. Column renamed to `telegram_chat_id_hash`. Pepper sealed in `Alethea.Encryption.Vault` per the `encryption-vault` skill.
- **Q4 — Topology:** single global Telegram bot for this foundation. **Multi-bot per psychologist is explicitly out of scope** and will be a separate future change.

---

## Capabilities (cap-scoped, change-relative)

These are the contract with the `sdd-spec` phase. Each becomes a delta or new spec.

| ID | Title | One-liner |
|---|---|---|
| **C-1** | Telegram webhook entrypoint | `POST /webhooks/telegram` validates `X-Telegram-Bot-Api-Secret-Token`, fast-acks 200, enqueues an Oban job. |
| **C-2** | HMAC-hashed `telegram_chat_id` lookup | Column renamed to `telegram_chat_id_hash`; HMAC-SHA256 with per-psychologist pepper; never store or query the raw value. |
| **C-3** | Async message processing (Oban) | `TelegramMessageWorker` is idempotent by `update_id`, persists `Message`, calls emotion + LLM, honours crisis bypass. |
| **C-4** | Deep-link onboarding with ephemeral token | `t.me/<bot>?start=<token>` issues short-TTL, single-use, rate-limited tokens; 6-digit code path retained as fallback; `auth_codes` (or equivalent) table flagged. |
| **C-5** | End-to-end clinical round-trip | Inbound → RoBERTa emotion → LLM reply → crisis bypass → outbound reply, mirroring `process_message_worker`. |
| **C-6** | Vault-sealed bot token | Bot token sealed in `Alethea.Encryption.Vault`; dev / test / prod entries distinct; never plaintext env. |
| **C-7** | Outbound rate-limit & 429 handling | Outbound sends go through an Oban queue with back-pressure, 429 retry with jitter, dead-letter on exhaustion; crisis bypass uses a priority lane. |

---

## Impact

| Area | Impact | Description |
|---|---|---|
| `lib/alethea/foundation/accounts/patient.ex` | Modified | Add `telegram_chat_id_hash`; remove or encrypt the un-encrypted `telegram_chat_id`. |
| `lib/alethea_web/controllers/telegram_webhook_controller.ex` | New | Plug controller, secret-token validation, Oban enqueue. |
| `lib/alethea_jobs/telegram_message_worker.ex` | New | Oban worker, idempotent by `update_id`. |
| `lib/alethea/telegram/client.ex` | New | Behaviour + Req implementation + `Fake` adapter. |
| `lib/alethea/telegram/deep_link_token.ex` | New | Ephemeral token generator/validator. |
| `lib/alethea/encryption/vault.ex` | Extended | Add `bot_token` and `telegram_chat_id_pepper` slots. |
| `priv/repo/migrations/*telegram*` | New | Column rename, `auth_codes` (or reuse), `telegram_deep_link_tokens`. |
| `lib/alethea_web/router.ex` | Modified | `POST /webhooks/telegram` route under a `pipe_through [:telegram_webhook]` scope. |
| `test/alethea_web/controllers/telegram_webhook_controller_test.exs` | New | TDD-first. |
| `test/alethea_jobs/telegram_message_worker_test.exs` | New | TDD-first. |
| `test/alethea/telegram/client_test.exs` | New | Behaviour contract + `Fake` tests. |

---

## Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| **PHI in transport.** Telegram webhooks are cleartext at network layer. | High | Encrypt at rest via Cloak.Ecto on `Message.body`; never log raw payloads; update consent copy to mention Telegram. |
| **Rate limits dropping a crisis message.** 1 msg/s/chat, 30 msg/s global; naive `Req.post` loop is the worst possible failure. | High | All outbound sends through Oban with back-pressure; 429 retry with jitter; crisis-bypass priority lane; dead-letter on exhaustion. |
| **Message reordering.** Telegram does not guarantee webhook ordering. | Med | Persist Telegram `message_id` (monotonic per chat); reconcile on insert before handing context to the LLM. |
| **Webhook spoofing.** Telegram does NOT HMAC-sign payloads — only `X-Telegram-Bot-Api-Secret-Token` set at `setWebhook` time. | Med | Validate the header explicitly; reject otherwise; non-guessable URL. |
| **Bot token blast radius.** A single global token gates every patient's flow. | High | Sealed in `Alethea.Encryption.Vault` (KEK), not plaintext env like the current `WHATSAPP_API_TOKEN`; dev/test distinct. |

---

## Out of Scope

- Multi-bot per-psychologist topology (separate future change — Q4).
- End-to-end encryption of chat contents at the transport layer (Telegram's secret-token is channel authentication; payload content is encrypted at rest via Cloak.Ecto on `Message.body`).
- Voice transcription via Whisper on the Telegram channel (Whisper pipeline exists; not wired to Telegram in this slice).
- Server-initiated scheduled triggers over Telegram (daily check-ins, session reminders — handled by other workers; this slice receives inbound only).
- Message threading UI in the psychologist's LiveView.
- Multi-language NLP beyond what the configured LLM and RoBERTa model already provide.
- Wearable / media ingestion on the Telegram channel.
- Cross-tenant correlation prevention beyond HMAC peppering (out of band for this slice).

---

## Open Questions (for `sdd-spec`)

1. **Auth table.** Does the v2 foundation already ship an `auth_codes` table, or does this slice introduce it? If reusing, what is the migration story to backfill existing patients on their next `/start`?
2. **Deep-link token thresholds.** Confirm proposed values: TTL = 10 min, max 5 attempts / hour / IP. Adjust based on adoption signals.
3. **RateLimiter scale.** What `:scale` / `:limit` values map to Telegram's 1 msg/s/chat and 30 msg/s global on the existing plug? Which Oban queue priority for crisis bypass?
4. **Pepper rotation.** What is the rotation policy for `telegram_chat_id_hash` if the `psychologist_id` salt is ever rotated? What is the cryptographic-erasure impact on lookup tables?
5. **Bot token storage.** Where exactly in `Alethea.Encryption.Vault`? Extend an existing encrypted config table, or new `BotConfig` schema? Single global row or per-environment?
6. **Backfill strategy.** For any pre-existing `foundation_patients.telegram_chat_id` values, hash in the same migration, drop the old column, and require a one-time re-link on next `/start`?
7. **6-digit code path.** Handle legacy 6-digit code through the same controller, or split into a separate `TelegramAuthController` to keep the webhook hot-path tight?
8. **Idempotency window.** How long do we keep `update_id` dedup state? Oban `unique` covers crash-retry; is that enough, or do we need a long-lived `processed_updates` table?
9. **Crisis-bypass queue priority.** Concrete Oban queue name and `max_demand`? Must survive a full outbound rate-limit window.

---

## References

- **Prior art — controller:** `lib/alethea_web/controllers/whatsapp_webhook_controller.ex` (HMAC + RateLimiter + Oban)
- **Prior art — worker:** `lib/alethea_jobs/process_message_worker.ex` (decrypt → RoBERTa → LLM → crisis bypass)
- **Prior art — client:** `lib/alethea/whatsapp/client.ex` (Req-based, behind a behaviour, Fake adapter)
- **ADR-004 — Telegram único canal del paciente:** `openspec/adr/004-telegram-unico-canal-paciente.md`
- **Encryption vault skill:** `.github/skills/encryption-vault/SKILL.md`
- **Context:** `openspec/CONTEXT.md`, `openspec/UBIQUITOUS_LANGUAGE.md`
- **Bootstrap prior proposal:** `openspec/sdd/archive/bootstrap-alethea-v2/proposal.md`
- **OpenSpec config:** `openspec/config.yaml` (strict_tdd, test_runner=`mix test`)

---

## Success Criteria

- [ ] `POST /webhooks/telegram` accepts a real `Update`, persists `Message`, and replies with a coherent Alethea message end-to-end.
- [ ] No raw `telegram_chat_id` ever reaches a `SELECT`, `INSERT`, or log line — only the HMAC hash.
- [ ] Bot token is unreadable in plaintext outside `Alethea.Encryption.Vault.decrypt/1`.
- [ ] Crisis-bypass message survives an outbound rate-limit window under load (regression test).
- [ ] `/start` deep-link path onboards a new patient in one round-trip; 6-digit code fallback still works.
- [ ] `mix precommit` green; `mix test` green; new tests added TDD-first (red → green → refactor).

---

## Rollback Plan

- **Column rename** is forward-only; rollback = restore `telegram_chat_id` from backup and revert the migration (data preserved, not destroyed).
- **Webhook route** is additive; rollback = remove the `:telegram_webhook` scope from `router.ex`.
- **Oban worker** is additive; rollback = drop `TelegramMessageWorker` and its queue.
- **Vault entry** is additive; rollback = delete the bot token vault entry (no other module depends on it yet).
- **Feature flag:** `config :alethea, :telegram_enabled, false` (default `true` post-merge) lets us disable the webhook without a deploy if a regression is found in production.
- **No patient data is destroyed** by any of the above — only the lookup column is renamed/hashed; on rollback, patients remain reachable via the un-encrypted column.
