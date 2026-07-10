# Spec — C-6: Vault-Sealed Bot Token

**Capability:** C-6 — Vault-sealed bot token
**Change:** `telegram-paciente-foundation`
**Status:** ADDED (this slice introduces the `BotConfig` schema and the
`BotToken` GenServer accessor)
**Module(s):** `Alethea.Foundation.Accounts.BotConfig`,
`Alethea.Telegram.BotToken`

---

## Purpose

The system shall store the Telegram bot token and webhook secret token as
encrypted binary fields in a `foundation_bot_configs` row keyed by environment
(`dev | test | prod`), expose them only through a `BotToken` GenServer accessor
that holds the plaintext in process state, and never read or write them from
plaintext environment variables in production configuration.

---

## Requirements

## REQ-C6-bot-token-stored-encrypted

The system shall persist the bot token and the webhook secret token as
`Cloak.Ecto.Binary` ciphertext in the `foundation_bot_configs` table — the
plaintext values shall not be present in any `INSERT` or `UPDATE` statement,
nor in any database dump, log line, or telemetry event.

#### Scenario: bot token is sealed at rest

- GIVEN a plaintext bot token `"123456:ABC-DEF…"`
- WHEN `BotConfig.upsert(env: :prod, bot_token: "123456:ABC-DEF…", …)` runs
- THEN the `token_ciphertext` column contains the AES ciphertext
- AND the plaintext is not stored in any other column
- AND the `token_ciphertext` is unreadable without the Cloak key

#### Scenario: webhook secret token is sealed at rest

- GIVEN a plaintext secret token `"some-shared-secret"`
- WHEN `BotConfig.upsert(env: :prod, secret_token: "some-shared-secret", …)` runs
- THEN the `secret_token_ciphertext` column contains the AES ciphertext
- AND no other column stores the plaintext

#### Scenario: decryption is allowed only through the accessor

- GIVEN a `BotConfig` row in `:prod` env
- WHEN `Alethea.Telegram.BotToken.bot_token/0` is called
- THEN the accessor returns the plaintext via the `Cloak` decrypt primitive
- AND the plaintext is held only in the GenServer's process state
- AND no other code path can read the plaintext without the accessor

---

## REQ-C6-distinct-per-env

The system shall enforce exactly one `BotConfig` row per environment value
(`"dev" | "test" | "prod"`) via a unique index on `env`, so that the dev, test,
and prod bots are never confused — a dev/test misconfiguration cannot route to
the production bot.

#### Scenario: only one row per env is allowed

- GIVEN no `BotConfig` row exists for `:prod`
- WHEN `BotConfig.upsert(env: :prod, …)` is called twice
- THEN exactly one row is created (the second call updates the existing row)
- AND the unique index prevents a second row

#### Scenario: dev and prod tokens are independent

- GIVEN a `:dev` row with `bot_username = "alethea_dev_bot"` and a `:prod` row
  with `bot_username = "alethea_prod_bot"`
- WHEN `BotToken.bot_username/0` is called in `Mix.env() == :dev`
- THEN the dev username is returned
- AND in `Mix.env() == :prod` the prod username is returned
- AND a misrouted call from a dev test to the prod accessor does not produce
  the prod token (the lookup is keyed on env)

---

## REQ-C6-bot-token-gen-server-accessor

The system shall expose a `Alethea.Telegram.BotToken` GenServer that loads the
`BotConfig.for_env(Mix.env())` row at boot, holds the plaintext tokens in
process state, and serves `bot_token/0`, `secret_token/0`, and
`bot_username/0` via synchronous `GenServer.call/2`.

#### Scenario: accessor returns the configured values

- GIVEN a `BotConfig` row exists for the current `Mix.env()` with token `"T"`,
  secret `"S"`, and username `"U"`
- WHEN the GenServer is asked for `bot_token()`, `secret_token()`, and
  `bot_username()`
- THEN each call returns the corresponding plaintext
- AND the values are served from process state (no DB read on every call)

#### Scenario: reload picks up a new row

- GIVEN the GenServer was started with token `"old-token"`
- WHEN the operator updates the `BotConfig` row and sends `:reload` to the
  GenServer (e.g. via a future SIGHUP or admin action)
- THEN the next `bot_token()` call returns `"new-token"`
- AND no app restart is required

#### Scenario: missing row raises on boot, not on first call

- GIVEN no `BotConfig` row exists for `Mix.env()`
- WHEN the application starts
- THEN the GenServer fails to start with a clear, logged error message
- AND the operator is forced to bootstrap a row before the system accepts
  any Telegram traffic

---

## REQ-C6-no-plaintext-in-env

The system shall not read the bot token or the webhook secret token from
plaintext environment variables in production runtime configuration — they
shall be reachable only via the `BotConfig` row, encrypted at rest.

#### Scenario: no TELEGRAM_BOT_TOKEN env var is read in prod

- GIVEN the application is started in `Mix.env() == :prod`
- WHEN the runtime configuration runs
- THEN `System.get_env("TELEGRAM_BOT_TOKEN")` is not called by the application
- AND the value, if accidentally set, is ignored — the accessor reads only
  from the `BotConfig` row

#### Scenario: test env may set a test-only pepper and uses the same BotConfig path

- GIVEN `Mix.env() == :test`
- WHEN the test process asks for the bot token
- THEN it is served from a `BotConfig` row with `env: "test"` (not from env)
- AND the test config may additionally set a test-only pepper via
  `Application.put_env(:alethea, :telegram_chat_id_pepper, "test-pepper")` —
  this is a test-only exception documented in the test suite

#### Scenario: secret-token header check uses the sealed value, not an env var

- GIVEN the `BotConfig` row for the current env has `secret_token = "X"`
- WHEN a webhook request arrives
- THEN the plug compares the inbound header against `"X"` (decrypted at
  accessor time) — not against `System.get_env("TELEGRAM_SECRET_TOKEN")`
