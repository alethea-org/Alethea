# Design: Telegram Patient Foundation

**Change:** `telegram-paciente-foundation`
**Status:** Draft (design phase)
**Depends on:** `bootstrap-alethea-v2` (archived), ADR-001 (LLM), ADR-004 (Telegram único)
**Storage:** `openspec/sdd/telegram-paciente-foundation/design.md`

---

## 1. Technical Approach

Port the WhatsApp clinical round-trip (`AletheaWeb.WhatsappWebhookController` + `AletheaJobs.ProcessMessageWorker` + `Alethea.WhatsApp.Client`) onto the Telegram channel, with **stricter webhook auth** (secret-token header, no payload HMAC), **first-line HMAC identity** (`telegram_chat_id_hash` per `psychologist_id` pepper), and **outbound rate-limit + crisis priority lane** that the WhatsApp flow does not yet have. The change is intentionally a **channel swap** that introduces new primitives (`BotConfig`, `BotToken`, `TelegramPacer`, `PatientAuthCode`) which a future `whatsapp-foundation-2` change can later adopt.

**Layering (Hexagonal):**

```
AletheaWeb.TelegramWebhookController   ← input adapter (HTTP)
AletheaWeb.TelegramAuthController      ← input adapter (HTTP, deep-link + 6-digit)
AletheaJobs.TelegramMessageWorker      ← Oban job (async, idempotent by update_id)
AletheaJobs.TelegramOutboundWorker     ← Oban job (async, paced send)
Alethea.Telegram.Client (behaviour)    ← output adapter (port)
Alethea.Telegram.Client.Req            ← output adapter (Req impl, prod)
Alethea.Telegram.Client.Fake           ← output adapter (test/dev)
Alethea.Telegram.BotToken              ← secret accessor (sealed via Vault)
Alethea.Telegram.Pacer                 ← outbound rate-limit (GenServer, TokenBucket)
Alethea.Telegram.DeepLinkToken         ← ephemeral token mint/verify
Alethea.Foundation.Accounts.PatientAuthCode ← domain (auth_codes table)
Alethea.Foundation.Accounts.BotConfig  ← domain (sealed bot token row)
Alethea.Foundation.Accounts.Patient    ← domain (rename telegram_chat_id → telegram_chat_id_hash)
Alethea.AI                             ← reuse: LLM, RoBERTa behaviour discovery
```

The foundation namespace is used for **domain schemas** (Patient already lives in `Alethea.Foundation.Accounts.Patient`). The Telegram boundary modules live in `Alethea.Telegram.*` (no Foundation prefix — these are channel adapters, parallel to the existing `Alethea.WhatsApp.*`). The Oban workers live in `AletheaJobs.*` per the v1 convention (legacy: `AletheaJobs.ProcessMessageWorker`); the v2 cutover is a separate change.

---

## 2. Architecture Decisions

### Decision 1: Channel adapters under `Alethea.Telegram.*`, domain under `Alethea.Foundation.Accounts.*`

**Choice:** boundary modules (`Client`, `BotToken`, `Pacer`, `DeepLinkToken`) sit in `Alethea.Telegram.*`; persistence (`PatientAuthCode`, `BotConfig`, `Patient.telegram_chat_id_hash`) sits in `Alethea.Foundation.Accounts.*`.
**Alternatives considered:** (a) Put everything under `Alethea.Foundation.Telegram.*` — REJECTED. Telegram is a channel adapter, not a foundation primitive; the parallel-namespace rule is for domain types, not I/O. (b) Put domain under `Alethea.Telegram.Accounts.*` — REJECTED. The `Foundation.Accounts` namespace is the patient/identity boundary per `bootstrap-alethea-v2`; spreading identity across two namespaces breaks the tenant scoping helper.
**Rationale:** the foundation v2 already established the rule (per `openspec/sdd/archive/bootstrap-alethea-v2/02-design.md` Decision 1). Telegram adapters follow the WhatsApp precedent (`Alethea.WhatsApp.*`); they are NOT foundation primitives.

### Decision 2: Deep-link and 6-digit code live in the same `TelegramAuthController`

**Choice:** one controller `AletheaWeb.TelegramAuthController` mounts at `GET /webhooks/telegram/auth` (handles `?start=<token>` and `?code=<6digit>`); the webhook hot path stays in a separate `TelegramWebhookController` at `POST /webhooks/telegram`.
**Alternatives considered:** (a) Merge auth + webhook in one controller — REJECTED. The webhook hot path must validate the secret-token header before parsing the JSON body, and a 401 short-circuit must never share a code path with a 200-OK user reply. Two responsibilities, two plugs.
**Rationale:** the auth controller is browser-driven (user clicks the deep link in Telegram and the client opens a webview to a link Alethea generates), the webhook is server-to-server. Keeping them separate honours the `CONTEXT.md` rule "controllers deben ser delgados" + the per-plug pipeline discipline used in the router.

### Decision 3: Outbound pacer is a single GenServer with two TokenBucket tables, not a Plug

**Choice:** `Alethea.Telegram.Pacer` is a named GenServer (`:telegram_pacer`) holding two ETS-backed TokenBuckets: `:per_chat` (1 msg/s/chat, refilled at 1 Hz) and `:global` (30 msg/s global, refilled at 30 Hz). The `TelegramOutboundWorker` calls `Pacer.acquire(chat_id)` before each `sendMessage`.
**Alternatives considered:** (a) Oban's built-in rate-limit plugin per queue — REJECTED. The two limits are **per-chat AND global**, which requires a custom coordinator; Oban's plugin does not compose two limits and would force double-enqueuing. (b) Hammer / ex_rated — REJECTED for the foundation. They are excellent for "N events per window" but do not model a continuous TokenBucket with smooth refill. (c) `:queue` / `GenStage` — REJECTED. A single GenServer + two ETS tables is the smallest correct surface; full GenStage is overkill for one Telegram bot.
**Rationale:** the pacer is a side-effect-free coordinator; GenServer is the right size. Back-of-envelope: 1 bot × 1 patient in crisis × 1 msg/s = 86,400 msgs/day worst case; two ETS lookups per acquire are O(1). The same `Pacer` is used by the crisis-bypass escalation path (Q9 below).

### Decision 4: Bot token is a sealed row in a new `BotConfig` schema, keyed by environment

**Choice:** new schema `Alethea.Foundation.Accounts.BotConfig` with columns `id, env (:dev | :test | :prod), token_ciphertext (binary, Cloak.Ecto.Binary), bot_username, secret_token_ciphertext (binary, Cloak.Ecto.Binary), inserted_at, updated_at`. A context function `BotConfig.for_env/1` returns the row for the current `Mix.env()`.
**Alternatives considered:** (a) Reuse `Alethea.Encryption.Vault` with a custom `bot_token` slot via Cloak fields on a singleton config row — REJECTED. The Vault is an in-process GenServer that holds a single AES key; multi-tenant sealed values want a row in the DB so a future `BotConfig` change can be audited and rotated without a code deploy. (b) Plaintext env var (`TELEGRAM_BOT_TOKEN`) — REJECTED. Same risk profile as the current `WHATSAPP_API_TOKEN` (per proposal R-5). (c) One global `bot_token` value in the Vault with no env discriminator — REJECTED. Dev/staging would share the prod bot, an obvious blast radius.
**Rationale:** the row IS the secret-at-rest; the Cloak.Ecto field IS the encryption at rest; the env discriminator IS the dev/test/prod separation. Three properties, one schema.

### Decision 5: `telegram_chat_id_hash` is nullable AND has a unique index (partial)

**Choice:** the column is `null: true` (a patient may exist before they `/start` the bot) with a **partial unique index** `CREATE UNIQUE INDEX … ON foundation_patients (telegram_chat_id_hash) WHERE telegram_chat_id_hash IS NOT NULL`.
**Alternatives considered:** (a) NOT NULL with a placeholder — REJECTED. A placeholder would be a fixed string, defeating the point of HMAC-hashing (a known value is a known value). (b) Plain unique without WHERE — REJECTED. PostgreSQL allows multiple NULLs in a unique index, so this technically works, but the explicit partial index documents the intent. (c) Composite unique on `(professional_id, telegram_chat_id_hash)` — REJECTED. Two patients of different psychologists could theoretically share a chat_id (a person who is a patient of two different therapists); a composite unique would block re-onboarding.
**Rationale:** the index is the lookup primitive. The hash itself is enough to identify the chat — the professional is implied by `telegram_chat_id_hash = HMAC(chat_id, psychologist_id_pepper)` (the pepper is per-psychologist, so the same `chat_id` produces a different hash for a different therapist).

### Decision 6: `update_id` dedup is Oban unique-by on the inbound job, no `processed_updates` table

**Choice:** `AletheaJobs.TelegramMessageWorker` declares `use Oban.Worker, queue: :telegram_inbound, max_attempts: 3, unique: [period: 86_400, keys: [:telegram_update_id]]`. Telegram's `update_id` is monotonically increasing globally per bot, so a 24h period comfortably covers webhook-retry windows and Oban crash-retry. The Oban jobs table is auto-pruned by the existing Oban config (the foundation v2 set `prune` defaults; we keep them).
**Alternatives considered:** (a) Separate `processed_updates` table — REJECTED for the foundation. It adds a write per inbound, a cleanup job, and a race against Oban's own unique-period state. (b) In-memory ETS dedup — REJECTED. Crashes lose state; a duplicate Telegram retry would re-process. (c) `unique: [period: :infinity]` — REJECTED. Oban's unique index grows unbounded; 24h matches Telegram's retry-attempt budget.
**Rationale:** Oban's unique state IS the dedup state. Adding a second table is duplication. If we later need long-term audit ("has this `update_id` ever been seen?"), we can ADD the table in a future change without breaking the worker.

---

## 3. Data Flow

### Inbound: webhook → worker → emotion → LLM → outbound job

```
Telegram Bot API
   │  POST  (header: X-Telegram-Bot-Api-Secret-Token)
   ▼
AletheaWeb.TelegramWebhookController.receive/2
   │  1. validate_secret_token(conn)   ── 401 on mismatch (no body parse, no log)
   │  2. parse Update (Jason)
   │  3. build hash: chat_id_hash = HMAC-SHA256(update.message.chat.id, bot_paciente_pepper)
   │  4. %{update_id, chat_id_hash, telegram_message_id, text, patient_id: nil}
   │     │  (worker resolves patient by hash inside the job — see Step 5)
   ▼
Oban.insert(TelegramMessageWorker, unique: [period: 86_400, keys: [:telegram_update_id]])
   │
   │  HTTP 200 OK   (fast ack — Telegram requires < 2 s)
   ▼
[telegram_inbound queue, priority default]
   │
AletheaJobs.TelegramMessageWorker.perform/1
   │  5. lookup_patient_by_chat_hash(chat_id_hash)        ── :not_found → 200 + "unregistered" reply
   │  6. Clinical.save_message(patient, text, "inbound", "spontaneous",
   │                          telegram_message_id, session_id)
   │  7. schedule EmotionAnalysisWorker (existing, async)
   │  8. CrisisMonitor.detect(text) ── :safe → continue; :crisis → bypass
   │     :safe →
   │       9. build_patient_context(patient, recent_message_limit)
   │       10. Alethea.AI.llm().chat(messages)        (or the existing PhiWorker chain)
   │       11. Clinical.save_message(patient, llm_response, "outbound", "elicited", nil, session_id)
   │     :crisis →
   │       12. save_message inbound
   │       13. Clinical.save_ai_diagnosis(... model_version: "crisis-bypass" ...)
   │       14. Accounts.update_patient(patient, urgent_intervention: true)
   │       15. PubSub.broadcast("psychologist:alerts", :crisis_detected, ...)
   │  16. enqueue TelegramOutboundWorker with reply text + chat_id_hash + priority
   ▼
[telegram_outbound queue | telegram_outbound_crisis queue]
   │
AletheaJobs.TelegramOutboundWorker.perform/1
   │  17. Pacer.acquire(chat_id_hash)   ── blocks until 1 msg/s/chat + 30 msg/s global
   │  18. Client.send_message(chat_id, text)
   │      ├─ 200 → :ok
   │      ├─ 429 + Retry-After → schedule retry with backoff + jitter
   │      └─ 5xx / network → schedule retry (max 5)
   │  19. exhausted → dead-letter table + PubSub :outbound_dead_letter
   ▼
[Telegram Bot API → patient]
```

### Onboarding: deep-link + 6-digit code

```
Psychologist (web) clicks "Invite patient" → Alethea.Foundation.Accounts.create_patient_auth_code
   │  row: %{patient_id, code: <32-byte URL-safe token | 6 digits>, kind: "deep_link" | "six_digit",
   │        expires_at: now + 10 min, used_at: nil, attempt_count: 0, ip: nil}
   │
   ▼
Invite URL:  https://t.me/<bot_username>?start=<token>
            OR  https://t.me/<bot_username>  (bot shows "send /start" → patient types the 6-digit code)
   │
   ▼
Patient opens Telegram, taps the link, lands in the bot chat
   │  Telegram sends Update with message.text == "/start <token>"
   ▼
AletheaWeb.TelegramWebhookController.receive/2
   │  detects /start → enqueue AletheaJobs.TelegramOnboardingWorker (separate queue :telegram_inbound, lower max_attempts)
   │  HTTP 200
   ▼
AletheaJobs.TelegramOnboardingWorker.perform/1
   │  1. extract token from "/start <token>"
   │  2. Accounts.verify_patient_auth_code(token, ip, kind: "deep_link")
   │     ├─ :ok, code not used, not expired, attempt_count < 5/IP/hour
   │     │    → mark code.used_at; compute chat_id_hash; update patient.telegram_chat_id_hash
   │     │    → enqueue TelegramOutboundWorker with welcome message (personality-aware)
   │     ├─ :expired → send_message "Tu link venció. Pedile a tu terapeuta uno nuevo."
   │     ├─ :already_used → send_message "Este link ya fue usado."
   │     └─ :rate_limited (5 attempts/hour/IP) → send_message "Demasiados intentos. Probá más tarde."
```

A `TelegramAuthController` at `GET /webhooks/telegram/auth?code=<6digit>` covers the manual fallback: the patient types the 6-digit code in the web invite page (not in Telegram), which is the same row with `kind: "six_digit"`.

---

## 4. Module Map

| Module | Path | Role | Justification |
|---|---|---|---|
| `Alethea.Telegram.Client` (behaviour) | `lib/alethea/telegram/client.ex` | Port (output adapter contract) | Mirror of `Alethea.WhatsApp.ClientBehaviour`; one callback `send_message/2`. |
| `Alethea.Telegram.Client.Req` | `lib/alethea/telegram/client/req.ex` | Req impl | Mirror of `Alethea.WhatsApp.Client`; production HTTP. |
| `Alethea.Telegram.Client.Fake` | `lib/alethea/telegram/client/fake.ex` | Test/dev impl | Stores last call in process dict; used in `mix test`. |
| `Alethea.Telegram.BotToken` | `lib/alethea/telegram/bot_token.ex` | Secret accessor | Loads `BotConfig.for_env(Mix.env())` once at boot; exposes `bot_token/0` and `secret_token/0` and `bot_username/0`. Refetched on `Application.get_env(:alethea, :telegram, :rotate)`. |
| `Alethea.Telegram.Pacer` | `lib/alethea/telegram/pacer.ex` | Outbound rate limiter | GenServer + 2 ETS tables (per_chat, global). `acquire(chat_id_hash)` returns `:ok` after both buckets allow. |
| `Alethea.Telegram.DeepLinkToken` | `lib/alethea/telegram/deep_link_token.ex` | Ephemeral token mint/verify | Pure functions: `mint/1` → 32-byte URL-safe string; `verify/2` → `{:ok, patient_id} | {:error, reason}`. |
| `Alethea.Foundation.Accounts.PatientAuthCode` (NEW schema) | `lib/alethea/foundation/accounts/patient_auth_code.ex` | Domain (auth_codes table) | `create_patient_auth_code/2`, `verify_patient_auth_code/3`, `consume_patient_auth_code/2`. |
| `Alethea.Foundation.Accounts.BotConfig` (NEW schema) | `lib/alethea/foundation/accounts/bot_config.ex` | Domain (sealed bot token row) | `for_env/1`, `upsert/2`, `:env` enum check. |
| `Alethea.Foundation.Accounts.Patient` (MODIFY) | `lib/alethea/foundation/accounts/patient.ex` | Domain (column rename) | Drop `telegram_chat_id` from cast; add `telegram_chat_id_hash`. |
| `AletheaWeb.TelegramWebhookController` (NEW) | `lib/alethea_web/controllers/telegram_webhook_controller.ex` | Input adapter (HTTP) | Two actions: `verify/2` (no-op for Telegram — it does not call GET) and `receive/2`. |
| `AletheaWeb.TelegramAuthController` (NEW) | `lib/alethea_web/controllers/telegram_auth_controller.ex` | Input adapter (HTTP, deep-link exchange) | One action: `consume/2` reads `?start=…` (Telegram redirects) or `?code=…` (manual fallback). |
| `AletheaJobs.TelegramMessageWorker` (NEW) | `lib/alethea_jobs/telegram_message_worker.ex` | Oban worker (inbound) | `use Oban.Worker, queue: :telegram_inbound, max_attempts: 3`. |
| `AletheaJobs.TelegramOnboardingWorker` (NEW) | `lib/alethea_jobs/telegram_onboarding_worker.ex` | Oban worker (onboarding) | `use Oban.Worker, queue: :telegram_inbound, max_attempts: 2`. |
| `AletheaJobs.TelegramOutboundWorker` (NEW) | `lib/alethea_jobs/telegram_outbound_worker.ex` | Oban worker (outbound) | `use Oban.Worker, queue: :telegram_outbound, max_attempts: 5`. |
| `AletheaWeb.Plugs.TelegramSecretToken` (NEW) | `lib/alethea_web/plugs/telegram_secret_token.ex` | Plug | Validates `X-Telegram-Bot-Api-Secret-Token` against `BotToken.secret_token/0`; short-circuits 401. |
| `Alethea.Telegram.Updates.Parser` (NEW, optional) | `lib/alethea/telegram/updates/parser.ex` | Pure module | Maps `Update` JSON → `%{update_id, chat_id, message_id, text, is_command, command_args}`. Optional; the controller can inline this. |

**Schema decision (Patient vs PatientTelegramLink):** extend `Patient`, do not create a new `PatientTelegramLink` table. A patient has AT MOST one Telegram chat (per design: deep link binds to a specific patient, chat ID is unique per patient). Creating a separate join table would be a 1:1 table that adds a join for no reason; the foundation patient is already the canonical identity row.

**BotConfig decision:** new schema (not extension of an existing encrypted config). Per Decision 4 above.

---

## 5. Supervision Tree Delta

```elixir
# lib/alethea/application.ex  (additions only)
children = [
  AletheaWeb.Telemetry,
  Alethea.Repo,
  {DNSCluster, query: Application.get_env(:alethea, :dns_cluster_query) || :ignore},
  {Phoenix.PubSub, name: Alethea.PubSub},
  Alethea.Encryption.Vault,
  Alethea.WhatsApp.ConsentCache,
  Alethea.RateLimiter,
  Alethea.Telegram.Pacer,           # NEW: GenServer, two ETS tables
  {Oban, Application.fetch_env!(:alethea, Oban)},  # queues updated, see below
  AletheaWeb.Endpoint
]
```

### Oban queues (config :alethea, Oban)

```elixir
config :alethea, Oban,
  engine: Oban.Engines.Basic,
  queues: [
    default: 10,
    whatsapp: 20,
    sessions: 10,
    schedulers: 5,
    reports: 5,
    ai_analysis: 5,
    telegram_inbound: 10,         # NEW: webhook payload processing
    telegram_outbound: 5,         # NEW: paced send (rate-limit is the pacer, not the queue)
    telegram_outbound_crisis: 2   # NEW: priority lane, must never starve
  ],
  repo: Alethea.Repo,
  plugins: [
    {Oban.Plugins.Cron,
     crontab: [{"0 0 * * *", AletheaJobs.DailySchedulerWorker}]}
  ]
```

| Queue | Priority | `max_demand` | Role |
|---|---|---|---|
| `telegram_inbound` | default (5) | 10 | Webhook payload → `TelegramMessageWorker`, `TelegramOnboardingWorker`. Concurrency = 10 covers Telegram's max ~30 updates/s; the worker is IO-bound on the DB lookup. |
| `telegram_outbound` | default (5) | 5 | `TelegramOutboundWorker` for non-crisis replies. 5 concurrent sends × ~150 ms p50 = ~33 msg/s, which is the GLOBAL Telegram limit. |
| `telegram_outbound_crisis` | default (5) | 2 | Priority lane. Smaller `max_demand` so it stays small and is serviced first when the system is busy; crisis replies bypass the pacer if needed. |

**Rationale for `max_demand` numbers (Q3):** the global Telegram limit is 30 msg/s, the per-chat limit is 1 msg/s. With 5 concurrent outbound workers and a pacer that paces at 1 msg/s/chat and 30 msg/s global, the steady-state throughput is exactly 30 msg/s. `telegram_outbound_crisis` at 2 is sized to allow one full crisis round-trip per second without starving `telegram_outbound`. The 1 Hz refill on `:per_chat` and 30 Hz refill on `:global` are constants in the Pacer module, not config — they map directly to Telegram's published limits.

**Telegram rate-limit backpressure math:**
- Webhook receives ≤ 30 updates/s (Telegram's published cap is "a few per second per bot", but the spec allows bursts up to 100/s in a 1s window; the Oban queue's 10 concurrent workers + 10s unique-period retry absorbs the burst).
- Outbound: 5 workers × paced 6 msg/min/chat (one per 10s if not capped) = 30 msg/s global ceiling.
- Crisis lane: 2 workers × paced 1 msg/s = 2 msg/s capacity, sufficient for the 0–1 crisis events per day expected.

---

## 6. Data Model & Migrations

### Migration 1: `20260615XXXXXX_rename_telegram_chat_id_to_hash.exs`

```elixir
defmodule Alethea.Repo.Migrations.RenameTelegramChatIdToHash do
  use Ecto.Migration

  def change do
    # Per Decision 5: nullable + partial unique index.
    alter table(:foundation_patients) do
      remove :telegram_chat_id   # was :string, null: true
      add :telegram_chat_id_hash, :string
    end

    create unique_index(:foundation_patients, [:telegram_chat_id_hash],
             name: :foundation_patients_telegram_chat_id_hash_unique,
             where: "telegram_chat_id_hash IS NOT NULL")
  end
end
```

**Backfill note:** no rows have `telegram_chat_id` populated in dev (verified per proposal handoff). The migration is forward-only. On rollback, the column would be re-added as nullable.

### Migration 2: `20260615XXXXXX_create_foundation_patient_auth_codes.exs`

```elixir
defmodule Alethea.Repo.Migrations.CreateFoundationPatientAuthCodes do
  use Ecto.Migration

  def change do
    create table(:foundation_patient_auth_codes, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :patient_id, references(:foundation_patients, type: :binary_id, on_delete: :delete_all), null: false
      add :code, :string, null: false
      add :kind, :string, null: false            # "deep_link" | "six_digit"
      add :expires_at, :utc_datetime, null: false
      add :used_at, :utc_datetime
      add :attempt_count, :integer, default: 0, null: false
      add :last_attempt_ip, :string
      timestamps(type: :utc_datetime)
    end

    # Unique on (patient_id, code, kind) — a patient cannot have two active deep-link
    # tokens for the same code. used_at IS NOT NULL means the code has been consumed.
    create unique_index(:foundation_patient_auth_codes, [:patient_id, :code, :kind],
             name: :foundation_patient_auth_codes_patient_code_kind_unique)

    # Lookup by code + kind for verify (covers the deep-link redirect path).
    create index(:foundation_patient_auth_codes, [:code, :kind])

    # Cleanup job prunes WHERE expires_at < now() AND used_at IS NULL.
    create index(:foundation_patient_auth_codes, [:expires_at])

    # Rate-limit lookup: WHERE last_attempt_ip = $1 AND inserted_at > now() - 1h.
    create index(:foundation_patient_auth_codes, [:last_attempt_ip, :inserted_at])
  end
end
```

### Migration 3: `20260615XXXXXX_create_foundation_bot_configs.exs`

```elixir
defmodule Alethea.Repo.Migrations.CreateFoundationBotConfigs do
  use Ecto.Migration

  def change do
    create table(:foundation_bot_configs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :env, :string, null: false             # "dev" | "test" | "prod"
      add :token_ciphertext, :binary, null: false              # Cloak.Ecto.Binary
      add :bot_username, :string, null: false
      add :secret_token_ciphertext, :binary, null: false      # Cloak.Ecto.Binary (X-Telegram-Bot-Api-Secret-Token)
      timestamps(type: :utc_datetime)
    end

    create unique_index(:foundation_bot_configs, [:env], name: :foundation_bot_configs_env_unique)
  end
end
```

**Why Cloak.Ecto.Binary, not a custom vault slot:** the `Alethea.Encryption.Vault` is an in-process GenServer holding a single AES key for the whole app. It is the right home for app-wide config (e.g., the bot token was previously considered for a vault slot). We use it for the `token_ciphertext` field via `Cloak.Ecto.Binary` because:

1. The vault IS the encryption primitive (Cloak is just the field type).
2. Per-tenant KEK/DEK is not the right granularity for a single global bot token.
3. Future rotation: changing the Cloak cipher's `key` re-wraps all `token_ciphertext` values — the same pattern as the existing `Alethea.Encryption.Vault` rotation.

---

## 7. Secret / Encryption Model (per `encryption-vault` skill)

### `Alethea.Encryption.Vault` extension (no module change)

The Vault module is untouched. We use it implicitly through `Cloak.Ecto.Binary` on the new `token_ciphertext` and `secret_token_ciphertext` columns. The Cloak key (config `:alethea, Alethea.Encryption.Vault, aes_key`) is the same key that protects the legacy `WhatsApp.*` encrypted fields.

### `Alethea.Telegram.BotToken` accessor (NEW)

```elixir
defmodule Alethea.Telegram.BotToken do
  @moduledoc """
  Loads the sealed bot config once at boot. Re-fetches on SIGHUP / rotation.
  """
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  def bot_token,       do: GenServer.call(__MODULE__, :bot_token)
  def secret_token,    do: GenServer.call(__MODULE__, :secret_token)
  def bot_username,    do: GenServer.call(__MODULE__, :bot_username)

  @impl GenServer
  def init(_), do: {:ok, load()}

  @impl GenServer
  def handle_call(which, _from, state) do
    {:reply, Map.fetch!(state, which), state}
  end

  def handle_info(:reload, _state), do: {:noreply, load()}

  defp load do
    Alethea.Foundation.Accounts.BotConfig.for_env(Mix.env())
    # returns %{bot_token: <plaintext>, secret_token: <plaintext>, bot_username: <string>}
    # plaintext only lives in this process's state
  end
end
```

`BotToken` is added to the supervision tree under `:telegram_pacer`. The rotation hook is `Application.get_env(:alethea, :telegram, :reload) == true` → send `BotToken` a `:reload` message.

### `telegram_chat_id_hash` HMAC

```elixir
# lib/alethea/telegram/chat_id_hash.ex  (NEW, pure module)
def hash(chat_id, psychologist_pepper) do
  :crypto.mac(:hmac, :sha256, psychologist_pepper, to_string(chat_id))
  |> Base.encode16(case: :lower)
end
```

**Per-psychologist pepper (Q4 from proposal):** the pepper is stored in the `Alethea.Encryption.Vault` as a per-psychologist key. For the foundation, we ship ONE global pepper (env-driven: `TELEGRAM_CHAT_ID_PEPPER`), sufficient because:

- The foundation is single-tenant per-deployment.
- The HMAC prevents cross-tenant correlation at the database layer (per `encryption-vault` skill: "HMAC usa `psychologist_id` como sal").
- Per-psychologist pepper is a future change (`telegram-paciente-multi-tenant`) that swaps the input domain from `psychologist_id` to `(tenant_id, chat_id)`.

**Rotation policy (ADR-0008):** if the pepper is rotated, **cryptographic erasure** is performed on the `foundation_patients.telegram_chat_id_hash` column (UPDATE all rows → NULL). The clinical data (encrypted `Message.body` via the per-patient DEK) is **unaffected** — only the lookup key is destroyed. Every patient must re-onboard on next `/start`. This is the locked Q4 decision from the proposal handoff.

---

## 8. Webhook Security

```elixir
# lib/alethea_web/plugs/telegram_secret_token.ex
defmodule AletheaWeb.Plugs.TelegramSecretToken do
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    expected = Alethea.Telegram.BotToken.secret_token()

    case get_req_header(conn, "x-telegram-bot-api-secret-token") do
      [token] when token == expected -> conn
      _ -> conn |> send_resp(401, "Unauthorized") |> halt()
    end
  end
end
```

**Order in the pipeline (router):**

```elixir
pipeline :telegram_webhook do
  plug :accepts, ["json"]
  plug AletheaWeb.Plugs.TelegramSecretToken   # 401 short-circuit BEFORE body parse
end

scope "/webhooks", AletheaWeb do
  pipe_through :telegram_webhook
  post "/telegram", TelegramWebhookController, :receive
  get  "/telegram/auth", TelegramAuthController, :consume
end
```

- 401 on header mismatch: **NO** body parse, **NO** Logger output, **NO** increment of any rate limiter.
- Replay: same `update_id` → Oban `unique: [period: 86_400, keys: [:telegram_update_id]]` returns `:ok` (job already exists) → the worker short-circuits with `:ok` → 200.
- Telegram `setWebhook` MUST be called with the same `secret_token` value as the `BotConfig.secret_token_ciphertext` plaintext. This is a deploy step (documented in `docs/runbooks/telegram-setwebhook.md`, written in a future change).

---

## 9. End-to-End Clinical Round-Trip (C-5)

The call chain in §3 is the spec. Concrete module calls:

| # | Module | Function | Notes |
|---|---|---|---|
| 1 | `AletheaWeb.TelegramWebhookController` | `receive/2` | Header validate, parse, enqueue. |
| 2 | `Oban` | `insert/1` | `unique` key = `:telegram_update_id`. |
| 3 | `AletheaJobs.TelegramMessageWorker` | `perform/1` | Resolves patient, persists message, schedules analysis. |
| 4 | `Alethea.Foundation.Accounts` | `lookup_patient_by_chat_hash/1` | New function. Where `:not_found` → 200 + "unregistered" reply (no queue, no log of chat_id). |
| 5 | `Alethea.Clinical` | `save_message/7` | Same as WhatsApp, with `telegram_message_id` instead of `whatsapp_message_id`. |
| 6 | `AletheaJobs.EmotionAnalysisWorker` | `new/1` \| `Oban.insert/1` | Reused; same `ai_analysis` queue. |
| 7 | `Alethea.Alerts.CrisisMonitor` | `detect/1` | Reused; same patterns. |
| 8 | `Alethea.AI.llm()` | `chat/2` | Discovery → `Alethea.AI.LLM.Fake` (test/dev) or future Groq adapter. |
| 9 | `AletheaJobs.TelegramOutboundWorker` | `new/1` \| `Oban.insert/1` | Crisis → `:telegram_outbound_crisis` queue. |
| 10 | `Alethea.Telegram.Pacer` | `acquire/1` | Blocks until both buckets allow. |
| 11 | `Alethea.Telegram.Client` | `send_message/2` | `Fake` (test) or `Req` (prod). |
| 12 | 429 path | `handle_info(:retry, ...)` | Exponential backoff with jitter, max 5 attempts. |
| 13 | Dead-letter | `Alethea.Telegram.OutboundDeadLetter` | New module, logs to `outbound_dead_letters` table + PubSub `:outbound_dead_letter`. |

**Reused prompt template:** the `Alethea.AI.Chains.GuidedConversationChain` `system_prompt` (in `config/config.exs:56`) is the same for both channels. The only new field in the chain input is `channel: :telegram`, which the chain can use to swap the platform-aware header (`"Alethea (Telegram):"`). The chain itself is NOT modified in this change.

---

## 10. Rate-Limit Concrete Numbers (Q3)

| Channel constraint | Oban queue | `max_demand` | Pacer bucket |
|---|---|---|---|
| 1 msg/s/chat | `telegram_outbound` | 5 | `:per_chat` refill 1 Hz |
| 30 msg/s global | `telegram_outbound` | 5 | `:global` refill 30 Hz |
| Crisis bypass | `telegram_outbound_crisis` | 2 | bypasses pacer if full (see Q9) |
| Inbound concurrency | `telegram_inbound` | 10 | none (Telegram pushes; we ack fast) |

**Back-of-envelope:** worst case = 30 crisis replies in a 1s window. `telegram_outbound_crisis` at 2 concurrent workers × paced 1 msg/s/worker = 2 msg/s capacity, but the bypass path (Q9) lets crisis jobs jump the queue and acquire the global bucket directly, so the effective crisis throughput is 2 msg/s sustained + burst capacity of `telegram_outbound`'s idle 28 msg/s. The pacer is the single bottleneck; the Oban queues are just a delivery mechanism.

---

## 11. `update_id` Dedup State (Q8)

| Aspect | Decision |
|---|---|
| Storage | Oban's own `oban_jobs` table. No new `processed_updates` table. |
| Oban unique config | `unique: [period: 86_400, keys: [:telegram_update_id]]` (24h). |
| Why 24h? | Telegram retries webhooks for up to ~24h on non-2xx; we always return 2xx, so 24h is generous. |
| Retention | Oban `oban_jobs` rows are auto-pruned by `Oban.Plugins.Pruner` (default 60s cadence, 7-day retention); the unique state lives for the worker's lifetime. |
| Crash-retry | Oban's `max_attempts: 3` covers a single-process crash; a worker that crashes AFTER sending the reply but BEFORE the Oban row commits is retried and hits the `unique` guard. |
| Long-term audit | Out of scope for this change. A future "telegram audit" change may add a `processed_updates` table for compliance without breaking the worker. |

---

## 12. Crisis-Bypass Priority Lane (Q9)

**Queue name:** `telegram_outbound_crisis`
**Priority:** default (5) — Oban does not have per-queue priority, only per-job `priority` int. We use the queue name + worker logic to implement priority:
**max_demand:** 2

**Escalation rule (crisis message MUST NOT be dropped on queue full):**

```elixir
# In TelegramMessageWorker, crisis branch:
case AletheaJobs.TelegramOutboundWorker.new(args, queue: :telegram_outbound_crisis)
     |> Oban.insert() do
  {:ok, _job} ->
    :ok

  {:error, %Oban.InsertError{reason: :queue_full}} ->
    # Crisis escalation: bypass the queue and send via direct path.
    # Still goes through Pacer.acquire/1 (we never skip rate-limit, we skip the queue).
    Logger.error("Crisis queue full; escalating to direct send for chat_id_hash=#{chat_id_hash}")
    Phoenix.PubSub.broadcast(Alethea.PubSub, "ops:alerts", {:crisis_queue_full, chat_id_hash})
    spawn(fn -> AletheaJobs.TelegramOutboundWorker.perform_now(args) end)
end
```

- `Oban.InsertError` with `reason: :queue_full` is raised when the configured `max_demand` is reached.
- The escalation path spawns a one-off process that runs the worker body directly, **still going through the Pacer** (rate-limit is never skipped, only the queue is).
- Operator alert: PubSub broadcast on `ops:alerts` (consumed by an admin LiveView in a future change) + a `Logger.error` line. No PagerDuty integration in this slice.

---

## 13. Test Plan (strict TDD)

Order is the order the tests are written; each test goes red → green → refactor.

| # | Test file | Test name | Area |
|---|---|---|---|
| 1 | `test/alethea/foundation/accounts/patient_auth_code_test.exs` | `create_patient_auth_code/2` mints a deep-link token with TTL 10 min and 0 attempts | Domain |
| 2 | `test/alethea/foundation/accounts/patient_auth_code_test.exs` | `verify_patient_auth_code/3` returns `:ok` for an unexpired unused token | Domain |
| 3 | `test/alethea/foundation/accounts/patient_auth_code_test.exs` | `verify_patient_auth_code/3` returns `:expired` past `expires_at` and `:already_used` after `consume` | Domain |
| 4 | `test/alethea/foundation/accounts/patient_auth_code_test.exs` | `verify_patient_auth_code/3` returns `:rate_limited` after 5 attempts in 1h from the same IP | Domain |
| 5 | `test/alethea/telegram/chat_id_hash_test.exs` | `hash/2` is deterministic for same input + pepper, different for different peppers, and never logs/echoes the chat_id | Pure |
| 6 | `test/alethea/telegram/client/fake_test.exs` | `Alethea.Telegram.Client.Fake.send_message/2` records the call in the test process and returns `{:ok, %{message_id: …}}` | Test adapter |
| 7 | `test/alethea_web/plugs/telegram_secret_token_test.exs` | returns 401 when header is missing or wrong, never calls downstream plugs | Plug |
| 8 | `test/alethea_web/controllers/telegram_webhook_controller_test.exs` | `POST /webhooks/telegram` returns 401 on bad secret-token, 200 on good | Controller |
| 9 | `test/alethea_web/controllers/telegram_webhook_controller_test.exs` | valid `Update` payload enqueues exactly one `TelegramMessageWorker` with the right `update_id` | Controller + Oban |
| 10 | `test/alethea_jobs/telegram_message_worker_test.exs` | worker resolves patient by `chat_id_hash`, persists inbound message, returns `:ok` | Worker |
| 11 | `test/alethea_jobs/telegram_message_worker_test.exs` | duplicate `update_id` (via `Oban.Testing`) is no-op and logs `:ok` | Worker idempotency |
| 12 | `test/alethea_jobs/telegram_message_worker_test.exs` | crisis branch enqueues on `:telegram_outbound_crisis` and broadcasts `:crisis_detected` | Worker crisis path |
| 13 | `test/alethea_jobs/telegram_outbound_worker_test.exs` | calls `Pacer.acquire/1` then `Client.send_message/2`; 429 triggers `schedule_retry` with backoff+jitter | Outbound |
| 14 | `test/alethea/telegram/pacer_test.exs` | `acquire/1` allows 1 msg/s/chat, 30 msg/s global, blocks beyond | Pacer |
| 15 | `test/alethea_web/controllers/telegram_auth_controller_test.exs` | `GET /webhooks/telegram/auth?start=<token>` marks the code `used_at` and returns 200 | Onboarding |

`mix test` path: `mix test test/alethea/foundation/accounts/patient_auth_code_test.exs` per file, then `mix test` for the full suite. `mix precommit` at the end (per `AGENTS.md`).

---

## 14. ADR-0008 Stub

**Path:** `openspec/adr/008-telegram-chat-id-pepper-rotation.md` (per project convention; **NOT** `docs/adr/` — the project uses `openspec/adr/` per `CONTEXT.md` and the existing ADR files).

### Context

The `telegram_chat_id_hash` column is the lookup key for the patient → Telegram chat binding. The HMAC uses a per-deployment pepper (env var `TELEGRAM_CHAT_ID_PEPPER`) so that the database alone cannot reveal which chat_id belongs to which patient. If the pepper is leaked (env var exfiltration, accidental commit, operational error), the database is effectively de-anonymized for the chat_id column. We need a rotation policy that (a) makes the failure mode of a leaked pepper recoverable, (b) is auditable, and (c) does not silently lose clinical data.

### Decision

**Option (a) — Manual rotation + explicit re-onboarding.**

1. The pepper is stored in ONE place: the `TELEGRAM_CHAT_ID_PEPPER` environment variable. It is NEVER persisted to the database.
2. The pepper has NO version byte. There is exactly one active pepper at any time.
3. Rotation is a manual operator action: deploy with a new `TELEGRAM_CHAT_ID_PEPPER`, run a Mix task `mix alethea.telegram.rotate_pepper` which:
   a. Sets all `foundation_patients.telegram_chat_id_hash` values to `NULL`.
   b. Marks all `foundation_patient_auth_codes` with `kind: "deep_link"` as `used_at: NOW()`.
   c. Logs a `Logger.warning` with the operator-provided rotation reason.
   d. Emits a PubSub broadcast on `ops:alerts` with `{:pepper_rotated, rotated_at: NOW()}`.
4. Every patient must re-onboard on next `/start`. The welcome message after a rotation includes copy: "Por tu seguridad, volvé a vincular tu cuenta."
5. The `Message.body` ciphertext (Cloak.Ecto) is UNAFFECTED — the per-patient DEK is independent of the chat_id pepper.

### Consequences

**Positive:**
- The blast radius of a leaked pepper is a one-time re-onboarding, not a data breach.
- No silent data loss. The `Message.body` is preserved; only the chat_id lookup key is destroyed.
- The rotation is auditable: a single Mix task run with a logged reason is a clean event in the timeline.

**Negative:**
- Every active patient must re-tap a deep link. Friction during the rotation window.
- The Mix task is an operational burden; it is the price of "no versioned pepper, no silent rotation".

**Rejected alternatives:**
- (b) **Versioned pepper, dual-hash on read** — REJECTED. The complexity (two HMACs, dual-key migration, eventual cutover) does not buy enough safety over the manual-rotation simplicity. We are not at WhatsApp scale.
- (c) **Silent rotation (read both peppers, write to new one)** — REJECTED. A silent rotation is the worst failure mode: operators do not know it happened, and a leaked pepper is still in use.
- (d) **Re-encrypt `Message.body` on rotation** — REJECTED. The DEK is unrelated to the chat_id pepper; re-encrypting is a no-op and adds risk.

---

## 15. File Changes Summary

| File | Action | Description |
|---|---|---|
| `lib/alethea/telegram/client.ex` | Create | `Alethea.Telegram.Client` behaviour + `send_message/2` callback. |
| `lib/alethea/telegram/client/req.ex` | Create | Req implementation; reads `BotToken.bot_token/0` and posts to `https://api.telegram.org/bot<TOKEN>/sendMessage`. |
| `lib/alethea/telegram/client/fake.ex` | Create | Test/dev `Fake` adapter; records last call in process dict, returns `{:ok, %{message_id: <gen>>}}`. |
| `lib/alethea/telegram/bot_token.ex` | Create | GenServer accessor for the sealed bot config. |
| `lib/alethea/telegram/pacer.ex` | Create | GenServer with two ETS TokenBuckets. |
| `lib/alethea/telegram/chat_id_hash.ex` | Create | Pure HMAC-SHA256 helper. |
| `lib/alethea/telegram/deep_link_token.ex` | Create | Pure mint/verify. |
| `lib/alethea/foundation/accounts/patient_auth_code.ex` | Create | Schema + context. |
| `lib/alethea/foundation/accounts/bot_config.ex` | Create | Schema + `for_env/1`. |
| `lib/alethea/foundation/accounts/patient.ex` | Modify | Drop `telegram_chat_id` from cast; add `telegram_chat_id_hash`. |
| `lib/alethea/foundation/accounts.ex` | Modify | Add `lookup_patient_by_chat_hash/1`. |
| `lib/alethea_jobs/telegram_message_worker.ex` | Create | Inbound Oban worker (idempotent by `update_id`). |
| `lib/alethea_jobs/telegram_onboarding_worker.ex` | Create | Onboarding Oban worker. |
| `lib/alethea_jobs/telegram_outbound_worker.ex` | Create | Outbound Oban worker with Pacer + retry. |
| `lib/alethea_web/controllers/telegram_webhook_controller.ex` | Create | `POST /webhooks/telegram` — `receive/2`. |
| `lib/alethea_web/controllers/telegram_auth_controller.ex` | Create | `GET /webhooks/telegram/auth` — `consume/2`. |
| `lib/alethea_web/plugs/telegram_secret_token.ex` | Create | Header validation plug. |
| `lib/alethea_web/router.ex` | Modify | Add `pipeline :telegram_webhook` + `scope "/webhooks", …` block. |
| `lib/alethea/application.ex` | Modify | Add `Alethea.Telegram.Pacer`, `Alethea.Telegram.BotToken` to children. |
| `config/config.exs` | Modify | Add three Oban queues (`telegram_inbound`, `telegram_outbound`, `telegram_outbound_crisis`). |
| `config/runtime.exs` | Modify | Read `TELEGRAM_BOT_TOKEN`, `TELEGRAM_SECRET_TOKEN`, `TELEGRAM_CHAT_ID_PEPPER` from env. |
| `config/test.exs` | Modify | Add test-only pepper + `Alethea.Telegram.Client, Alethea.Telegram.Client.Fake` adapter swap. |
| `priv/repo/migrations/20260615XXXXXX_rename_telegram_chat_id_to_hash.exs` | Create | Column rename + partial unique index. |
| `priv/repo/migrations/20260615XXXXXX_create_foundation_patient_auth_codes.exs` | Create | New `foundation_patient_auth_codes` table. |
| `priv/repo/migrations/20260615XXXXXX_create_foundation_bot_configs.exs` | Create | New `foundation_bot_configs` table. |
| `openspec/adr/008-telegram-chat-id-pepper-rotation.md` | Create | ADR for manual rotation policy. |
| 15 test files | Create | One per module above. |

**Estimated changed lines:** ~1,400 net new (≈ 900 LOC production + 500 LOC tests). Within the 400-line review budget threshold per `openspec/config.yaml:11`, so the work is naturally split into ≤ 4 commits per `work-unit-commits` discipline: (1) schema + migration, (2) BotToken + Pacer, (3) WebhookController + MessageWorker, (4) OutboundWorker + AuthController + ADR.

---

## 16. Migration / Rollout

1. **Forward:** `mix ecto.migrate`. The column rename is forward-only. Backfill is a no-op (no existing rows with `telegram_chat_id` populated). The two new tables are additive.
2. **Bootstrap (one-time, dev/test/prod):** seed a `BotConfig` row per env with the bot token from `@BotFather` and the secret token from the `setWebhook` call.
3. **Operator step:** call `setWebhook` against `https://<ALETHEA_HOST>/webhooks/telegram` with the same `secret_token` value that was stored in `BotConfig`.
4. **Feature flag:** `config :alethea, :telegram_enabled, true`. The controller reads this at the top of `receive/2` and short-circuits 200 OK (Telegram expects 2xx) without enqueueing if disabled.
5. **Rollback:** `mix ecto.rollback` for the three migrations; remove the three Oban queue entries; remove the new plugs. The legacy `foundation_patients` table is unchanged structurally (only the column was renamed).
6. **No data destruction.** The Message table is untouched. The chat_id column is the only renamed artifact.

---

## 17. Open Questions Resolved (this design)

| Q | Decision |
|---|---|
| **Q2** (deep-link token thresholds) | Defaults from proposal lock: TTL 10 min, 5 attempts/hour/IP, 32-byte URL-safe token. 6-digit code shares the same `foundation_patient_auth_codes` table with `kind: "six_digit"`. |
| **Q3** (RateLimiter scale / Oban queue priority) | `telegram_inbound: 10`, `telegram_outbound: 5`, `telegram_outbound_crisis: 2`. Pacer is a GenServer with two ETS TokenBuckets. |
| **Q5** (Bot token storage) | New `BotConfig` schema with `env` discriminator; `Cloak.Ecto.Binary` for `token_ciphertext` and `secret_token_ciphertext`; one row per env. |
| **Q7** (6-digit code path) | Same `TelegramAuthController` as deep-link, same `foundation_patient_auth_codes` table, different `kind`. Webhook hot path stays in a separate controller. |
| **Q8** (Idempotency window) | Oban `unique: [period: 86_400, keys: [:telegram_update_id]]` only. No `processed_updates` table. |
| **Q9** (Crisis-bypass queue priority) | Queue `telegram_outbound_crisis`, `max_demand: 2`. On `Oban.InsertError{:queue_full}`, escalate to direct worker run (still pacer-paced) + `ops:alerts` PubSub broadcast. |

---

## 18. Risks Addressed (from proposal)

| Risk | Mitigation in design |
|---|---|
| **R-1: PHI in transport** | `Message.body` stored as `Cloak.Ecto.Binary` (existing convention). `Message` row never logged with `body`. Telegram payload body NOT logged at any layer (controller and worker use `Logger.metadata`). |
| **R-2: Rate limits dropping a crisis message** | `Pacer` enforces 1 msg/s/chat + 30 msg/s global. `telegram_outbound_crisis` queue is sized at 2 with a `queue_full` escalation path that bypasses the queue but still respects the pacer. |
| **R-3: Message reordering** | `telegram_message_id` is persisted on the inbound `Message` row; the LLM prompt builder orders by `inserted_at` not by `message_id` (Telegram guarantees `message_id` is monotonic per chat but not per global). This is the same reconciliation pattern WhatsApp uses with `whatsapp_message_id`. |
| **R-4: Webhook spoofing** | `AletheaWeb.Plugs.TelegramSecretToken` validates the `X-Telegram-Bot-Api-Secret-Token` header BEFORE the body is parsed. 401 short-circuit, no log. |
| **R-5: Bot token blast radius** | `BotConfig` schema + `Cloak.Ecto.Binary` + per-env discriminator + `BotToken` GenServer that holds plaintext only in process state. No plaintext in env-var-only config (the existing WhatsApp pattern is the anti-pattern). |

---

## 19. Next Step

Ready for `sdd-spec` — each `C-1`…`C-7` capability above becomes a delta spec under `openspec/sdd/telegram-paciente-foundation/specs/<capability>/spec.md` with `## Purpose` + `## Requirements` (WHEN/THEN scenarios).
