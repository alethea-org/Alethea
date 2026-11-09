# Issue #484 — One-command local Telegram testing with a Docker tunnel

Branch `feat/484-dev-telegram-tunnel` (worktree `C:/Users/teofu/Code/Alethea-484`, from origin/main d13f9d4).
Development tooling only: production config, `Dockerfile`, `docker-compose.prod.yml` and release scripts stay untouched.

## Specs

- S1 (user): "todo esto que tuve que hacer en 4 Git Bash diferentes... no hay forma de hacerlo en containers de docker y ahorrarme un montón de laburo cada vez que quiero testear algo en desarrollo (y a mis compañeros de trabajo!)"
- S2 (user): "Podríamos modificar alguno de los archivos de desarrollo como para indicar que esa es la forma estándar de desarrollar así nadie se vuelve a confundir?"
- S3 (user decision): "Local por defecto con Telegram" — the Telegram flow uses the local Docker database by default so nobody overwrites the shared Neon `foundation_bot_configs` env `dev` row.
- S4 (issue acceptance): "`docker compose --profile telegram up` levanta app, db, sidecar y túnel sin pasos manuales extra." (mechanism may be a compose override file instead of a profile; see D1)
- S5 (issue acceptance): "`mix alethea.telegram.dev_tunnel` registra el webhook contra la URL actual del túnel y termina con éxito, o falla con un mensaje claro si no hay túnel o no hay bot configurado."
- S6 (issue acceptance): "`docker compose up` sin el profile se comporta igual que hoy."
- S7 (issue acceptance): "El README documenta el flujo estándar en un solo lugar."
- S8 (issue acceptance): "Nada de esto afecta la configuración ni el despliegue de producción."
- S9 (issue): the task "Nunca imprime el token ni el secret."

## Design decisions

- D1: Telegram flow is an opt-in compose override file `docker-compose.telegram.yml`, used as `docker compose -f docker-compose.yml -f docker-compose.telegram.yml up`. It (a) forces `DATABASE_URL=postgresql://postgres:postgres@db:5432/alethea_dev` for `app` (S3), (b) passes `TELEGRAM_BOT_TOKEN`, `TELEGRAM_BOT_USERNAME`, `TELEGRAM_WEBHOOK_SECRET` from `.env` to `app`, (c) adds a `tunnel` service (`cloudflare/cloudflared`, quick tunnel, no account: `tunnel --no-autoupdate --metrics 0.0.0.0:2000 --url http://app:4000`), and (d) adds a one-shot `telegram-webhook` service that waits for app and tunnel, then runs `mix alethea.telegram.dev_tunnel`. Plain `docker compose up` is unchanged (S6).
- D2: `entrypoint.sh` — when `TELEGRAM_BOT_TOKEN` is non-empty, run `mix alethea.telegram.bootstrap --env dev` (generating a random `TELEGRAM_WEBHOOK_SECRET` of `[A-Za-z0-9]` if unset) instead of the fake-bot seed; otherwise keep today's exact steps (S6).
- D3: `mix alethea.telegram.dev_tunnel` reads the quick-tunnel hostname from cloudflared's metrics endpoint `GET <metrics>/quicktunnel` (JSON `{"hostname": "..."}`), default metrics URL from `TUNNEL_METRICS_URL` or `http://127.0.0.1:2000`, optional `--wait <seconds>` retry until the hostname and app are reachable; then calls Telegram `setWebhook` with `https://<hostname>/webhooks/telegram` and the stored `BotConfig` secret, verifies with `getWebhookInfo`, and prints only non-secret lines. Dev-only: refuses any env other than dev. Reuse existing Telegram client/webhook code rather than a second HTTP path.

## Tasks

- [x] T1 S5,S9 — `mix alethea.telegram.dev_tunnel` + tests (hostname parsing, no tunnel, no bot config, non-dev refusal, no secrets in output). Route: worker mw8htjb7-1-ga5y. Commit: e0b4a27
- [x] T2 S1,S3,S4,S6,S8 — `docker-compose.telegram.yml` + `entrypoint.sh` branch; `docker compose ... config` structural check for both invocations. Route: worker mw8htjb7-1-ga5y. Commit: 25a3a66
- [x] T3 S2,S7 — README "Probar con Telegram real" as the single standard flow; `docs/main-demo-operator-guide.md` points to it. Route: worker mw8htjb7-1-ga5y. Commit: 4ae8a17 (.env.example not edited: path blocked as sensitive by the edit guard)
- [ ] T4 — verification (Risk item 5 environment → independent verify). Route: gentle-ai-verify.

## Log

- L1 (user, 2026-11-08): "podemos resolver esto que mencionas del túnel ahora? Podríamos modificar alguno de los archivos de desarrollo como para indicar que esa es la forma estándar de desarrollar así nadie se vuelve a confundir?"
- L2 (user decisions, 2026-11-08): "Issue y rama nuevos desde main" → issue #484; "Local por defecto con Telegram".
- L3 (evidence, 2026-11-08): worker RED 16/16 UndefinedFunctionError; GREEN 16/0; test/mix/tasks + test/alethea/telegram 247/0; compile --force --warnings-as-errors exit 0; `docker compose config -q` and override `config -q` OK; `sh -n entrypoint.sh` OK, LF. Deviations: override also sets TELEGRAM_CLIENT_ADAPTER=req and TELEGRAM_CHAT_ID_PEPPER (dev fallback); telegram-webhook uses entrypoint ["mix"]; tunnel waits for app healthy; extra --metrics-url/--app-url/APP_HEALTH_URL and --wait retries on setWebhook 400/transport errors; reuses WebhookRegistration.register/3. Runtime (containers) untested. Incident: rendering the merged compose config printed NEON_DATABASE_URL from the local .env into the worker transcript (not written to files).
