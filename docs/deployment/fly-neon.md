# Deploy Alethea to Fly.io with PostgreSQL on Neon

> **Scope: milestone 1 of issue 402, synthetic data only.**
> This deployment is a technical environment. Real patient data is **NOT
> authorized** until milestone 2 of issue 402 is complete (access controls,
> log filtering, retention, key custody, runbooks). Use synthetic patients and
> a test Telegram bot.

This guide is for the operator who runs the first deploy. Nothing in it has
been executed against Fly, Neon or Telegram yet: see
[Verification checklist](#verification-checklist-not-yet-executed).

## Quick path

1. Create the Neon production project and copy its **direct** connection string.
2. `fly apps create`, then stage every secret from the [inventory](#secrets-and-environment-inventory).
3. `fly deploy --ha=false` — the release command migrates and writes the Telegram bot row, then the server boots.
4. Register the Telegram webhook by hand, once.
5. Work through the verification checklist and record the evidence in issue 402.

## Topology

| Piece | Decision | Why |
| --- | --- | --- |
| Compute | One always-on Fly Machine in `gru` (São Paulo) | Oban queues and cron must run with no HTTP traffic, so `fly.toml` sets `auto_stop_machines = "off"` and `min_machines_running = 1`. |
| Database | Neon project in AWS `sa-east-1`, reached over the public internet with verified TLS | Same metro as `gru`. `ECTO_IPV6` and `DNS_CLUSTER_QUERY` stay unset: no Fly private network, no clustering. |
| Database host | Neon's **direct** host (no `-pooler` in the name) for everything | The pooler is PgBouncer in transaction mode: it breaks `LISTEN/NOTIFY` (Oban's Postgres notifier) and session advisory locks (migrations). |
| Migrations | Only from the deploy release command, `/app/bin/release` | Migration `20260618234145` disables the migration lock, so two runners at once are not protected from each other. |
| Scale to zero | Will not happen on either side | Oban polls the database every second, so the Neon compute never goes idle. Budget for an always-on Neon compute and an always-on Machine. |

Database connection settings, from `config/runtime.exs`:

| Variable | Default | Meaning |
| --- | --- | --- |
| `POOL_SIZE` | `5` | Connections in the Repo pool. Oban's notifier holds one more, and each deploy's release Machine opens a short-lived pool of its own. Check the total against the connection limit of the Neon compute size. |
| `DATABASE_CONNECT_TIMEOUT_MS` | `15000` | TCP connect and TLS/authentication handshake budget; covers a compute resume. |
| `DATABASE_QUEUE_TARGET_MS` | `2000` | How long callers may wait for a connection before the pool sheds load. |
| `DATABASE_QUEUE_INTERVAL_MS` | `10000` | Window over which the queue target is measured. |

Reconnection uses randomized exponential backoff between 500 ms and 10 s (not configurable through the environment).

## Neon setup checklist

- [ ] Create a **separate Neon project** for production. Not a branch of the development project: branches share the project's roles, history and access.
- [ ] Region: AWS `sa-east-1`.
- [ ] PostgreSQL 16, the version CI runs with pgvector (`pgvector/pgvector:pg16`). Another major version is untested here.
- [ ] Create the application role and database **through the Neon console**. Console-created roles may run `CREATE EXTENSION vector`, which the migrations do; a role created with plain SQL may not.
- [ ] Copy the connection string with connection pooling **turned off**, so the host has no `-pooler` suffix.
- [ ] Remove the whole query string (`?sslmode=...`) before storing it as `DATABASE_URL`. TLS is already verified by the application, and a `ssl=false` parameter in the URL would override that (see [Known limitations](#known-limitations-and-gaps)).
- [ ] Never reuse development credentials, and never point a development machine at this project.

## Secrets and environment inventory

Built from `config/runtime.exs`. "Secret" means `fly secrets`; "plain" means `[env]` in `fly.toml` or a secret, at the operator's choice. A missing required variable stops the release command, and therefore the deploy, with a message naming the variable.

### Required

| Name | Kind | Default | Purpose |
| --- | --- | --- | --- |
| `DATABASE_URL` | secret | none | Neon direct connection string, `ecto://USER:PASS@HOST/DATABASE`. |
| `SECRET_KEY_BASE` | secret | none | Signs and encrypts cookies and sessions. Generate with `mix phx.gen.secret`. |
| `CLOAK_AES_KEY` | secret | none | Base64 of 32 random bytes; encrypts clinical data at rest. Generate with `openssl rand -base64 32`. **Losing it loses the data.** |
| `TELEGRAM_CHAT_ID_PEPPER` | secret | none | HMAC key for Telegram chat id hashes, at least 32 bytes. Generate with `openssl rand -hex 32`. Changing it orphans every stored hash. |
| `PHX_HOST` | plain, in `fly.toml` | none | Public bare host name. Drives URLs, the origin check and the webhook URL. |
| `AI_PROVIDER` | plain | none | `local` or `cloud`. Provider of the guided conversation chain only. **Pending decision; not in `fly.toml`.** |
| `EMOTION_ANALYZER_ENABLED` | plain | none | Exactly `true` or `false`. **Pending decision; not in `fly.toml`.** |
| `EMBEDDINGS_ENABLED` | plain | none | Exactly `true` or `false`. **Pending decision; not in `fly.toml`.** |

### Required depending on another value

| Name | Kind | Required when | Purpose |
| --- | --- | --- | --- |
| `LOCAL_LLM_BASE_URL` | plain | `AI_PROVIDER=local` | Endpoint of the self-hosted model. Also the only endpoint of every non-guided chain. |
| `OPENAI_API_KEY` | secret | `AI_PROVIDER=cloud` | Hosted provider credential. |
| `LLM_MODEL` | plain | `AI_PROVIDER=cloud` | Model name; optional with `local` (compiled default `phi4-mini`). |
| `EMOTION_SIDECAR_URL` | plain | `EMOTION_ANALYZER_ENABLED=true` | Emotion sidecar endpoint. |
| `EMBEDDINGS_BASE_URL` | plain | `EMBEDDINGS_ENABLED=true` | Embeddings endpoint (Ollama API). |
| `TELEGRAM_BOT_TOKEN` | secret | first deploy and token rotation | BotFather token. Read by the release command and by nothing else. |
| `TELEGRAM_WEBHOOK_SECRET` | secret | with `TELEGRAM_BOT_TOKEN` | 1–256 characters of `A-Z a-z 0-9 _ -`. Generate with `openssl rand -hex 32`. |
| `TELEGRAM_BOT_USERNAME` | plain | with `TELEGRAM_BOT_TOKEN` | Bot user name, 5–32 letters, digits or underscores. |

The three `TELEGRAM_*` values are stored encrypted in the database by the release command. The running server reads the stored row, not these variables. Whether they stay as permanent secrets or are removed after the first deploy is an [open decision](#open-decisions); both work.

### Optional

| Name | Default | Purpose |
| --- | --- | --- |
| `PORT` | `4000` | HTTP port; set in `fly.toml` and must equal `internal_port`. |
| `PHX_EXTRA_ORIGINS` | empty | Comma-separated extra allowed origins, for example a custom domain. |
| `POOL_SIZE`, `DATABASE_CONNECT_TIMEOUT_MS`, `DATABASE_QUEUE_TARGET_MS`, `DATABASE_QUEUE_INTERVAL_MS` | see [Topology](#topology) | Database pool tuning. |
| `OPENAI_BASE_URL` | `https://api.openai.com/v1` | Hosted provider endpoint. |
| `EMBEDDINGS_MODEL` | adapter default (`bge-m3`) | Embeddings model name. |
| `EMOTION_SIDECAR_CONNECT_TIMEOUT_MS` / `_RECEIVE_TIMEOUT_MS` / `_MAX_BATCH_SIZE` / `_MAX_TEXT_BYTES` | `2000` / `30000` / `32` / `4096` | Emotion sidecar limits. |
| `WHISPER_ENABLED` | unset (disabled) | Must be unset or `false`; `true` fails the boot because no production adapter exists. |
| `DB_MONITORING_ENABLED` | `true` | Database telemetry warnings. |
| `DB_SLOW_QUERY_THRESHOLD_MS` / `DB_POOL_QUEUE_WARN_MS` / `DB_POOL_QUEUE_LENGTH_WARN` / `DB_QUERY_LOG_MAX_CHARS` | `1000` / `100` / `1` / `4000` | Thresholds for those warnings. |

### Never set on Fly

| Name | Why |
| --- | --- |
| `DATABASE_SSL` | `false` turns database TLS off. It exists only for local and CI smoke tests. |
| `ECTO_IPV6`, `DNS_CLUSTER_QUERY` | Neon is reached over the public internet and the app is a single node. |

## AI capabilities

| Capability | Configured by | When off or unconfigured |
| --- | --- | --- |
| Guided conversation chain (Telegram replies) | `AI_PROVIDER`, plus `LOCAL_LLM_BASE_URL` or `OPENAI_API_KEY` + `LLM_MODEL` | Cannot be off: the boot fails without a complete provider. |
| Every other chain: session summary, weekly summary, weekly report, pattern proposal, clinical consultation, clinical hypothesis, functional analysis draft | `LOCAL_LLM_BASE_URL` only. They are pinned to the local provider so clinical narrative is never rerouted to a hosted model by `AI_PROVIDER`. | "Not configured": summaries fail and retry; consultations and reports return errors. |
| Emotion analyzer slot | `EMOTION_ANALYZER_ENABLED` + `EMOTION_SIDECAR_URL` | Explicit `Disabled` adapter; session closure completes without trends. |
| Embeddings slot (RAG indexing) | `EMBEDDINGS_ENABLED` + `EMBEDDINGS_BASE_URL` (+ `EMBEDDINGS_MODEL`) | Explicit `Disabled` adapter; indexing jobs fail and retry per event (known gap). |
| Transcription slot (Whisper) | nothing | Always disabled. |

No Fake adapter and no `localhost` endpoint is reachable in production.

### Open decisions

These belong to the product owner. The deploy fails fast until the three required AI variables are set, so they cannot be skipped by accident.

- **Hosted provider for non-guided chains.** With `AI_PROVIDER=cloud` and no `LOCAL_LLM_BASE_URL`, only guided conversation works. Letting the other chains use a hosted provider is a privacy decision.
- **No "LLM disabled" mode.** `AI_PROVIDER` accepts only `local` or `cloud`.
- **Emotion analyzer posture.** Enabling it in production conflicts with its development-only status from issue 198.
- **Where a `local` model runs.** `LOCAL_LLM_BASE_URL` must be reachable from the Fly Machine; no hosting for it is defined yet.
- **Telegram secrets policy.** Keep the three `TELEGRAM_*` values permanently, or set them for one deploy and unset them afterwards.
- **Machine capacity.** `fly.toml` uses `shared-cpu-1x` with 1 GB as a starting point.

## First deploy

Run from the repository root. `fly.toml` names the app `alethea-prod`; change that line (and `PHX_HOST`) first if the name is taken.

1. **Create the app.**

   ```sh
   fly apps create alethea-prod --org <your-org>
   ```

2. **Stage the secrets.** `--stage` stores them without deploying. `fly secrets import` reads `NAME=VALUE` lines from stdin, which keeps values out of shell history:

   ```sh
   fly secrets import --stage -a alethea-prod < production.secrets
   ```

   The file needs every required secret, the three AI variables with the values that were decided, and the three `TELEGRAM_*` values. Keep it out of the repository and delete it afterwards. `fly secrets set --stage -a alethea-prod NAME=VALUE ...` is the inline equivalent.

3. **Deploy one Machine.** `--ha=false` matters on the first deploy: the default creates a spare Machine, and this app runs as exactly one.

   ```sh
   fly deploy --ha=false
   ```

   The release command `/app/bin/release` runs first, in a temporary Machine: it migrates the empty database and writes the Telegram bot row. The server cannot boot without that row, which is why the `TELEGRAM_*` values must be staged before this step. Expect these lines in the deploy output:

   ```text
   TELEGRAM_BOT_CONFIG env=prod status=created username=<bot>
   ```

4. **Check it is up.**

   ```sh
   fly status -a alethea-prod
   fly checks list -a alethea-prod
   curl -i https://alethea-prod.fly.dev/health/ready
   ```

5. **Register the Telegram webhook.** This is the only step that calls Telegram, and it never runs on its own.

   ```sh
   fly ssh console -a alethea-prod -C "/app/bin/telegram_bootstrap register-webhook"
   ```

   Expect `TELEGRAM_WEBHOOK env=prod status=... url=https://alethea-prod.fly.dev/webhooks/telegram ...`.
   **Verify before running:** that the SSH session carries the app's secrets (the command needs `DATABASE_URL` and `CLOAK_AES_KEY`), and that running it as `root` (the SSH default; the server runs as `nobody`) is acceptable.

## Operations

### Rotate a secret

```sh
fly secrets set --stage -a alethea-prod NAME=NEW_VALUE
fly deploy
```

Staging and then deploying guarantees the release command runs with the new value.

| Secret | Effect of rotating |
| --- | --- |
| `DATABASE_URL` | Reset the role password in Neon first, then rotate. |
| `SECRET_KEY_BASE` | Signs every user out. |
| `TELEGRAM_BOT_TOKEN`, `TELEGRAM_WEBHOOK_SECRET` | Stage all three `TELEGRAM_*` values and deploy: the release command reports `status=updated` and the restarted server loads the new row. If the secret changed, run `register-webhook` again. |
| `CLOAK_AES_KEY` | **Do not rotate.** The vault has one cipher and no re-encryption procedure; a new key makes existing data unreadable. Key custody is milestone 2. |
| `TELEGRAM_CHAT_ID_PEPPER` | **Do not rotate.** Every stored chat id hash stops matching. |

### Roll back

```sh
fly releases -a alethea-prod --image
fly deploy --image <image reference of the good release>
```

Redeploying an older image rolls back code only. Its release command finds the database already ahead and changes nothing.

The schema is rolled back by hand, on purpose: `Alethea.Release.rollback/2` runs `down` migrations, which can drop columns and data, and the migration lock is disabled. Decide per migration, then run (**verify before running**: quoting through `-C`):

```sh
fly ssh console -a alethea-prod -C '/app/bin/alethea eval "Alethea.Release.rollback(Alethea.Repo, <version>)"'
```

### Run a one-off migration

Every deploy migrates, so the normal path is `fly deploy`. Without a deploy:

```sh
fly ssh console -a alethea-prod -C "/app/bin/migrate"
```

Never run it while a deploy is in progress: that would be two migration runners at once.

## Verification checklist (not yet executed)

**None of these has been run.** Each needs the evidence in issue 402.

- [ ] **Image builds.** `docker build -t alethea:prod .` exits 0 (also the `Release image` CI job).
- [ ] **Deploy succeeds.** `fly deploy --ha=false` ends with the Machine healthy; `fly status -a alethea-prod` shows one started Machine in `gru`.
- [ ] **Migrations applied.** The deploy output shows the migrations, and `select count(*) from schema_migrations;` in the Neon SQL editor matches the number of files in `priv/repo/migrations`.
- [ ] **Readiness.** `curl -i https://alethea-prod.fly.dev/health/ready` returns 200 with `"database":"ok"` and `"oban":"ok"`.
- [ ] **LiveView and static assets.** The login page loads over HTTPS, the browser shows a connected LiveView socket (`wss://.../live/websocket`, status 101), and `curl -I https://alethea-prod.fly.dev/assets/js/app.js` returns 200.
- [ ] **Telegram → Oban → reply, synthetic data.** After `register-webhook`, a message from a synthetic patient to the test bot gets a reply, and `fly logs -a alethea-prod` shows the webhook request and the inbound and outbound jobs.
- [ ] **Oban and cron with no HTTP traffic.** With no requests for 15 minutes, `select state, inserted_at from oban_jobs where worker = 'AletheaJobs.TelegramDeliverySweepWorker' order by id desc limit 3;` shows completed rows five minutes apart.
- [ ] **Reconnection after a Neon suspend and resume.** Suspend the compute from the Neon console (**verify the current control**; it will not suspend on its own), watch `/health/ready` return 503 and then 200 again without restarting the Machine.
- [ ] **Recovery after stopping the Machine.** `fly machine list -a alethea-prod`, `fly machine stop <id> -a alethea-prod`, `fly machine start <id> -a alethea-prod`; readiness returns to 200 and the next cron run appears as above.

## Known limitations and gaps

- **`ssl=false` in `DATABASE_URL` disables database TLS.** Ecto merges URL parameters over the application's verified TLS setting. Store the URL without a query string.
- **Single Machine.** A deploy or a host failure is a short outage; there is no high availability.
- **Oban dashboard, login abuse protection, MFA, log filtering, retention and key custody** are milestone 2.
- **Trends are not resumable** after a crash between session close and save.
- **Goodbye idempotency relies on `oban_jobs` rows persisting**; no Pruner is configured, so the table grows without bound.
- **With the emotion analyzer off**, a no-op emotion job is still enqueued per inbound message.
- **With embeddings off**, RAG indexing retries and fails per event.
- **`BotConfig.upsert` does not silence its own query log**; only the bootstrap caller guards the plaintext token. Production logs at `info`, where queries are not printed.
- **`.env.example` and the README** do not list the variables above.
- **The image is built on Elixir 1.19 / OTP 28**; local development uses a newer toolchain.
