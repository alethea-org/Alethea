#!/bin/sh
set -eu

# Fail closed: without a token, Caddy's header matcher would accept "Bearer ".
case "${OLLAMA_AUTH_TOKEN:-}" in
  "" | *[!0-9A-Za-z_-]*)
    echo "OLLAMA_AUTH_TOKEN must be set to a non-empty value of [0-9A-Za-z_-]" >&2
    exit 1
    ;;
esac

OLLAMA_HOST=127.0.0.1:11434 ollama serve &
exec caddy run --config /etc/caddy/Caddyfile --adapter caddyfile
