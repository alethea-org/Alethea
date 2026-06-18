# Tasks: Telegram Patient Foundation (6-Slice Re-Sliced)

**Change:** `telegram-paciente-foundation`
**Chain strategy:** `feature-branch-chain` (locked)
**Tracker branch:** `feat/telegram-paciente-foundation` (draft PR, no-merge)
**Slices:** 6 (PR #1a → #1b → #2 → #3a → #3b → #4; only the tracker merges to main)
**Strict TDD:** every task writes its test first (RED), then implements (GREEN), then refactors.
**Per-task verify:** `mix test <test_file>` + at slice end `mix precommit`.
**Soft review budget (D-revised):** 800 changed lines / PR (was 400). 6 PRs each ≤ 800 keeps
the chain at ≤ 4,000 total and preserves the natural Pacer / Onboarding dependency cuts.

## Re-Slice Justification (delta from previous 4-slice plan)

The previous 4-slice plan put ~1,335 lines in PR #3 and ~990 in PR #4 — both well above the
400-line cap on a raw-diff basis. The maintainer has chosen to re-slice to 6 PRs with a
**soft 800-line budget** so the natural dependency cuts (Pacer ETS, Pacer-as-consumer
contract, safe vs crisis path, schema vs worker vs controller) are preserved without
forcing a 10-PR chain that would split a TokenBucket across two PRs.

| Δ from previous | Reason |
|---|---|
| Split previous PR #1 into #1a (persistence + secrets) and #1b (rate-limit + deep-link + ADR) | The two halves have no compile-time dependency on each other; #1a is the encryption boundary, #1b is the rate-limit boundary. Splitting lets reviewers focus on secret-handling first, concurrency primitives second. |
| Moved `Telegram.Client` behaviour + `Fake` from previous PR #1 to PR #2 | The Client is consumed by the worker stubs in PR #2; keeping it next to its consumer is the work-unit-commits rule. The production `Req` impl moves to #3a. |
| Split previous PR #3 into #3a (safe path + outbound + dead-letter) and #3b (crisis branch + escalation + ops broadcast) | The safe path is the clinical baseline; the crisis branch adds two broadcasts and a queue_full escalation. They are independently testable: #3a green-tests the "happy journal" loop; #3b green-tests the "patient in crisis" loop without re-testing the safe path. |
| PR #4 stays as a single slice (overshoot documented below) | Splitting #4 into "schema" and "controller" would leave a half-state where the schema is on main but no chat can bind. The single overshoot is the honest answer. |

---

## Review Workload Forecast (Top of File)

| Field | Value |
|---|---|
| Estimated changed lines (all 6 PRs) | ~3,839 (impl + tests + migrations + ADR) |
| Per-PR target | #1a ≤ 500 / #1b ≤ 550 / #2 ≤ 700 / #3a ≤ 700 / #3b ≤ 650 / #4 ≤ 800 |
| 800-line budget risk | Medium overall (#1a low; #1b low; #2 medium; #3a medium; #3b low; #4 medium-high — overshoot explicitly accepted, see below) |
| Chained PRs recommended | Yes (locked) |
| Chain strategy | feature-branch-chain |
| Delivery strategy | ask-always — but the re-slice IS the ask, captured here |
| Decision needed before apply | No (chain strategy locked, per-PR budgets documented, #4 overshoot accepted) |
| Suggested split | PR 1a → PR 1b → PR 2 → PR 3a → PR 3b → PR 4 → tracker → main |

Decision needed before apply: No
Chained PRs recommended: Yes
Chain strategy: feature-branch-chain
400-line budget risk: High (under the original D1=400 cap; **Medium under the D-revised 800 cap**)
Soft budget for this change: 800

### Suggested Work Units

| Unit | Goal | Likely PR | Base branch | Notes |
|---|---|---|---|---|
| 1a | Sealed bot token + HMAC identity helper + Vault wiring, no I/O | PR #1a | `main` | Tracker branch `feat/telegram-paciente-foundation` created as draft PR (no-merge) |
| 1b | Pacer GenServer (2 ETS TokenBuckets) + DeepLinkToken + ADR-0008 | PR #1b | #1a | Concurrency primitives land after secrets are safe |
| 2 | Webhook wire + secret-token plug + skeleton controllers + Client behaviour + Fake + Oban queues | PR #2 | #1b | First slice with HTTP; all enqueued jobs are no-op stubs |
| 3a | Clinical safe path: TelegramMessageWorker (idempotency + patient resolve + LLM + emotion) + TelegramOutboundWorker (Pacer + 429 + jitter) + DeadLetter + Req impl | PR #3a | #2 | Big slice; documented as 740 lines (40 over 700 target, within soft 800 budget) |
| 3b | Clinical crisis branch: crisis detection, bypass, PubSub `:crisis_detected`, queue_full escalation, ops:alerts broadcast | PR #3b | #3a | Adds two broadcasts and one escalation; green-tests the crisis loop |
| 4 | Onboarding: PatientAuthCode schema + verify/consume + DeepLink + 6-digit routes + TelegramOnboardingWorker + welcome emission | PR #4 | #3b | Single overshoot accepted at ~990 lines (see rationale at end) |

---

## Chain Topology

```
main
 └─ feat/telegram-paciente-foundation                                  (TRACKER — draft, no-merge)
     └─ feat/telegram-paciente-foundation/pr-1a-foundations-a           (PR #1a → main)
     └─ feat/telegram-paciente-foundation/pr-1b-foundations-b           (PR #1b → pr-1a)
     └─ feat/telegram-paciente-foundation/pr-2-entrypoint              (PR #2  → pr-1b)
     └─ feat/telegram-paciente-foundation/pr-3a-clinical-safe          (PR #3a → pr-2)
     └─ feat/telegram-paciente-foundation/pr-3b-clinical-crisis        (PR #3b → pr-3a)
     └─ feat/telegram-paciente-foundation/pr-4-onboarding              (PR #4  → pr-3b)
```

Each PR is a child of the previous PR's branch. Only the tracker branch merges to `main`.
The tracker is integration-only — it accumulates the chain and is the single PR that lands.

---

## PR #1a — Foundations A: Sealed Secrets + HMAC Identity Helper

**Title:** `feat(telegram): bot token vault, chat id hash, encryption-vault wiring`
**Base branch:** `main`
**Head branch:** `feat/telegram-paciente-foundation/pr-1a-foundations-a`
**Tracker branch:** `feat/telegram-paciente-foundation` (created as draft, no-merge)
**Why this slice:** the encryption boundary lands first. BotConfig + BotToken are the
sealed-secret surface; ChatIdHash is the pure HMAC helper used by every later slice; ADR-0008
documents the pepper-rotation policy. **No HTTP, no Oban worker, no GenServer that talks
to Telegram.** All units are independently testable with `Mix.env() == :test` config.
**Caps touched:** C-2 (ChatIdHash pure helper), C-6 (BotConfig + BotToken + Vault wiring).
**Est. lines:** **420** (well under 500 target — `budget_800_risk: low`)

### TASK-1a-1 — ChatIdHash pure HMAC helper (C-2)
- **Type:** impl
- **Files (impl):** `lib/alethea/telegram/chat_id_hash.ex`
- **Files (test):** `test/alethea/telegram/chat_id_hash_test.exs`
- **Requirements:** `REQ-C2-chat-id-stored-as-hmac` (pure half — no DB)
- **Risks:** R-1 (PHI hygiene — no decoding helper exposed)
- **Verify:** `mix test test/alethea/telegram/chat_id_hash_test.exs`
- **Commit:** `feat(telegram): add chat id hash HMAC helper`
- **Est. lines:** 18 impl + 50 test = **68**

### TASK-1a-2 — BotConfig schema + `foundation_bot_configs` migration + context (C-6)
- **Type:** impl + migration
- **Files (impl):** `lib/alethea/foundation/accounts/bot_config.ex`
- **Files (migration):** `priv/repo/migrations/20260616XXXXXX_create_foundation_bot_configs.exs`
- **Files (config):** `config/config.exs` (Cloak field type registered)
- **Files (test):** `test/alethea/foundation/accounts/bot_config_test.exs`
- **Requirements:** `REQ-C6-bot-token-stored-encrypted`, `REQ-C6-distinct-per-env`
- **Risks:** R-5 (bot token blast radius — sealed at rest, dev/test/prod discriminated)
- **Verify:** `mix test test/alethea/foundation/accounts/bot_config_test.exs`
- **Commit:** `feat(telegram): add BotConfig schema with env discriminator`
- **Est. lines:** 60 impl + 35 migration + 90 test = **185**

### TASK-1a-3 — BotToken GenServer accessor (C-6)
- **Type:** impl
- **Files (impl):** `lib/alethea/telegram/bot_token.ex`
- **Files (config):** `config/test.exs` (BotConfig `:test` row bootstrap)
- **Files (test):** `test/alethea/telegram/bot_token_test.exs`
- **Requirements:** `REQ-C6-bot-token-gen-server-accessor`, `REQ-C6-no-plaintext-in-env`
- **Risks:** R-5 (fail-loud on missing BotConfig row in prod)
- **Verify:** `mix test test/alethea/telegram/bot_token_test.exs`
- **Commit:** `feat(telegram): add BotToken GenServer accessor`
- **Est. lines:** 65 impl + 90 test = **155**

### TASK-1a-4 — Application supervision delta for BotToken (infra wiring)
- **Type:** infra
- **Files (impl):** `lib/alethea/application.ex` (add `BotToken` child spec)
- **Files (test):** indirect — covered by `mix test` (full suite)
- **Requirements:** prereq for C-6 accessor at runtime
- **Risks:** R-5 (BotToken must be supervised; missing-row is loud)
- **Verify:** `mix test`
- **Commit:** `chore(app): supervise BotToken GenServer`
- **Est. lines:** 12 = **12**

### PR #1a totals
- **Tasks:** 4
- **Est. lines:** 68 + 185 + 155 + 12 = **420** (impl + tests + migration + wiring)
  - Net-new code: ~145 impl + 35 migration + 230 test = 410
  - Wiring: 12
  - **Independent green-test:** yes — pure helper + sealed schema + GenServer accessor
    are unit-testable in isolation; no HTTP, no Oban, no Telegram I/O.

**PR #1a PR body (branch-pr convention):**

> ## What
> Ship the encryption boundary for the Telegram patient gateway before any HTTP traffic
> arrives: a sealed per-env `BotConfig` row (Cloak.Ecto for `token` and `secret_token`),
> a `BotToken` GenServer accessor that never exposes plaintext, a pure HMAC `ChatIdHash`
> helper, and the application supervision delta that brings `BotToken` up at boot.
>
> ## Why
> The previous 4-slice plan lumped secrets, rate-limit, deep-link, and ADR into one PR.
> Splitting the secrets half (#1a) from the rate-limit half (#1b) lets reviewers focus
> on the encryption boundary first and the concurrency primitives second.
>
> ## Dependency
> First child of the tracker branch `feat/telegram-paciente-foundation` (draft, no-merge).
> Targets `main` directly.
>
> ## Out of scope
> HTTP webhook (#2), rate-limit Pacer (#1b), deep-link token (#1b), clinical round-trip (#3a/#3b),
> onboarding (#4).
>
> ## Verification
> `mix precommit`; per-test: `mix test test/alethea/telegram/chat_id_hash_test.exs`,
> `mix test test/alethea/foundation/accounts/bot_config_test.exs`,
> `mix test test/alethea/telegram/bot_token_test.exs`.

---

## PR #1b — Foundations B: Pacer + DeepLinkToken + ADR-0008

**Title:** `feat(telegram): pacer GenServer with token buckets and deep link token`
**Base branch:** `feat/telegram-paciente-foundation/pr-1a-foundations-a` (NOT main)
**Head branch:** `feat/telegram-paciente-foundation/pr-1b-foundations-b`
**Why this slice:** the concurrency primitives land second. The Pacer is a single GenServer
holding two ETS-backed TokenBuckets (per-chat 1 Hz + global 30 Hz); DeepLinkToken is a pure
mint/verify helper used by the onboarding slice (#4); ADR-0008 documents the pepper-rotation
policy. **No HTTP, no Oban worker that talks to Telegram.** ADR-0008 lives here because it
describes the operational story for the deep-link token (rotation = re-onboard), which the
reader of the Pacer PR naturally encounters.
**Caps touched:** C-4 (DeepLinkToken pure half), C-7 (Pacer only).
**Est. lines:** **462** (under 550 target — `budget_800_risk: low`)

### TASK-1b-1 — DeepLinkToken mint/verify pure module (C-4 primitive)
- **Type:** impl
- **Files (impl):** `lib/alethea/telegram/deep_link_token.ex`
- **Files (test):** `test/alethea/telegram/deep_link_token_test.exs`
- **Requirements:** `REQ-C4-mint-deep-link-token` (pure half; persistence half lives in #4)
- **Risks:** — (pure function, no I/O)
- **Verify:** `mix test test/alethea/telegram/deep_link_token_test.exs`
- **Commit:** `feat(telegram): add deep link token mint/verify`
- **Est. lines:** 22 impl + 60 test = **82**

### TASK-1b-2 — Pacer GenServer with two ETS TokenBuckets (C-7 partial)
- **Type:** impl
- **Files (impl):** `lib/alethea/telegram/pacer.ex`
- **Files (test):** `test/alethea/telegram/pacer_test.exs`
- **Requirements:** `REQ-C7-pacer-per-chat-limit`, `REQ-C7-pacer-global-limit`
- **Risks:** R-2 (rate limits dropping a crisis message — Pacer is the safety net)
- **Verify:** `mix test test/alethea/telegram/pacer_test.exs`
- **Commit:** `feat(telegram): add Pacer GenServer with per-chat and global token buckets`
- **Est. lines:** 110 impl + 160 test = **270**

### TASK-1b-3 — ADR-0008: chat_id pepper rotation policy (docs)
- **Type:** docs
- **Files (impl):** `openspec/adr/008-telegram-chat-id-pepper-rotation.md`
- **Files (test):** —
- **Requirements:** Q4-bonus decision (locked — pepper rotation = manual + re-onboarding)
- **Risks:** R-1 (rotation erases only the lookup key, not clinical data)
- **Verify:** `ls openspec/adr/008-*.md` (file exists, contents match design §14)
- **Commit:** `docs(adr): add 008 telegram chat id pepper rotation policy`
- **Est. lines:** 110 = **110**

### PR #1b totals
- **Tasks:** 3
- **Est. lines:** 82 + 270 + 110 = **462**
  - Net-new code: ~132 impl + 220 test = 352
  - Docs (ADR): 110
  - **Independent green-test:** yes — pure mint/verify + ETS-backed GenServer + ADR.
    The Pacer is supervised in the next slice (#2) so this slice tests `Pacer.start_link/1`
    directly per test.

**PR #1b PR body (branch-pr convention):**

> ## What
> Ship the rate-limit primitive and the deep-link token primitive on top of the
> encryption boundary from #1a. `Alethea.Telegram.Pacer` is a single GenServer holding
> two ETS-backed TokenBuckets (per-chat 1 Hz, global 30 Hz). `Alethea.Telegram.DeepLinkToken`
> is a pure mint/verify module (32-byte URL-safe base64, 10 min TTL semantics in the
> caller). ADR-0008 documents the chat_id pepper rotation policy (manual rotation +
> re-onboarding).
>
> ## Why
> The Pacer's two ETS tables must ship as a single unit — splitting them across PRs
> would create a half-state where the global limit is enforced but the per-chat limit
> is not, or vice versa. The deep-link token is a pure helper, but its operational
> contract (TTL, single-use) is documented in ADR-0008, so they ship together.
>
> ## Dependency
> Targets PR #1a branch `feat/telegram-paciente-foundation/pr-1a-foundations-a` (NOT main).
>
> ## Out of scope
> BotConfig, BotToken, HTTP webhook, clinical round-trip, onboarding, Oban queues.
>
> ## Verification
> `mix precommit`; per-test: `mix test test/alethea/telegram/deep_link_token_test.exs`,
> `mix test test/alethea/telegram/pacer_test.exs`.

---

## PR #2 — Entrypoint: Webhook + Plug + Skeleton Controllers + Client Behaviour + Oban Queues

**Title:** `feat(telegram): webhook entrypoint with secret-token plug and skeleton controllers`
**Base branch:** `feat/telegram-paciente-foundation/pr-1b-foundations-b` (NOT main)
**Head branch:** `feat/telegram-paciente-foundation/pr-2-entrypoint`
**Why this slice:** the HTTP wire lands. The `TelegramSecretToken` plug validates the
`X-Telegram-Bot-Api-Secret-Token` header; the `TelegramWebhookController` 401s on bad token,
fast-acks 200, and enqueues a worker by `update_id` (24h Oban unique); the
`TelegramAuthController` is a 200+log skeleton; the `Telegram.Client` behaviour ships with
the `Fake` adapter (the `Req` adapter ships in #3a where it's consumed); the Application
supervisor gains the `Pacer` child spec; the router gains the `:telegram_webhook` scope.
**The enqueued workers are stubs that return `:ok` immediately** — the real bodies land
in #3a/#3b/#4. The migration to rename `telegram_chat_id` → `telegram_chat_id_hash` ships
here so the column is in place when #3a writes to it.
**Caps touched:** C-1 (webhook + plug), C-2 (lookup wired in by name only, full use in #3a),
C-7 prep (Oban queue definitions, consumed in #3a).
**Est. lines:** **642** (under 700 target — `budget_800_risk: medium`)

### TASK-2-1 — Patient `telegram_chat_id` → `telegram_chat_id_hash` migration (C-2)
- **Type:** migration
- **Files (impl):** `priv/repo/migrations/20260616XXXXXX_rename_telegram_chat_id_to_hash.exs`
- **Files (modify):** `lib/alethea/foundation/accounts/patient.ex` (add
  `telegram_chat_id_hash` field; keep `telegram_chat_id` for one migration then drop)
- **Files (modify):** `lib/alethea/foundation/accounts.ex` (add
  `lookup_patient_by_chat_hash/1` + re-export)
- **Files (test):** `test/alethea/foundation/accounts/patient_test.exs` (extend),
  `test/alethea/foundation/accounts_test.exs` (new)
- **Requirements:** `REQ-C2-chat-id-stored-as-hmac`, `REQ-C2-lookup-by-hash`,
  `REQ-C2-partial-unique-index`
- **Risks:** R-1 (no plaintext at rest; partial unique index per design §6 Migration 1)
- **Verify:** `mix test test/alethea/foundation/accounts/`
- **Commit:** `feat(telegram): rename patient telegram chat id to HMAC hash`
- **Est. lines:** 40 migration + 8 patient.ex + 12 accounts.ex + 50 test = **110**

### TASK-2-2 — TelegramSecretToken plug (C-1)
- **Type:** impl
- **Files (impl):** `lib/alethea_web/plugs/telegram_secret_token.ex`
- **Files (test):** `test/alethea_web/plugs/telegram_secret_token_test.exs`
- **Requirements:** `REQ-C1-secret-token-validates-header`
- **Risks:** R-4 (webhook spoofing — header is the only auth)
- **Verify:** `mix test test/alethea_web/plugs/telegram_secret_token_test.exs`
- **Commit:** `feat(telegram): add secret-token validation plug`
- **Est. lines:** 22 impl + 38 test = **60**

### TASK-2-3 — TelegramWebhookController (skeleton) — receive/2 401/200 + enqueue (C-1)
- **Type:** impl
- **Files (impl):** `lib/alethea_web/controllers/telegram_webhook_controller.ex`
- **Files (test):** `test/alethea_web/controllers/telegram_webhook_controller_test.exs`
- **Requirements:** `REQ-C1-webhook-fast-acks`, `REQ-C1-webhook-enqueues-inbound-worker`,
  `REQ-C1-webhook-routes-start-to-onboarding`
- **Risks:** R-4, R-3 (use `update_id` as Oban unique key from day 1)
- **Verify:** `mix test test/alethea_web/controllers/telegram_webhook_controller_test.exs`
- **Commit:** `feat(telegram): add webhook controller with Oban enqueue`
- **Est. lines:** 60 impl + 120 test = **180**
  - 401 path (C-1 req 1), 200 fast-ack (C-1 req 2), enqueue
    `TelegramMessageWorker` with `unique: [period: 86_400, keys: [:telegram_update_id]]`
    (C-1 req 3), route `/start` to `TelegramOnboardingWorker` (C-1 req 4). All 4 REQs in
    this one module. The workers themselves are stubbed modules in TASK-2-7; their real
    bodies ship in #3a (and #4 for onboarding).

### TASK-2-4 — TelegramAuthController (skeleton) — 200 + log only (C-4 wire)
- **Type:** impl
- **Files (impl):** `lib/alethea_web/controllers/telegram_auth_controller.ex`
- **Files (test):** `test/alethea_web/controllers/telegram_auth_controller_test.exs`
- **Requirements:** C-1 wire-up only (skeleton). Full `consume/2` semantics land in #4.
- **Risks:** —
- **Verify:** `mix test test/alethea_web/controllers/telegram_auth_controller_test.exs`
- **Commit:** `feat(telegram): add auth controller skeleton`
- **Est. lines:** 20 impl + 30 test = **50**

### TASK-2-5 — Router pipeline `:telegram_webhook` + scope block (C-1, C-2)
- **Type:** infra
- **Files (modify):** `lib/alethea_web/router.ex`
- **Files (test):** covered by full `mix test` (the controller tests exercise the route)
- **Requirements:** C-1 + C-2 wire-up
- **Risks:** R-4 (plug runs before `:accepts` body parse)
- **Verify:** `mix test`
- **Commit:** `feat(telegram): wire webhook routes in router`
- **Est. lines:** 14 = **14**

### TASK-2-6 — Oban queue config + Application supervisor delta for Pacer + 3 queues (C-7 prep)
- **Type:** infra
- **Files (modify):** `config/config.exs` (add `telegram_inbound`, `telegram_outbound`,
  `telegram_outbound_crisis` queues)
- **Files (modify):** `lib/alethea/application.ex` (add `Pacer` child spec)
- **Files (test):** `mix test` (workers from #3a will assert queue names)
- **Requirements:** C-7 prep (queue definitions exist before workers reference them)
- **Risks:** —
- **Verify:** `mix test`
- **Commit:** `chore(oban): add telegram_inbound, telegram_outbound, telegram_outbound_crisis queues; supervise Pacer`
- **Est. lines:** 18 (config) + 6 (supervisor) = **24**

### TASK-2-7 — TelegramMessageWorker + TelegramOnboardingWorker stubs (worker shells)
- **Type:** impl
- **Files (impl):**
  - `lib/alethea_jobs/telegram_message_worker.ex` (queue + Oban unique declared, body
    returns `:ok`)
  - `lib/alethea_jobs/telegram_onboarding_worker.ex` (queue declared, body returns `:ok`)
- **Files (test):** `test/alethea_jobs/telegram_message_worker_test.exs`,
  `test/alethea_jobs/telegram_onboarding_worker_test.exs` (minimal: declares the queue,
  unique config, returns `:ok` on perform)
- **Requirements:** C-3 prep (queue + unique key), C-4 wire-up prep
- **Risks:** R-3 (the unique key locks in the dedup contract)
- **Verify:** `mix test test/alethea_jobs/telegram_*_worker_test.exs`
- **Commit:** `feat(telegram): add inbound and onboarding worker shells`
- **Est. lines:** 40 impl + 60 test = **100**
  - Stubs exist only so PR #2 can assert the enqueue + `unique:` contract. PR #3a/#3b
    grow the inbound body under the same module (no rename, no second PR churn). PR #4
    grows the onboarding body.

### TASK-2-8 — Telegram.Client behaviour + Fake adapter (C-7 prep + #3a dependency)
- **Type:** impl
- **Files (impl):**
  - `lib/alethea/telegram/client.ex` (behaviour — defines `send_message/2`)
  - `lib/alethea/telegram/client/fake.ex` (test/dev impl, accumulates sends in ETS)
- **Files (config):** `config/test.exs` wires `Alethea.Telegram.Client` → `Alethea.Telegram.Client.Fake`
- **Files (test):** `test/alethea/telegram/client/fake_test.exs`
- **Requirements:** C-7 prep (the send_message contract is the outbound worker's dependency)
- **Risks:** — (test adapter; production Req ships in #3a)
- **Verify:** `mix test test/alethea/telegram/client/`
- **Commit:** `feat(telegram): add Client behaviour with Fake adapter`
- **Est. lines:** 18 + 30 impl + 56 test = **104**
  - Note: production Req impl is in PR #3a (TASK-3a-4) where it's consumed. The behaviour +
    Fake ship in #2 so the worker stubs in TASK-2-7 can declare the contract.

### PR #2 totals
- **Tasks:** 8
- **Est. lines:** 110 + 60 + 180 + 50 + 14 + 24 + 100 + 104 = **642**
  - Net-new code: ~250; tests: ~378; config + wiring: ~38; migration: ~40
  - **Raw diff** stays under 700; reviewable as a "wire + skeleton + behaviour" PR.
    **Budget risk: medium** (TASK-2-3 alone is 180 lines because it covers 4 REQ-C1
    scenarios in one controller; TASK-2-8 ships the behaviour + Fake, with the Req impl
    in #3a).
  - **Independent merge-ability:** the skeleton controllers return 200, the plug returns
    401, the workers are enqueued and `:ok` immediately, the migration is a no-op on the
    empty dev DB (per handoff Q1 evidence), and the Fake client is wired in test config
    so no real Telegram call is made. The Pacer is supervised and unit-testable in
    isolation (its own test file from #1b covers behaviour; supervision is the wiring).

**PR #2 PR body (branch-pr convention):**

> ## What
> Wire the Telegram webhook into the app: `POST /webhooks/telegram` validates the secret
> token via a new plug, enqueues a worker by `update_id` (24h Oban unique), and routes
> `/start` to a separate onboarding worker. `GET /webhooks/telegram/auth` exists as a
> 200+log skeleton (full body in #4). The `Patient` schema gains `telegram_chat_id_hash`
> (HMAC, partial unique index), the Oban queue config gains the three Telegram queues,
> and the Application supervisor gains the Pacer child spec. `Telegram.Client` behaviour
> ships with the `Fake` adapter; the production Req adapter lands in #3a where it's
> consumed.
>
> ## Why
> PR #1a/#1b shipped the foundation primitives. PR #2 closes the wire: a real Telegram
> Update can reach the system, be authenticated, and be enqueued — without yet performing
> the clinical round-trip. This is the first slice that exercises HTTP at all.
>
> ## Dependency
> Targets PR #1b branch `feat/telegram-paciente-foundation/pr-1b-foundations-b` (NOT main).
>
> ## Out of scope
> Clinical round-trip (safe path #3a, crisis path #3b), onboarding logic (#4), setWebhook
> runbook.
>
> ## Verification
> `mix precommit`; per-test: webhook controller, plug, accounts context, worker stubs,
> Client.Fake.

---

## PR #3a — Clinical Round-Trip Safe Path: Inbound Worker + Outbound Worker + DeadLetter + Req

**Title:** `feat(telegram): clinical round-trip safe path with outbound pacer and dead letter`
**Base branch:** `feat/telegram-paciente-foundation/pr-2-entrypoint` (NOT main)
**Head branch:** `feat/telegram-paciente-foundation/pr-3a-clinical-safe`
**Why this slice:** the meat of the safe path. The `TelegramMessageWorker` resolves the
patient by hash, persists the inbound message via `Clinical.save_message/7`, enqueues the
existing `EmotionAnalysisWorker`, calls `CrisisMonitor.detect/1` (returns `:safe` here —
crisis branch is in #3b), calls `Alethea.AI.llm().chat/2` for the reply, persists the
outbound message, and enqueues `TelegramOutboundWorker`. The outbound worker paces through
`Pacer.acquire/1`, sends via `Telegram.Client.send_message/2` (Req impl ships here), retries
429 with jittered backoff, and dead-letters on exhaustion. **The crisis branch (no LLM,
PubSub broadcast) is in #3b; the Pacer acquire still runs in the crisis path, so #3b
inherits the pacing for free.**
**Caps touched:** C-3 (TelegramMessageWorker), C-5 (safe-path clinical round-trip),
C-7 (TelegramOutboundWorker + dead-letter — safe path only; crisis lane + escalation in #3b).
**Est. lines:** **740** (40 over 700 hard target, within the 800 soft budget — `budget_800_risk: medium`)

### TASK-3a-1 — TelegramMessageWorker: idempotency + patient resolution + safe clinical round-trip (C-3, C-5)
- **Type:** impl
- **Files (impl):** `lib/alethea_jobs/telegram_message_worker.ex` (replace the stub body)
- **Files (test):** `test/alethea_jobs/telegram_message_worker_test.exs` (replace the stub
  test with full scenarios: queue, unique, replay-noop, patient-not-found, safe path
  orchestration, empty-text drop)
- **Requirements:** `REQ-C3-idempotent-by-update-id`, `REQ-C3-replay-duplicate-is-noop`,
  `REQ-C3-worker-emits-outbound-job`, `REQ-C3-worker-persists-message`,
  `REQ-C3-worker-resolves-patient`, `REQ-C5-persist-inbound-message`,
  `REQ-C5-trigger-emotion-analysis`, `REQ-C5-llm-reply-on-safe`,
  `REQ-C5-persist-outbound-reply`
- **Risks:** R-3 (reordering — `update_id` is the Oban unique key, not `message_id`),
  R-1 (PHI: never log body; use chat_id_hash prefix only)
- **Verify:** `mix test test/alethea_jobs/telegram_message_worker_test.exs`
- **Commit:** `feat(telegram): message worker safe path persists inbound runs emotion and LLM`
- **Est. lines:** 150 impl + 200 test = **350**
  - This is the largest single task in the chain. The body covers: idempotency check
    (Oban unique), patient resolution (lookup by hash), persist inbound via
    `Clinical.save_message/7`, enqueue `EmotionAnalysisWorker`, classify via
    `CrisisMonitor.detect/1` (returns `:safe` here; `:crisis` is in #3b), build patient
    context, call LLM, persist outbound, enqueue `TelegramOutboundWorker`. The crisis
    branch is `#3b`'s territory; the safe-path code returns `:safe` and the test in #3a
    stubs the CrisisMonitor to do so.

### TASK-3a-2 — TelegramOutboundWorker: Pacer acquire + 429 retry + dead-letter (C-7)
- **Type:** impl
- **Files (impl):** `lib/alethea_jobs/telegram_outbound_worker.ex` (full implementation;
  the stub from #2 is replaced by the real worker)
- **Files (test):** `test/alethea_jobs/telegram_outbound_worker_test.exs`
- **Requirements:** `REQ-C7-429-retry-with-jitter`, `REQ-C7-dead-letter-on-exhaustion`
- **Risks:** R-2 (rate-limit + 429 backoff; crisis escalation is in #3b)
- **Verify:** `mix test test/alethea_jobs/telegram_outbound_worker_test.exs`
- **Commit:** `feat(telegram): outbound worker paces through Pacer with 429 backoff and dead letter`
- **Est. lines:** 100 impl + 150 test = **250**
  - The worker is the Pacer consumer; it calls `Pacer.acquire(chat_id_hash)` before
    `Client.send_message(chat_id, text)`, handles 429 with `Retry-After` + jittered
    exponential backoff, handles 5xx with retry, dead-letters on exhaustion (writes
    to `TelegramDeadLetter` table), and broadcasts `{:outbound_dead_letter, ...}` on
    PubSub. The crisis-bypass escalation to `perform_now/1` is in #3b.

### TASK-3a-3 — TelegramDeadLetter schema + `foundation_outbound_dead_letters` migration (C-7)
- **Type:** impl + migration
- **Files (impl):** `lib/alethea/foundation/accounts/outbound_dead_letter.ex`
- **Files (migration):** `priv/repo/migrations/20260616XXXXXX_create_foundation_outbound_dead_letters.exs`
- **Files (test):** `test/alethea/foundation/accounts/outbound_dead_letter_test.exs`
- **Requirements:** `REQ-C7-dead-letter-on-exhaustion` (storage half)
- **Risks:** — (audit-only; no PHI at rest — chat_id_hash only)
- **Verify:** `mix test test/alethea/foundation/accounts/outbound_dead_letter_test.exs`
- **Commit:** `feat(telegram): add outbound dead letter schema and migration`
- **Est. lines:** 30 impl + 15 migration + 35 test = **80**

### TASK-3a-4 — Telegram.Client.Req production impl (C-7)
- **Type:** impl
- **Files (impl):** `lib/alethea/telegram/client/req.ex` (Req-based send_message)
- **Files (test):** `test/alethea/telegram/client/req_test.exs` (Bypass)
- **Requirements:** C-7 (production Req adapter is consumed by the outbound worker)
- **Risks:** R-2 (real Telegram API; tests use Bypass)
- **Verify:** `mix test test/alethea/telegram/client/req_test.exs`
- **Commit:** `feat(telegram): add Client Req production adapter`
- **Est. lines:** 30 impl + 30 test = **60**

### PR #3a totals
- **Tasks:** 4
- **Est. lines:** 350 + 250 + 80 + 60 = **740** (40 over the 700 hard target, within the
  800 soft budget)
  - Net-new code: ~310 impl + 45 migration + 355 test = 710; rounding brings the
    honest estimate to 740 with the per-task test budget held to 1.1-1.3× impl.
  - **Honest overshoot note:** the safe-path clinical round-trip is the irreducible
    core of this change. The TelegramMessageWorker body covers 6 distinct orchestration
    steps (idempotency, patient resolution, persist inbound, enqueue emotion, classify
    safe, LLM chat, persist outbound, enqueue outbound). Splitting these into separate
    PRs would create a half-state where the worker is on main but the LLM is not yet
    called, which breaks strict TDD (the RED test for the safe path must hit the real
    orchestration, not a stubbed version of itself). The 40-line overshoot is documented
    and accepted; it sits comfortably under the 800-line soft budget.
  - **Independent green-test:** yes — the worker is tested with the CrisisMonitor stubbed
    to return `:safe`, the outbound worker is tested with `Pacer` real + `Client.Fake`,
    the dead-letter table is unit-tested, the Req client is tested with Bypass. No
    crisis-branch code is in this PR; no forward dependency on #3b.

**PR #3a PR body (branch-pr convention):**

> ## What
> The safe clinical round-trip on the Telegram channel: inbound message persists via
> `Clinical.save_message/7`; emotion analysis is enqueued; `CrisisMonitor.detect/1`
> returns `:safe` (crisis branch is #3b); the LLM is called via
> `Alethea.AI.llm().chat/2`; the outbound reply is persisted then enqueued. The outbound
> worker paces through the Pacer (1 msg/s/chat, 30 msg/s global), retries 429 with
> jittered backoff, and dead-letters on exhaustion. The Telegram.Client.Req production
> adapter ships here (Fake is from #2).
>
> ## Why
> PR #2 shipped the wire + behaviour + Fake. PR #3a ships the safe-path substance —
> the same clinical flow the WhatsApp channel already has, but on Telegram, with the
> Pacer + 429-backoff + dead-letter primitives. The crisis branch is in #3b to keep
> this PR reviewable.
>
> ## Dependency
> Targets PR #2 branch `feat/telegram-paciente-foundation/pr-2-entrypoint` (NOT main).
>
> ## Out of scope
> Crisis branch (`:crisis_detected` PubSub broadcast, no LLM bypass, queue_full
> escalation — all #3b), onboarding (#4), admin LiveView for the dead-letter dashboard,
> setWebhook runbook.
>
> ## Verification
> `mix precommit`; per-test: message worker (safe path), outbound worker (Pacer + 429 +
> dead-letter), dead-letter schema, Client.Req.

---

## PR #3b — Clinical Round-Trip Crisis Branch: Detection + Bypass + PubSub + Escalation

**Title:** `feat(telegram): crisis branch bypasses LLM and broadcasts psychologist alert`
**Base branch:** `feat/telegram-paciente-foundation/pr-3a-clinical-safe` (NOT main)
**Head branch:** `feat/telegram-paciente-foundation/pr-3b-clinical-crisis`
**Why this slice:** the crisis branch lands second. When `CrisisMonitor.detect/1` returns
`:crisis`, the worker persists the inbound message, marks the patient as
`urgent_intervention: true`, **bypasses the LLM**, broadcasts `:crisis_detected` on the
`psychologist:alerts` PubSub topic, and emits a crisis-bypass reply on the
`telegram_outbound_crisis` priority queue. If the crisis queue is full, the emit step
escalates to `TelegramOutboundWorker.perform_now/1` — which still calls `Pacer.acquire/1`,
so the rate-limit is never bypassed. An `ops:alerts` PubSub broadcast fires when a
crisis message is dead-lettered (the operator needs to know).
**Caps touched:** C-5 (crisis branch), C-7 (crisis priority lane + queue_full escalation +
ops broadcast).
**Est. lines:** **585** (under 650 target — `budget_800_risk: low`)

### TASK-3b-1 — Crisis branch in TelegramMessageWorker: bypass LLM + PubSub `:crisis_detected` (C-5)
- **Type:** impl
- **Files (impl):** `lib/alethea_jobs/telegram_message_worker.ex` (extend with the
  `:crisis` branch: persist inbound, mark `urgent_intervention: true`, skip LLM, broadcast
  `{:crisis_detected, patient_id, text}` on `psychologist:alerts`, enqueue
  `TelegramOutboundWorker` on `telegram_outbound_crisis` queue)
- **Files (test):** `test/alethea_jobs/telegram_message_worker_test.exs` (extend with
  crisis-branch scenarios: `:crisis` classification → no LLM call, PubSub broadcast
  fires, `urgent_intervention` set, crisis queue used)
- **Requirements:** `REQ-C5-crisis-bypasses-llm`, `REQ-C5-crisis-broadcasts-alert`
- **Risks:** R-2 (crisis must not be dropped — escalation in TASK-3b-3)
- **Verify:** `mix test test/alethea_jobs/telegram_message_worker_test.exs --only crisis`
  (or named test filter)
- **Commit:** `feat(telegram): crisis branch bypasses LLM and broadcasts psychologist alert`
- **Est. lines:** 60 impl + 100 test = **160**

### TASK-3b-2 — `telegram_outbound_crisis` priority queue + Pacer preservation (C-7)
- **Type:** infra + impl
- **Files (modify):** `config/config.exs` (the queue was added in #2; here we configure its
  `max_demand` and `priority` per design §13)
- **Files (modify):** `lib/alethea_jobs/telegram_outbound_worker.ex` (extend `perform/1`
  to read the `priority` field from the job args; the Pacer call is unchanged —
  Pacer.acquire is the same in both lanes)
- **Files (test):** `test/alethea_jobs/telegram_outbound_worker_test.exs` (extend with
  crisis-lane scenario: Pacer is called regardless of priority)
- **Requirements:** `REQ-C7-crisis-priority-lane`
- **Risks:** R-2 (rate-limit must NEVER be bypassed — Pacer is the safety net)
- **Verify:** `mix test test/alethea_jobs/telegram_outbound_worker_test.exs`
- **Commit:** `feat(telegram): crisis priority lane preserves Pacer acquire`
- **Est. lines:** 15 config + 25 impl + 60 test = **100**

### TASK-3b-3 — Queue-full escalation to `perform_now/1` (C-7)
- **Type:** impl
- **Files (modify):** `lib/alethea_jobs/telegram_message_worker.ex` (extend the emit step
  to catch `Oban.InsertError{:queue_full}` on the crisis queue and call
  `TelegramOutboundWorker.perform_now/1`)
- **Files (modify):** `lib/alethea_jobs/telegram_outbound_worker.ex` (extend with the
  `perform_now/1` private entry point that still calls `Pacer.acquire/1`)
- **Files (test):** `test/alethea_jobs/telegram_message_worker_test.exs` (extend with
  queue_full scenario), `test/alethea_jobs/telegram_outbound_worker_test.exs` (extend
  with perform_now scenario)
- **Requirements:** `REQ-C7-crisis-queue-full-escalation`
- **Risks:** R-2 (rate-limit must NEVER be bypassed; perform_now still calls Pacer)
- **Verify:** `mix test test/alethea_jobs/telegram_message_worker_test.exs --only escalation`
- **Commit:** `feat(telegram): crisis lane escalates on queue full via perform now`
- **Est. lines:** 50 impl + 100 test = **150**

### TASK-3b-4 — `ops:alerts` PubSub broadcast on crisis dead-letter (C-7)
- **Type:** impl
- **Files (modify):** `lib/alethea_jobs/telegram_outbound_worker.ex` (broadcast
  `{:crisis_dead_letter, patient_id, text}` on `ops:alerts` when a crisis job
  exhausts retries)
- **Files (test):** `test/alethea_jobs/telegram_outbound_worker_test.exs` (extend with
  the crisis dead-letter scenario)
- **Requirements:** C-7 (operator visibility for crisis message loss — the only message
  type where dead-letter is a clinical incident)
- **Risks:** R-2 (crisis dead-letter is the worst case; operator must know)
- **Verify:** `mix test test/alethea_jobs/telegram_outbound_worker_test.exs`
- **Commit:** `feat(telegram): broadcast crisis dead letter on ops alerts`
- **Est. lines:** 15 impl + 30 test = **45**

### TASK-3b-5 — Crisis-path log redaction (R-1 hygiene)
- **Type:** impl
- **Files (impl):** `lib/alethea/telegram/log_redactor.ex` (small helper: redact
  chat_id_hash to a 6-char prefix in log lines)
- **Files (modify):** `lib/alethea_jobs/telegram_message_worker.ex` (call the redactor
  in every crisis-branch `Logger.info` / `Logger.error` line)
- **Files (test):** `test/alethea/telegram/log_redactor_test.exs`
- **Requirements:** `REQ-C2-no-plaintext-in-logs` (crisis branch)
- **Risks:** R-1
- **Verify:** `mix test test/alethea/telegram/log_redactor_test.exs`
- **Commit:** `feat(telegram): redact chat id from crisis branch logs`
- **Est. lines:** 20 impl + 30 test = **50**
  - The safe-path log redaction is a smaller follow-up that can ship in #4 or be folded
    into the existing worker's logger calls; the crisis path is the more sensitive one
    so it lands first.

### TASK-3b-6 — Crisis integration scenarios: end-to-end `:crisis` flow (C-5, C-7)
- **Type:** impl (test surface only — no new modules)
- **Files (test):** `test/alethea_jobs/telegram_message_worker_test.exs` (extend with
  end-to-end crisis scenarios: webhook → inbound worker → crisis branch → outbound
  worker on crisis queue → Pacer acquires → message is sent via Fake client → patient
  gets the crisis-bypass text and PubSub alert fires)
- **Files (test):** `test/alethea_jobs/telegram_outbound_worker_test.exs` (extend
  similarly)
- **Requirements:** C-5 + C-7 (end-to-end crisis story)
- **Risks:** R-2 (regression test for the full crisis loop)
- **Verify:** `mix test test/alethea_jobs/telegram_*_worker_test.exs`
- **Commit:** `test(telegram): add end to end crisis branch scenarios`
- **Est. lines:** 0 impl + 80 test = **80**

### PR #3b totals
- **Tasks:** 6
- **Est. lines:** 160 + 100 + 150 + 45 + 50 + 80 = **585**
  - Net-new code: ~150 impl + 0 migration + 400 test = 550
  - Config: ~15
  - Tests: ~400 (crisis branch is highly testable; many small scenarios)
  - **Independent green-test:** yes — the crisis branch is the inverse of the safe path;
    the worker test stubs `CrisisMonitor.detect/1` to return `:crisis`, the outbound
    worker tests use the Fake client, the Pacer is real, the PubSub is real (subscribe
    in test). No forward dependency on #4.

**PR #3b PR body (branch-pr convention):**

> ## What
> The crisis branch on the Telegram channel: when `CrisisMonitor.detect/1` returns
> `:crisis`, the worker persists the inbound message, marks the patient as
> `urgent_intervention: true`, **bypasses the LLM**, broadcasts `:crisis_detected` on
> `psychologist:alerts`, and emits a crisis-bypass reply on the
> `telegram_outbound_crisis` priority queue. If the crisis queue is full, the emit
> step escalates to `TelegramOutboundWorker.perform_now/1` — which still calls
> `Pacer.acquire/1`, so the rate-limit is never bypassed. An `ops:alerts` PubSub
> broadcast fires when a crisis message is dead-lettered. Log redaction is added for
> the crisis branch (chat_id_hash is reduced to a 6-char prefix in log lines).
>
> ## Why
> PR #3a shipped the safe path. PR #3b ships the crisis path — the inverse loop where
> the LLM is bypassed, the psychologist is notified, and the rate-limit is preserved
> even under escalation. Splitting safe vs crisis into separate PRs keeps each reviewable.
>
> ## Dependency
> Targets PR #3a branch `feat/telegram-paciente-foundation/pr-3a-clinical-safe` (NOT main).
>
> ## Out of scope
> Onboarding (#4), admin LiveView for the psychologist alerts, setWebhook runbook.
>
> ## Verification
> `mix precommit`; per-test: message worker (crisis + escalation), outbound worker
> (crisis lane + dead-letter + ops broadcast), log redactor.

---

## PR #4 — Onboarding: PatientAuthCode + Deep-Link + 6-Digit Routes + Onboarding Worker + Welcome

**Title:** `feat(telegram): patient onboarding via deep link and six digit code`
**Base branch:** `feat/telegram-paciente-foundation/pr-3b-clinical-crisis` (NOT main)
**Head branch:** `feat/telegram-paciente-foundation/pr-4-onboarding`
**Why this slice:** closes the patient-binding loop end-to-end. The `PatientAuthCode` schema
+ `foundation_patient_auth_codes` migration lands; the `verify_patient_auth_code/3` and
`consume_patient_auth_code/1` context functions handle `:ok` / `:expired` / `:already_used` /
`:rate_limited` / per-IP isolation / TTL boundary; the `TelegramAuthController.consume/2`
is fleshed out for the `?code=<6digit>` web fallback; the `TelegramOnboardingWorker` body
is replaced with the real flow (extract token from `/start <token>`, verify, bind via
`HMAC-SHA256(chat_id, pepper)`, emit personality-aware welcome). The deep-link token primitive
is reused from #1b (`Alethea.Telegram.DeepLinkToken`).
**Caps touched:** C-4 (full).
**Est. lines:** **990** (190 over 800 target — see "Overshoot — PR #4" below; this is
the documented exception in this re-slice — `budget_800_risk: medium-high`, overshoot
accepted). **Further splitting (#4a schema + #4b worker/controller) is rejected** —
see rationale at end of file.

### TASK-4-1 — `foundation_patient_auth_codes` migration + schema (C-4)
- **Type:** impl + migration
- **Files (impl):** `lib/alethea/foundation/accounts/patient_auth_code.ex`
- **Files (migration):** `priv/repo/migrations/20260616XXXXXX_create_foundation_patient_auth_codes.exs`
- **Files (test):** `test/alethea/foundation/accounts/patient_auth_code_test.exs`
- **Requirements:** `REQ-C4-mint-deep-link-token` (persistence half), `REQ-C4-bind-chat-on-success`
- **Risks:** — (table is the auth-code surface; no PHI directly, but `last_attempt_ip` is
  retained for audit)
- **Verify:** `mix test test/alethea/foundation/accounts/patient_auth_code_test.exs`
- **Commit:** `feat(telegram): add patient auth code schema for deep link and six digit`
- **Est. lines:** 60 impl + 50 migration + 130 test = **240**

### TASK-4-2 — Auth code context: `verify_patient_auth_code/3` + `consume_patient_auth_code/1` (C-4)
- **Type:** impl
- **Files (impl):** `lib/alethea/foundation/accounts/patient_auth_code.ex` (extend) +
  `lib/alethea/foundation/accounts.ex` (re-export)
- **Files (test):** `test/alethea/foundation/accounts/patient_auth_code_test.exs` (extend
  with the verify/consume scenarios: `:ok`, `:expired`, `:already_used`, `:rate_limited`,
  per-IP isolation, TTL boundary)
- **Requirements:** `REQ-C4-reject-expired-token`, `REQ-C4-reject-already-used-token`,
  `REQ-C4-reject-rate-limited`
- **Risks:** R-1 (rate-limit audit trail must persist — `last_attempt_ip` + `attempt_count`
  fields are the audit row)
- **Verify:** `mix test test/alethea/foundation/accounts/patient_auth_code_test.exs`
- **Commit:** `feat(telegram): auth code verify and consume with rate limit and ttl`
- **Est. lines:** 80 impl + 150 test = **230**

### TASK-4-3 — TelegramOnboardingWorker (C-4)
- **Type:** impl
- **Files (impl):** `lib/alethea_jobs/telegram_onboarding_worker.ex` (extend the stub
  from #2 with the real body: extract token from `/start <token>`, verify, bind,
  emit welcome)
- **Files (impl):** `lib/alethea/foundation/accounts.ex` (re-export
  `verify_patient_auth_code/3` for the worker)
- **Files (test):** `test/alethea_jobs/telegram_onboarding_worker_test.exs` (extend with
  the full scenario set: bind on success, reject expired, reject already-used, reject
  rate-limited, send welcome reply)
- **Requirements:** `REQ-C4-bind-chat-on-success`, `REQ-C4-reject-expired-token`,
  `REQ-C4-reject-already-used-token`, `REQ-C4-reject-rate-limited`, `REQ-C4-send-welcome-reply`
- **Risks:** R-1 (PHI: log redaction on the worker — reuses the `LogRedactor` from #3b)
- **Verify:** `mix test test/alethea_jobs/telegram_onboarding_worker_test.exs`
- **Commit:** `feat(telegram): onboarding worker binds chat and emits welcome`
- **Est. lines:** 110 impl + 180 test = **290**

### TASK-4-4 — TelegramAuthController (full): `consume/2` for deep-link + 6-digit (C-4)
- **Type:** impl
- **Files (impl):** `lib/alethea_web/controllers/telegram_auth_controller.ex` (extend the
  #2 skeleton with real `consume/2` body: read `?start=<token>` and `?code=<6digit>`,
  call into the worker)
- **Files (test):** `test/alethea_web/controllers/telegram_auth_controller_test.exs`
  (extend with the deep-link and 6-digit scenarios; the test for "six_digit via /start
  rejected" is here, not in the worker)
- **Requirements:** `REQ-C4-six-digit-fallback` (`/start` rejection lives in the worker;
  the controller is the entry point for `?code=`)
- **Risks:** R-1 (no plaintext chat_id in any log line)
- **Verify:** `mix test test/alethea_web/controllers/telegram_auth_controller_test.exs`
- **Commit:** `feat(telegram): auth controller consumes deep link and six digit codes`
- **Est. lines:** 80 impl + 150 test = **230**

### PR #4 totals
- **Tasks:** 4
- **Est. lines:** 240 + 230 + 290 + 230 = **990**
  - Net-new code: ~330; tests: ~610; migration: ~50
  - **Budget risk: HIGH by raw line count** (190 over the 800 target).
  - **Honest call:** the 800-line review budget is exceeded by raw diff. The chain
    strategy tolerates it; reviewers can step through the 4 commits independently.
  - **Why not split #4 into #4a (schema + context) and #4b (worker + controller)?**
    See "Overshoot — PR #4" at the end of this file. The short answer: splitting creates
    a half-state where the schema is on main but no chat can bind, and the worker +
    controller would not be testable end-to-end without the schema from the same PR.
    The single overshoot is the honest answer.

**PR #4 PR body (branch-pr convention):**

> ## What
> Patient onboarding end-to-end. The `foundation_patient_auth_codes` table persists
> deep-link and six-digit codes with TTL 10 min, single-use, and 5 attempts/hour/IP
> rate-limit. `TelegramOnboardingWorker` consumes the `/start <token>` payload, verifies
> the code, binds the chat via `HMAC-SHA256(chat_id, pepper)`, and emits a
> personality-aware welcome on `telegram_outbound`. `TelegramAuthController.consume/2`
> covers the `?code=<6digit>` web fallback. Six-digit codes shared via `/start` are
> rejected (the controller is the only valid entry point for a 6-digit code).
>
> ## Why
> PR #3b shipped the crisis branch. PR #4 closes the binding loop — without a way to
> bind a Telegram chat to a `Patient` row, the round-trip is unreachable in production.
>
> ## Dependency
> Targets PR #3b branch `feat/telegram-paciente-foundation/pr-3b-clinical-crisis` (NOT main).
>
> ## Out of scope
> Admin LiveView for invite generation (separate change), setWebhook runbook (separate
> change), per-psychologist welcome copy editor (separate change).
>
> ## Verification
> `mix precommit`; per-test: patient_auth_code, onboarding worker, auth controller.

---

## Cross-Slice Dependency Graph

```
main
 └─ feat/telegram-paciente-foundation                                                    (TRACKER — draft, no-merge)
     └─ feat/telegram-paciente-foundation/pr-1a-foundations-a                            (PR #1a → main)
     │   ├─ TASK-1a-1  ChatIdHash pure HMAC helper
     │   ├─ TASK-1a-2  BotConfig schema + migration
     │   ├─ TASK-1a-3  BotToken GenServer
     │   └─ TASK-1a-4  Application supervisor delta for BotToken
     └─ feat/telegram-paciente-foundation/pr-1b-foundations-b                            (PR #1b → pr-1a)
     │   ├─ TASK-1b-1  DeepLinkToken mint/verify (pure)
     │   ├─ TASK-1b-2  Pacer GenServer (2 ETS TokenBuckets)
     │   └─ TASK-1b-3  ADR-0008 pepper rotation policy
     └─ feat/telegram-paciente-foundation/pr-2-entrypoint                                (PR #2  → pr-1b)
     │   ├─ TASK-2-1  Patient column rename + lookup_patient_by_chat_hash
     │   ├─ TASK-2-2  TelegramSecretToken plug
     │   ├─ TASK-2-3  TelegramWebhookController (skeleton + enqueue)
     │   ├─ TASK-2-4  TelegramAuthController (skeleton)
     │   ├─ TASK-2-5  Router pipeline + scope
     │   ├─ TASK-2-6  Oban queue config + Pacer supervisor
     │   ├─ TASK-2-7  TelegramMessageWorker + TelegramOnboardingWorker stubs
     │   └─ TASK-2-8  Telegram.Client behaviour + Fake
     └─ feat/telegram-paciente-foundation/pr-3a-clinical-safe                            (PR #3a → pr-2)
     │   ├─ TASK-3a-1  TelegramMessageWorker (idempotency + patient resolve + safe round-trip)
     │   ├─ TASK-3a-2  TelegramOutboundWorker (Pacer + 429 retry + dead-letter)
     │   ├─ TASK-3a-3  TelegramDeadLetter schema + migration
     │   └─ TASK-3a-4  Telegram.Client.Req production impl
     └─ feat/telegram-paciente-foundation/pr-3b-clinical-crisis                          (PR #3b → pr-3a)
     │   ├─ TASK-3b-1  Crisis branch in worker (bypass LLM + PubSub)
     │   ├─ TASK-3b-2  Crisis priority lane + Pacer preservation
     │   ├─ TASK-3b-3  Queue-full escalation to perform_now
     │   ├─ TASK-3b-4  ops:alerts broadcast on crisis dead-letter
     │   ├─ TASK-3b-5  Crisis-path log redaction
     │   └─ TASK-3b-6  End-to-end crisis integration scenarios
     └─ feat/telegram-paciente-foundation/pr-4-onboarding                                (PR #4  → pr-3b)
         ├─ TASK-4-1  PatientAuthCode schema + migration
         ├─ TASK-4-2  verify_patient_auth_code + consume (context)
         ├─ TASK-4-3  TelegramOnboardingWorker (full)
         └─ TASK-4-4  TelegramAuthController.consume/2 (full)
```

### Independent green-test verification (per PR)

| PR | Green test suite at branch tip? | Stubs / Fakes used | Why independent |
|---|---|---|---|
| #1a | Yes | `BotConfig` row seeded in `config/test.exs` | No HTTP, no Oban worker, no Telegram I/O. Pure helper + sealed schema + GenServer accessor unit-tested. |
| #1b | Yes | `Pacer.start_link/1` directly per test; no workers | Pure mint/verify + ETS-backed GenServer + ADR. Pacer is not yet supervised (supervision lands in #2). |
| #2 | Yes | `TelegramMessageWorker`/`TelegramOnboardingWorker` stubs return `:ok`; Fake client wired in test config | Migration is a no-op on the empty dev DB (Q1 evidence); controllers enqueue, workers no-op; Pacer is supervised. |
| #3a | Yes | Reuses `Alethea.AI.llm/0` discovery; `EmotionAnalysisWorker` already exists; `CrisisMonitor.detect/1` stubbed to `:safe`; `Client.Fake` for outbound tests; `Bypass` for `Client.Req` | No new external dep; clinical flow uses already-wired pieces. The `:crisis` branch is the inverse — tested in #3b. |
| #3b | Yes | `Client.Fake` continues; PubSub is real (subscribe in test); Pacer is real | Crisis branch is the inverse of safe path; no forward dependency on #4 (onboarding). |
| #4 | Yes | `Client.Fake` for the welcome message emission; `Pacer` real; `LogRedactor` real | Onboarding worker is the only new behaviour; all consumers (bot, controller) are already in the tree. |

**Note on tracker branch:** `feat/telegram-paciente-foundation` is created at the start
of PR #1a as a draft PR targeting `main`. It is kept in draft and never merged by itself.
PR #1a also targets `main` directly. PRs #1b, #2, #3a, #3b, #4 each target the previous
PR's branch. When all six are reviewed and green, the tracker branch is fast-forwarded
to PR #4's tip and the single tracker PR is marked ready-for-review for the integration.

---

## REQ-C*-* Distribution Map

| REQ ID | Lands in |
|---|---|
| `REQ-C1-secret-token-validates-header` | PR #2 (TASK-2-2) |
| `REQ-C1-webhook-fast-acks` | PR #2 (TASK-2-3) |
| `REQ-C1-webhook-enqueues-inbound-worker` | PR #2 (TASK-2-3, TASK-2-7) |
| `REQ-C1-webhook-routes-start-to-onboarding` | PR #2 (TASK-2-3, TASK-2-7) |
| `REQ-C2-chat-id-stored-as-hmac` | PR #1a (TASK-1a-1 helper) + PR #2 (TASK-2-1 column) |
| `REQ-C2-lookup-by-hash` | PR #2 (TASK-2-1) |
| `REQ-C2-partial-unique-index` | PR #2 (TASK-2-1) |
| `REQ-C2-no-plaintext-in-logs` | PR #3b (TASK-3b-5 crisis branch) — full worker coverage extends in #4 |
| `REQ-C3-idempotent-by-update-id` | PR #3a (TASK-3a-1) |
| `REQ-C3-replay-duplicate-is-noop` | PR #3a (TASK-3a-1) |
| `REQ-C3-worker-resolves-patient` | PR #3a (TASK-3a-1) |
| `REQ-C3-worker-persists-message` | PR #3a (TASK-3a-1) |
| `REQ-C3-worker-emits-outbound-job` | PR #3a (TASK-3a-1, TASK-3a-2) |
| `REQ-C4-mint-deep-link-token` | PR #1b (TASK-1b-1 pure) + PR #4 (TASK-4-1, TASK-4-2 persistence) |
| `REQ-C4-bind-chat-on-success` | PR #4 (TASK-4-1, TASK-4-3) |
| `REQ-C4-reject-expired-token` | PR #4 (TASK-4-2, TASK-4-3) |
| `REQ-C4-reject-already-used-token` | PR #4 (TASK-4-2, TASK-4-3) |
| `REQ-C4-reject-rate-limited` | PR #4 (TASK-4-2, TASK-4-3) |
| `REQ-C4-send-welcome-reply` | PR #4 (TASK-4-3) |
| `REQ-C4-six-digit-fallback` | PR #4 (TASK-4-4) |
| `REQ-C5-persist-inbound-message` | PR #3a (TASK-3a-1) |
| `REQ-C5-trigger-emotion-analysis` | PR #3a (TASK-3a-1) |
| `REQ-C5-llm-reply-on-safe` | PR #3a (TASK-3a-1) |
| `REQ-C5-persist-outbound-reply` | PR #3a (TASK-3a-1) |
| `REQ-C5-crisis-bypasses-llm` | PR #3b (TASK-3b-1) |
| `REQ-C5-crisis-broadcasts-alert` | PR #3b (TASK-3b-1) |
| `REQ-C6-bot-token-stored-encrypted` | PR #1a (TASK-1a-2) |
| `REQ-C6-distinct-per-env` | PR #1a (TASK-1a-2) |
| `REQ-C6-no-plaintext-in-env` | PR #1a (TASK-1a-3) |
| `REQ-C6-bot-token-gen-server-accessor` | PR #1a (TASK-1a-3) |
| `REQ-C7-pacer-per-chat-limit` | PR #1b (TASK-1b-2) |
| `REQ-C7-pacer-global-limit` | PR #1b (TASK-1b-2) |
| `REQ-C7-429-retry-with-jitter` | PR #3a (TASK-3a-2) |
| `REQ-C7-dead-letter-on-exhaustion` | PR #3a (TASK-3a-2, TASK-3a-3) |
| `REQ-C7-crisis-priority-lane` | PR #3b (TASK-3b-2) |
| `REQ-C7-crisis-queue-full-escalation` | PR #3b (TASK-3b-3) |

All 35 REQ-C*-* IDs are present in at least one slice. No REQ is orphaned.

---

## Strict TDD ordering (per task)

For every task in every PR:

1. **RED** — write the test file. Watch `mix test <test_file>` fail with `function … undefined`
   or `expected … got …`. Commit: `test(<area>): add failing <test>`.
2. **GREEN** — implement the module with the minimum code that makes the test pass. Commit:
   `feat(<area>): <unit>` (the task's main commit message).
3. **REFACTOR** — clean up duplication, rename locals, extract helpers. Commit:
   `refactor(<area>): <unit>` only if the refactor is non-trivial.

Work-unit-commits skill: tests + impl land in the same logical unit (PR review);
the RED/GREEN/REFACTOR sequence is the commit history within the PR, not the PR shape.

---

## Overshoot — PR #4 (the only documented exception in this re-slice)

PR #4 lands at **~990 lines** (190 over the 800 soft budget). The maintainer pre-empted
this exception in the re-slice mandate. The trade-off analysis:

**Why not split #4 into #4a (schema + context, ~470 lines) and #4b (worker + controller, ~520 lines)?**

1. **Half-state on main.** #4a would land the `PatientAuthCode` schema + verify/consume
   context functions with no producer and no consumer. The schema would be reachable
   from main but unused; future refactors could be tempted to "tidy up" the unused
   fields. The chain contract says each PR is reviewable in isolation **AND** ships a
   complete work unit; an unused-table PR violates the second half.
2. **Worker + controller cannot be tested end-to-end without the schema in the same PR.**
   The worker's full scenarios (bind, expired, already-used, rate-limited, welcome) all
   read and write the `foundation_patient_auth_codes` table. Splitting the schema into
   #4a means the worker's tests in #4b run against a migration that has not landed.
   That breaks the strict-TDD rule: the RED test must hit the real schema, not a stub.
3. **Two PRs is not materially less review work.** A reviewer reads 990 lines in one PR
   and gets the full story. Two PRs of 470 + 520 = 990 lines plus the overhead of
   re-loading the second PR's diff and re-orienting to the context. The chain grows
   from 6 to 7 PRs for ~5% review-time savings at best.
4. **The commit history is the discipline, not the PR shape.** Each task in #4 is a
   work-unit commit (schema → context → worker → controller). The reviewer can step
   through the 4 commits independently; the PR is the container for the chain.

**Conclusion:** the 190-line overshoot is accepted. The chain stays at 6 PRs. The PR
is reviewable per work-unit commit. If a future re-slice of the chain is needed (e.g.,
for a `whatsapp-foundation-2` change that reuses `PatientAuthCode`), the 4 commits in
#4 become a template for that chain's onboarding slice.

---

## Review Workload Forecast Block (machine-readable)

```yaml
review_workload_forecast:
  total_estimated_changed_lines: 3839
  per_pr:
    - pr: 1a
      title: "Foundations A: bot token vault, chat id hash, encryption-vault wiring"
      estimated_lines: 420
      budget_800_risk: low
    - pr: 1b
      title: "Foundations B: pacer GenServer with token buckets, deep link token, ADR-0008"
      estimated_lines: 462
      budget_800_risk: low
    - pr: 2
      title: "Entrypoint: webhook with secret-token plug, skeleton controllers, Client behaviour + Fake, Oban queues"
      estimated_lines: 642
      budget_800_risk: medium
    - pr: 3a
      title: "Clinical safe path: message worker, outbound worker, dead letter, Client.Req"
      estimated_lines: 740
      budget_800_risk: medium
    - pr: 3b
      title: "Clinical crisis branch: bypass LLM, psychologist alert, queue full escalation, ops broadcast"
      estimated_lines: 585
      budget_800_risk: low
    - pr: 4
      title: "Onboarding: patient auth code schema, deep link and six digit routes, onboarding worker, welcome"
      estimated_lines: 990
      budget_800_risk: medium-high
  chained_prs_recommended: true
  decision_needed_before_apply: false
  rationale: >-
    Per-PR line counts are all under the 800-line soft budget except PR #3a (740, 40
    over the 700 hard target but within the 800 soft budget) and PR #4 (990, 190 over
    the 800 soft budget — the documented exception). The Pacer's two ETS TokenBuckets
    ship as a single unit in #1b (splitting them would create a half-state where one
    limit is enforced and the other is not). The safe-vs-crisis clinical paths ship
    as separate PRs (#3a, #3b) so each is reviewable in isolation. The schema+context
    +worker+controller for onboarding ships as a single PR (#4) because splitting
    would leave the schema unused on main and break the worker's strict-TDD contract
    (RED tests must hit the real schema). PR #3a is 40 over its 700 hard target
    because the safe-path clinical round-trip is the irreducible core; splitting the
    worker body into a separate LLM-call PR would break the end-to-end safe-path
    testability. 4 of 6 PRs are under their hard target; 1 is 40 over its hard target
    but within the soft 800 cap; 1 is the documented exception per the maintainer's
    re-slice mandate. The chain stays at 6 PRs instead of forcing 7 (which would add
    a no-op PR boundary for a 5% review-time saving).
  soft_budget_for_this_change: 800
  deviation_from_d1_400: >-
    D1 specified 400 changed lines per PR. Under strict D1=400, this change would
    require ~10 PRs (every 400-line increment becomes a new branch), which would
    force splitting the Pacer's two ETS TokenBuckets across two PRs (broken state),
    splitting the safe vs crisis clinical paths into 4-5 micro-PRs (broken
    end-to-end testability), and splitting the onboarding schema from its
    consumer (broken strict-TDD contract). The maintainer has accepted a
    D-revised soft budget of 800 lines, which preserves the natural dependency
    cuts (secrets vs rate-limit, wire vs clinical, safe vs crisis) at 6 PRs and
    keeps the chain at ≤ 4,000 total lines. This is a conscious trade-off:
    per-PR review load goes up (a 700-line PR is harder than a 400-line PR), but
    per-PR review coherence goes up too (a reviewer reads one clinical story,
    not a fragment of it).
```
