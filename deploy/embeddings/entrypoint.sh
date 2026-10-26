#!/bin/bash
set -euo pipefail

# Fail closed: without a token, Caddy's header matcher would accept "Bearer ".
case "${OLLAMA_AUTH_TOKEN:-}" in
  "" | *[!0-9A-Za-z_-]*)
    echo "OLLAMA_AUTH_TOKEN must be set to a non-empty value of [0-9A-Za-z_-]" >&2
    exit 1
    ;;
esac

export OLLAMA_HOST=127.0.0.1:11434
READY_ATTEMPTS="${OLLAMA_READY_ATTEMPTS:-120}"

ollama serve &
ollama_pid=$!
caddy_pid=""
stopping=0
# A requested stop (auto-stop, deploy) exits cleanly; only a crash exits 1.
trap 'stopping=1; kill -TERM "$ollama_pid" $caddy_pid 2>/dev/null || true' TERM INT

# Publish only once Ollama answers, so the request that woke the machine is
# proxied to a listening upstream instead of getting a 502.
attempt=0
until ollama list >/dev/null 2>&1; do
  if ! kill -0 "$ollama_pid" 2>/dev/null; then
    echo "ollama exited during startup" >&2
    exit 1
  fi
  attempt=$((attempt + 1))
  if [ "$attempt" -ge "$READY_ATTEMPTS" ]; then
    echo "ollama did not become ready" >&2
    kill -TERM "$ollama_pid" 2>/dev/null || true
    exit 1
  fi
  sleep 0.5
done

caddy run --config /etc/caddy/Caddyfile --adapter caddyfile &
caddy_pid=$!

# Supervise both: if either exits, stop the other and exit non-zero so Fly
# restarts the machine instead of serving 502s forever. Polling keeps this
# portable (no `wait -n` with PIDs) and lets the TERM trap run promptly.
while kill -0 "$ollama_pid" 2>/dev/null && kill -0 "$caddy_pid" 2>/dev/null; do
  sleep 1
done
kill -TERM "$ollama_pid" "$caddy_pid" 2>/dev/null || true
wait 2>/dev/null || true
if [ "$stopping" -eq 1 ]; then
  exit 0
fi
echo "ollama or caddy exited; stopping the machine" >&2
exit 1
