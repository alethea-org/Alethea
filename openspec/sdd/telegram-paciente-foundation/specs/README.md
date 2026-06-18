# Specs Index — `telegram-paciente-foundation`

**Change:** `telegram-paciente-foundation`
**Status:** Draft (spec phase)
**Pipeline:** SDD on OpenSpec (`strict_tdd: true`, `mix test` runner)
**Chain strategy:** `feature-branch-chain`
**Next phase:** `sdd-tasks`

---

## Capability → Spec File Index

| ID | Capability | Status | Spec file |
|---|---|---|---|
| **C-1** | Telegram webhook entrypoint | ADDED | [`C-1-telegram-webhook-entrypoint/spec.md`](./C-1-telegram-webhook-entrypoint/spec.md) |
| **C-2** | HMAC-hashed `telegram_chat_id` lookup | MODIFIED | [`C-2-hmac-chat-id-lookup/spec.md`](./C-2-hmac-chat-id-lookup/spec.md) |
| **C-3** | Async message processing (Oban) | ADDED | [`C-3-async-message-processing/spec.md`](./C-3-async-message-processing/spec.md) |
| **C-4** | Deep-link onboarding with ephemeral token | ADDED | [`C-4-deep-link-onboarding/spec.md`](./C-4-deep-link-onboarding/spec.md) |
| **C-5** | End-to-end clinical round-trip | ADDED | [`C-5-clinical-round-trip/spec.md`](./C-5-clinical-round-trip/spec.md) |
| **C-6** | Vault-sealed bot token | ADDED | [`C-6-vault-sealed-bot-token/spec.md`](./C-6-vault-sealed-bot-token/spec.md) |
| **C-7** | Outbound rate-limit & 429 handling | ADDED | [`C-7-outbound-rate-limit/spec.md`](./C-7-outbound-rate-limit/spec.md) |

Each spec is **self-contained**: it opens with a `Purpose` block, then a flat
list of `## REQ-<capability-id>-<slug>` requirements, each followed by 2–4
Given/When/Then `#### Scenario` blocks. `sdd-verify` and `sdd-tasks` reference
these REQ and Scenario names verbatim.

---

## Capability → Risk Coverage Matrix

Five risks are tracked from the proposal (`R-1` … `R-5`).

| Risk | Summary | Mitigated by | Why |
|---|---|---|---|
| **R-1** | PHI in transport | **C-5** (Cloak.Ecto on `Message.body`), **C-2** (no raw chat_id in logs), **C-3** (worker logs hash prefix only) | Encryption at rest + no plaintext identifiers in any log line + redacted telemetry |
| **R-2** | Rate limits dropping a crisis message | **C-7** (Pacer + crisis priority lane + queue_full escalation + dead-letter) | TokenBucket pacing plus a dedicated lane plus an escalation path that bypasses the queue but never the rate-limit |
| **R-3** | Message reordering | **C-3** (persists `telegram_message_id`, orders by `inserted_at` upstream), **C-5** (LLM context builder reuses the same pattern) | Same reconciliation discipline as the WhatsApp channel |
| **R-4** | Webhook spoofing | **C-1** (`AletheaWeb.Plugs.TelegramSecretToken`, 401 before body parse), **C-6** (sealed secret token, not env) | The `X-Telegram-Bot-Api-Secret-Token` header is the only authenticator; sealed at rest |
| **R-5** | Bot token blast radius | **C-6** (`BotConfig` row + `Cloak.Ecto.Binary` + per-env discriminator + GenServer accessor) | Plaintext exists only in `BotToken` process state; per-env separation prevents dev/test → prod cross-talk |

C-4 (onboarding) does not directly mitigate a proposal risk; it covers a
patient-facing flow that is itself a precondition for R-1..R-5 to be meaningful
(no chat binding ⇒ nothing to look up, send, or rate-limit).

---

## Chain Strategy Signpost

`chain_strategy = feature-branch-chain`. The 400-line review budget plus
`work-unit-commits` discipline mean the implementation will be sliced into
roughly four feature-branch PRs. These are **signposts** at the spec level only;
`sdd-tasks` will refine them into concrete task groups and per-slice
verification.

| Slice | Theme | Capabilities touched | Why this slice |
|---|---|---|---|
| **(a)** | Pacer + BotToken + ChatIdHash | C-6, C-2 (pure), C-7 (Pacer only) | Pure / low-risk primitives with no IO. Establishes the sealed-token + rate-limit foundation before any HTTP or worker code lands. |
| **(b)** | Webhook + Plug + Controller | C-1, C-2 (Account lookup wired in) | Adds the HTTP entrypoint and the secret-token plug; webhook can already receive traffic but does not yet run the clinical round-trip. |
| **(c)** | MessageWorker + clinical round-trip + crisis bypass | C-3, C-5, C-7 (Outbound worker + dead-letter + crisis lane) | The end-to-end clinical flow on the existing webhook; the largest slice because it touches reuse (LLM, RoBERTa, CrisisMonitor) plus the new outbound worker. |
| **(d)** | Onboarding (deep-link + 6-digit fallback) | C-4, C-6 (`for_env/1` already shipped) | The patient-binding flow that turns an inbound chat into a usable clinical record. Last because it is the one flow that has the most PHI to land in the DB; doing it last lets the team validate the PHI guardrails end-to-end first. |

This README is a signpost, not the task plan. `sdd-tasks` will replace it with
the per-slice task groups and the explicit `Decision needed before apply`,
`Chained PRs recommended`, and `400-line budget risk` lines per
`sdd-phase-common.md §E`.

---

## Coverage Summary

- **Happy paths covered:** webhook receipt, secret-token pass, Oban enqueue,
  patient resolution, inbound persistence, emotion trigger, LLM reply, crisis
  bypass, deep-link bind, six-digit fallback, outbound send, Pacer pacing, 429
  retry.
- **Negative paths covered:** secret-token mismatch (401), unknown chat (200
  with "unregistered"), expired token, already-used token, rate-limited token,
  six-digit via `/start` (rejected), LLM unavailable (crash-retry), emotion
  worker failure (independent queue), 5xx/network on send, dead-letter on
  exhaustion, `:queue_full` on crisis lane.
- **Edge cases covered:** 32-byte URL-safe collision resistance, two mints for
  the same patient, TTL boundary, rate-limit per-IP vs per-kind, Pacer
  per-chat vs global interaction, escalation never skips Pacer, hash prefix
  only in logs, plaintext not in env vars.

Every scenario is testable. The 15 tests in the design's §13 test plan map
roughly one-to-one to the requirements in C-1..C-7; the design's test names are
the contract, this spec set is the contract's requirements layer.

---

## Next Step

Ready for `sdd-tasks`. The four chain slices above are the spec-level
signposts; `sdd-tasks` will turn them into per-slice task groups with explicit
RED-GREEN-REFACTOR ordering and a delivery-strategy decision.
