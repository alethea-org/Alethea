# Issue 402 — Production readiness on Fly.io with PostgreSQL on Neon

- Issue: https://github.com/alethea-org/Alethea/issues/402
- Branch: `chore/402-fly-neon-production` (from `main` at `8e3cbac`)
- Engram mirror: `odd/issue-402-fly-neon-production/tasks`
- Status: in progress — slice 1 (T1–T3) committed; T4 next

## Objective

Make the repository deployable as a Mix release on Fly.io against an isolated
Neon production database, covering the repository-side work of milestone 1
("despliegue técnico") of issue 402.

## Problem

The repository cannot produce a working production release today:

- `Dockerfile:32` calls a `mix assets.deploy` alias that does not exist, builds
  dependencies outside `MIX_ENV=prod`, and never sets `PHX_SERVER`.
- `Mix.env()` is called at runtime (`lib/alethea/telegram/bot_token.ex:225`,
  `lib/alethea_web/live/dashboard_live.ex:452`,
  `lib/alethea/operator/demo_processor.ex:15`); the first one blocks boot.
- No release-compatible migration or Telegram bootstrap exists; the only writer
  of the production `BotConfig` row is a Mix task, and nothing calls
  `setWebhook`.
- `config/runtime.exs:125` leaves database TLS commented out; `PHX_HOST`
  defaults to `example.com`; AI endpoints default to `localhost`.
- The `:emotion_analyzer` and `:ai_embeddings` slots are unset in production,
  so `SessionTimeoutWorker` closes the session, raises, and the retry reports
  success with trends, summary and goodbye permanently skipped.
- `/health/ready` returns 200 with the database down
  (`lib/alethea_web/controllers/health_controller.ex:40-59`).
- CI builds neither the image nor the release.

## Why

Issue 402 gates the first technical deployment with synthetic data. Milestone 2
(real patients) depends on it and is NOT authorized by completing this work.

## Scope

In scope: repository changes for milestone 1 items, with tests and docs.

Out of scope:

- Milestone 2 controls (Oban dashboard restriction, login abuse protection,
  MFA, log filtering, retention, key custody, runbooks, README/CLAUDE.md).
- Remote operations: creating the Neon project, `fly launch`/`fly deploy`,
  setting secrets, registering the Telegram webhook against the real bot.
  These need explicit user authorization per destination and operation.
- New clinical features, automatic migration of development data, multi-region
  high availability.

## Constraints

- Patient-level encryption and the sanitizer-before-LLM rule stay untouched.
- No Fake adapter and no `localhost` endpoint may be reachable in production by
  default; an unconfigured AI capability is explicitly disabled, never faked.
- Oban remains mandatory for the message pipeline.
- Use `Req` for HTTP; generate migrations with `mix ecto.gen.migration` only.
- The user's uncommitted `CLAUDE.md` and `docs/agents/` are not part of this
  work and must not be staged.

## Verified external facts

- Postgrex `ssl: true` verifies peer and hostname from 0.21.0 (locked: 0.22.1);
  SNI is derived from `:hostname`. Ecto ignores `sslmode=` in `DATABASE_URL`.
- Neon's `-pooler` host is PgBouncer in transaction mode: no `LISTEN/NOTIFY`,
  no session advisory locks. Migrations and Oban's Postgres notifier need the
  direct host.
- Neon suspends an idle compute after 5 minutes and closes connections; Oban's
  one-second stager keeps the compute effectively always on.
- `CREATE EXTENSION IF NOT EXISTS vector` works on Neon for console-created
  roles.
- Fly `release_command` runs in a temporary Machine with secrets and aborts the
  deploy on a non-zero exit. Background work needs
  `auto_stop_machines = "off"` or `min_machines_running >= 1`.

## Tasks

Route per task is recorded with its trigger evidence.

- [x] **T1 — Release runtime foundations.** Replace runtime `Mix.env()` with a
  compile-time `config :alethea, :env`; add `Alethea.Release` with `migrate/0`
  and `rollback/2`; add `rel/overlays/bin/server` and `bin/migrate`; add
  `releases:` to `mix.exs`.
  Route: delegated (writer trigger: 6+ non-trivial files).
  Checks: `mix test` for touched suites, `mix precommit`.
- [x] **T2 — Docker build.** Debian-based multi-stage image pinned to the CI
  Elixir/OTP versions, whole build under `MIX_ENV=prod`, no asset step,
  `ca-certificates` in the runner, non-root user, `PHX_SERVER` via
  `bin/server`; stop ignoring `rel` in `.dockerignore`.
  Route: delegated with T1 (same writer, separate commit).
  Checks: `docker build`; boot the release against a local Postgres.
- [x] **T3 — Readiness.** `/health/ready` fails on database or Oban error
  tuples and when Oban is not running; liveness stays dependency-free and is
  excluded from the `force_ssl` redirect.
  Route: inline candidate (one file plus its test) — confirm at execution.
  Checks: RED/GREEN in `test/alethea_web/health_controller_test.exs`.
- [ ] **T4 — Production configuration.** Verified TLS for the Repo, required
  `PHX_HOST`, `check_origin`, pool and queue settings for Neon, no `localhost`
  AI defaults in production, explicit capability switches.
  Route: delegated (config plus config tests plus `LLMConfig`).
  Checks: `Config.Reader.read!(path, env: :prod)` tests, following
  `test/config/telegram_client_config_test.exs`.
- [ ] **T5 — AI capability degradation.** A disabled or failing AI capability
  no longer leaves session closure incomplete; `EmotionAnalysisWorker` does not
  raise per inbound message when the analyzer is disabled.
  Route: delegated (workers plus `Alethea.AI` plus tests).
  Checks: RED/GREEN in `test/alethea_jobs/session_timeout_worker_test.exs` and
  `emotion_analysis_worker_test.exs`; sentiment regression test.
- [ ] **T6 — Telegram production bootstrap.** Release-callable, idempotent
  `BotConfig` bootstrap and `setWebhook` registration with `secret_token`,
  verified through `getWebhookInfo`; `Client.Fake` not started in production.
  Route: delegated.
  Checks: Req.Test-backed tests; existing bootstrap task test stays green.
- [ ] **T7 — Fly configuration and deployment doc.** `fly.toml` (HTTPS, port,
  checks on `/health/ready`, always-on Machine, `release_command`), plus a
  deployment document covering the Neon connection scheme (direct host, pool,
  migrations, Oban `LISTEN/NOTIFY`), secrets inventory and the AI inventory.
  Route: delegated or inline, decided at execution.
  Blocked on: app name and primary region (pending decision in the issue).
- [ ] **T8 — CI.** Build the image and smoke-test the release (migrate, boot,
  `/health/ready`) in GitHub Actions; compile with `--warnings-as-errors`.
  Route: inline candidate (one workflow file).
  Checks: workflow syntax; result observable only after push.

### Not achievable from the repository alone

These issue items need the authorized remote environment and stay open here:

- Create the isolated Neon production environment with its own credentials.
- Verify reconnection across Neon suspend/resume.
- Prove Oban and cron keep running with no HTTP traffic and recover after a
  Machine interruption.
- Milestone evidence: deployed app, migrations, LiveView, and the
  Telegram → Oban → reply path with synthetic data.

## Acceptance criteria

- `docker build` succeeds and the release boots with `bin/server` against
  PostgreSQL with pgvector, with no `Mix` call at runtime.
- `bin/migrate` applies all migrations on an empty database without seeds.
- `/health/ready` returns 503 when the database or Oban is unavailable.
- Production config evaluated in tests has verified TLS, no `localhost`
  endpoint and no Fake adapter.
- A session closes completely when the emotion analyzer is disabled or fails.
- `mix precommit` passes.

## Delivery

- Forecast: about 1,000–1,300 authored changed lines, above the 400-line
  budget, so the work ships as a PR chain.
- Strategy: `ask-on-risk`; chain strategy `stacked-to-main` (user choice,
  2026-10-07).
- Slices: (1) T1, T2, T3 on `chore/402-fly-neon-production`; (2) T4, T5, T6;
  (3) T7, T8. Each later slice branches from the previous one.
- Running count: 647 changed lines in slice 1 (17 paths, native assessment).

## Progress and evidence

| Task | Commit | Checks observed | Review tier / outcome |
| --- | --- | --- | --- |
| T1 | `6b0c4ba` | Mix usage test RED (6 offenders) then GREEN; release builds; `bin/alethea eval` passes runtime config | slice 1 |
| T2 | `dcfc015` | Image tags confirmed on Docker Hub; `docker build` NOT RUN (daemon down) | slice 1 |
| T3 | `8f626c3` | Health tests RED 6/13 then GREEN 13/13; parent re-run 14 passed | slice 1 |
| T1 follow-up | `d56b4ae` | `mix compile --force --warnings-as-errors` exit 0 (parent re-run) | slice 1 |
| T1 follow-up | `727d198` | `bin/migrate` 55/55 on empty database with a 38-byte pepper; backfill hash equals `ChatIdHash.hash/2`; `mix precommit` 1926 passed, 5 skipped | slice 1 |

## Next step

Native review of slice 1 (base `8e3cbac`, assessed high: executable mode on
`rel/overlays/bin/migrate`), then slice 2 starting with T4.

## Accepted changes during slice 1

- Routes: T1, T2 and T3 ran through one delegated writer (writer trigger).
- The chat id hash migration `20260618234145` was edited in place: its backfill
  passed the pepper as the `down` argument of `execute/2` and needed `pgcrypto`,
  so `bin/migrate` failed on an empty database with a production-sized pepper.
  It now computes the HMAC in Elixir, byte-identical to
  `Alethea.Telegram.ChatIdHash.hash/2`. Applied databases are unaffected.
- An unreachable clause in `lib/alethea/clinical_record.ex` was removed because
  it failed `mix precommit` on Elixir 1.20 on the base commit.
- The image `HEALTHCHECK` was removed: the slim runner has no HTTP client and
  Fly uses its own checks.

## Pending checks

- `docker build` and image boot (Docker daemon not running locally).
- `bin/server` serving `/health/ready` from the release.
- Behaviour under the CI toolchain (Elixir 1.19 / OTP 28).
