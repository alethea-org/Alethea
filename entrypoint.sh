#!/bin/sh
# Dev container entrypoint: applies pending migrations, then seeds the
# "dev" foundation_bot_configs row (idempotent — see
# priv/repo/seed_dev_bot_config.exs) so Alethea.Telegram.BotToken can boot
# on a fresh DB without a manual step. Fails loud if either step fails.
set -e

mix ecto.migrate
if [ -n "${TELEGRAM_BOT_TOKEN:-}" ]; then
  # Real Telegram bot (docker-compose.telegram.yml): store the sealed dev
  # BotConfig from TELEGRAM_* instead of the fake-bot seed. The webhook secret
  # is generated when unset; the dev_tunnel task reads it back from the row.
  if [ -z "${TELEGRAM_WEBHOOK_SECRET:-}" ]; then
    TELEGRAM_WEBHOOK_SECRET=$(head -c 512 /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 48)
    export TELEGRAM_WEBHOOK_SECRET
  fi
  mix alethea.telegram.bootstrap --env dev
else
  mix run --no-start priv/repo/seed_dev_bot_config.exs
fi
# Development only: team accounts (idempotent) so the same logins work on
# both the shared Neon database and the local fallback.
mix run --no-start priv/repo/seeds_team.exs

exec "$@"
