# Run the Alethea Demo from `main`

Use this runbook for a synthetic, local `main` demo with a real Telegram bot. Keep secrets, invite URLs, patient data, and message contents out of terminals, recordings, shell history, and chat.

## Boundaries

- Use synthetic data only. Do not use a real identity, message, token, password, invite URL, or identifier in this guide.
- The operator manually starts Ollama and OrbStack. Do not stop either from this runbook.
- This runbook starts and stops Phoenix and the emotion sidecar. Stop an `ngrok` tunnel manually when its public endpoint is no longer needed.
- Register the Telegram webhook only after the public readiness check passes.

## Prerequisites

Before starting, the operator must manually ensure:

- Ollama is running, and the `phi4-mini` model is available. If it is not, run `ollama pull phi4-mini`.
- OrbStack is running so Docker Compose can start the emotion sidecar and local dependencies are available.
- `ngrok`, `curl`, `openssl`, Docker Compose, Elixir, and the repository dependencies are installed.

Check the local LLM without displaying credentials:

```bash
curl -fsS http://localhost:11434/api/tags >/dev/null
ollama list
```

## Sync `main`

From the repository root, start from a clean worktree. These commands fail safely instead of overwriting local work.

```bash
git switch main
git fetch origin main
git pull --ff-only origin main
```

## Configure the Local Runtime

Create or update the local `.env` privately. Do not print it, commit it, or paste its values anywhere. The required demo settings are:

```dotenv
# Supply private values; do not use these placeholders literally.
CLOAK_AES_KEY=<private-base64-key>
TELEGRAM_CHAT_ID_PEPPER=<private-pepper-at-least-32-bytes>
AI_PROVIDER=local
LLM_MODEL=phi4-mini
LOCAL_LLM_BASE_URL=http://localhost:11434
EMOTION_SIDECAR_URL=http://127.0.0.1:8080
TELEGRAM_CLIENT_ADAPTER=req
```

`CLOAK_AES_KEY` and `TELEGRAM_CHAT_ID_PEPPER` must remain stable for existing local encrypted data and Telegram bindings. Do not rotate either during a demo. For a first-machine setup, prefer the interactive setup command below rather than inventing values manually:

```bash
bash scripts/setup_telegram_demo.sh
```

## Bootstrap Synthetic Data

Store bot credentials only in the encrypted `BotConfig` row. Read them privately into the current shell; the bootstrap task does not print them.

```bash
read -rs TELEGRAM_BOT_TOKEN
printf '\n'
export TELEGRAM_BOT_TOKEN
read -rs TELEGRAM_WEBHOOK_SECRET
printf '\n'
export TELEGRAM_WEBHOOK_SECRET
read -r TELEGRAM_BOT_USERNAME
export TELEGRAM_BOT_USERNAME
mix alethea.telegram.bootstrap --env dev
```

Confirm only `TELEGRAM_BOT_CONFIGURED_ENV=dev`. Then set a synthetic-only professional password privately and create or reuse the synthetic identity:

```bash
read -rs ALETHEA_DEMO_PROFESSIONAL_PASSWORD
printf '\n'
export ALETHEA_DEMO_PROFESSIONAL_PASSWORD
mix alethea.demo.bootstrap --synthetic --env dev
unset ALETHEA_DEMO_PROFESSIONAL_PASSWORD
```

The bootstrap emits a short-lived onboarding URL. Treat it as a credential: use it only in Telegram, do not print, log, or retain it. It expires after 10 minutes.

## Start and Verify Services

Use separate terminals from the repository root.

Terminal 1 starts the sidecar bound to loopback:

```bash
docker compose run --rm --publish 127.0.0.1:8080:8080 emotion-sidecar
```

Wait for a successful readiness response. The first model download can take several minutes.

```bash
curl -fsS http://127.0.0.1:8080/health/ready
```

Terminal 2 starts Phoenix only after the BotConfig bootstrap is complete:

```bash
mix phx.server
```

Verify liveness and dependency readiness from a third terminal:

```bash
curl -fsS http://127.0.0.1:4000/health
curl -fsS http://127.0.0.1:4000/health/ready
```

Both requests must return HTTP 200 before continuing. `/health/ready` verifies the database and Oban table access; it is the stronger startup gate.

## Login and Dashboard

Open `http://127.0.0.1:4000/login` and authenticate with the synthetic professional credential used during bootstrap. Then open `/dashboard` and verify that the synthetic patient appears and the invitation flow produces a current deep link. Do not copy the link into notes, terminal output, or the demo recording.

## Expose and Validate the Public Endpoint

Terminal 3 starts an ngrok HTTP tunnel to Phoenix:

```bash
ngrok http 4000
```

Copy the HTTPS base URL privately from ngrok, without a trailing slash, and validate the public application before changing Telegram:

```bash
read -r PUBLIC_BASE_URL
export PUBLIC_BASE_URL
curl -fsS "$PUBLIC_BASE_URL/health"
curl -fsS "$PUBLIC_BASE_URL/health/ready"
```

Both public checks must return HTTP 200. If either fails, stop here: do not register or update the Telegram webhook.

## Register and Verify the Webhook

Only after public readiness succeeds, register the webhook. This passes credentials through curl stdin rather than command arguments or shell history:

```bash
curl --config - <<EOF
silent
show-error
request = "POST"
url = "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/setWebhook"
form = "url=${PUBLIC_BASE_URL}/webhooks/telegram"
form = "secret_token=${TELEGRAM_WEBHOOK_SECRET}"
EOF
```

Continue only if Telegram returns `"ok": true`. Clear temporary credential variables when registration is complete:

```bash
unset TELEGRAM_BOT_TOKEN TELEGRAM_WEBHOOK_SECRET TELEGRAM_BOT_USERNAME PUBLIC_BASE_URL
```

## Exercise One Synthetic Message

Use the fresh onboarding link in Telegram, complete onboarding, and send exactly one safe, non-identifying synthetic journal message. Wait for the bot reply. Do not send a second message as a retry.

For deterministic analytics and report generation, provide the synthetic patient UUID privately and run:

```bash
read -rs ALETHEA_DEMO_PATIENT_ID
printf '\n'
mix alethea.demo.process --patient-id "$ALETHEA_DEMO_PATIENT_ID"
unset ALETHEA_DEMO_PATIENT_ID
```

Expected outcomes:

- Telegram accepts onboarding and sends one AI reply to the synthetic message.
- The dashboard shows the synthetic patient and refreshed message-derived metrics.
- The processing task prints `ALETHEA_DEMO_PROCESSING_COMPLETE` with an emotion count and `weekly_report=generated`.
- No command prints journal text, reply text, tokens, passwords, invite URLs, or personal identifiers.

## Recovery

| Symptom | Safe recovery |
|---|---|
| No bot reply; local LLM unavailable | Stop sending messages. Confirm Ollama is running and `phi4-mini` is listed with the prerequisite commands. Confirm the local `.env` values above, then restart Phoenix so it loads the corrected runtime configuration. |
| BotConfig credentials changed after Phoenix started | Stop Phoenix, rerun `mix alethea.telegram.bootstrap --env dev` with privately supplied values, then restart Phoenix. `BotToken` loads credentials at application startup. |
| Sidecar liveness works but readiness fails | Keep the sidecar terminal running and wait for model startup; retry `curl -fsS http://127.0.0.1:8080/health/ready`. Do not proceed on a 503 response. |
| Public health or readiness fails | Keep the webhook unchanged. Repair Phoenix, the sidecar, or ngrok, then repeat both public checks before registration. |
| Telegram does not deliver after registration | Confirm public readiness first, then register the current ngrok URL again and require `"ok": true`. A changed tunnel URL requires a new registration. |
| A fresh start is required | Stop Phoenix first, then run `mix alethea.demo.reset --confirm`. It is development-only, transactional, removes local demo identities, clinical data, delivery records, and Oban jobs, and preserves encrypted `BotConfig`, migrations, and Oban peer state. Bootstrap a fresh synthetic identity afterward. |

## Shutdown

Stop the processes owned by this runbook with `Ctrl-C` in their terminals:

1. Phoenix (`mix phx.server`).
2. Emotion sidecar (`docker compose run ... emotion-sidecar`).

Stop the ngrok terminal manually when the public endpoint is no longer required. The operator owns Ollama and OrbStack: leave them running or stop them manually outside this runbook.

## Related Artifacts

- `scripts/setup_telegram_demo.sh`
- `services/emotion_sidecar/README.md`
- `lib/mix/tasks/alethea.demo.bootstrap.ex`
- `lib/mix/tasks/alethea.demo.process.ex`
- `lib/mix/tasks/alethea.demo.reset.ex`
- `lib/mix/tasks/alethea.telegram.bootstrap.ex`
