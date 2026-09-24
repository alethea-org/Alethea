#!/bin/sh
# Dev container entrypoint: applies pending migrations, then seeds the
# "dev" foundation_bot_configs row (idempotent — see
# priv/repo/seed_dev_bot_config.exs) so Alethea.Telegram.BotToken can boot
# on a fresh DB without a manual step. Fails loud if either step fails.
set -e

mix ecto.migrate
mix run --no-start priv/repo/seed_dev_bot_config.exs
# Development only: team accounts (idempotent) so the same logins work on
# both the shared Neon database and the local fallback.
mix run --no-start priv/repo/seeds_team.exs

exec "$@"
