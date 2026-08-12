# Demo Tech Setup — Alethea + Real Telegram Bot

Static reference for running the demo against a real Telegram bot.
For the interactive equivalent that captures and validates every value, run:

```bash
bash scripts/setup_telegram_demo.sh
```

---

## Legend

| Label | Meaning |
|---|---|
| **Once per machine** | Only needed the first time you set up this dev machine. |
| **Each demo** | Run every time you give the demo (or after restarting the machine). |

---

## Step 1 — Install `cloudflared` _(once per machine)_

Check if it is already installed:

```bash
cloudflared --version
```

If missing, follow the official guide:
<https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/>

macOS shortcut:

```bash
brew install cloudflared
```

---

## Step 2 — Start the dev server _(each demo)_

Open a dedicated terminal and keep it running for the entire demo session:

```bash
mix phx.server
```

Wait until you see `[info] Running AletheaWeb.Endpoint with Bandit` before continuing.

---

## Step 3 — Launch the Cloudflare quick tunnel _(each demo)_

Open a second terminal:

```bash
cloudflared tunnel --url http://localhost:4000
```

Copy the generated public URL — it looks like `https://something-random.trycloudflare.com`.
You will need it in Steps 5 and 6.

> **Keep this terminal running.** If it dies, the tunnel URL changes and you must
> re-register the webhook (Step 6) and restart the demo flow.

---

## Step 4 — Provision a Telegram bot via @BotFather _(once per machine, or when rotating the bot)_

1. Open Telegram and search for **@BotFather** (blue verified badge).
2. Send `/newbot` to create a new bot, or `/mybots` to reuse an existing one.
3. Follow BotFather's prompts. At the end you receive:
   - An **HTTP API token** in the format `123456789:ABCdef...`
   - A **bot username** ending in `Bot` (e.g. `alethea_demo_bot`)

Keep both values on hand for Step 5.

---

## Step 5 — Register bot credentials with Alethea _(each demo, if BotConfig is empty)_

This writes or replaces the encrypted `BotConfig` row for `env=dev`.
You only need to redo this if the row is missing or you rotated the bot token.

```bash
TELEGRAM_BOT_TOKEN="<paste token from BotFather>" \
TELEGRAM_WEBHOOK_SECRET="<generate with: openssl rand -hex 32>" \
TELEGRAM_BOT_USERNAME="<paste username without @>" \
mix alethea.telegram.bootstrap --env dev
```

A successful run prints `TELEGRAM_BOT_CONFIGURED_ENV=dev`.

> Save `TELEGRAM_WEBHOOK_SECRET` — you need the exact same value in Step 6.

---

## Step 6 — Register the Telegram webhook _(each demo, after the tunnel URL changes)_

Send your tunnel URL to Telegram so it knows where to deliver messages.
Pass credentials through stdin to keep them out of shell history:

```bash
PUBLIC_BASE_URL="https://something-random.trycloudflare.com"   # from Step 3
TELEGRAM_BOT_TOKEN="<your bot token>"
TELEGRAM_WEBHOOK_SECRET="<same secret used in Step 5>"

curl --config - <<EOF
silent
show-error
request = "POST"
url = "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/setWebhook"
form = "url=${PUBLIC_BASE_URL}/webhooks/telegram"
form = "secret_token=${TELEGRAM_WEBHOOK_SECRET}"
EOF
```

A successful response contains `"ok": true`.

---

## Step 7 — Verify the dashboard renders the real deep link

1. Open `http://localhost:4000/dashboard` (or the public tunnel URL).
2. Select the demo patient in the picker.
3. Click **Invitar** — the invite modal should appear.
4. Confirm the modal shows a real `https://t.me/<bot_username>?start=<token>` deep link
   (not a plain 6-digit code, which only appears when no BotConfig is present).
5. Open the link on a phone or desktop Telegram client; the bot should respond to `/start`.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| Modal shows only a 6-digit code | BotConfig is missing or not for `env=dev`. Rerun Step 5. |
| `/start` in Telegram gets no reply | Webhook is stale or wrong. Rerun Step 6 with the current tunnel URL. |
| `mix alethea.telegram.bootstrap` fails | Check that `mix phx.server` is running and the DB is migrated. |
| Tunnel URL changed mid-demo | Rerun Step 6. The BotConfig row does not change. |
