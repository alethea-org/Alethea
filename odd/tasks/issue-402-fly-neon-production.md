# Issue 402 — Production readiness on Fly.io with PostgreSQL on Neon

- Issue: https://github.com/alethea-org/Alethea/issues/402
- Branch: `chore/402-fly-neon-production` (from `main` at `8e3cbac`)
- Engram mirror: `odd/issue-402-fly-neon-production/tasks`
- Status: repository work for milestone 1 complete (T1–T8 committed and
  reviewed); remote evidence pending user authorization
- Engram mirror status: PENDING resync (save refused on 2026-10-07: multiple
  active runtime sessions); this file is authoritative.

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
- [x] **T4 — Production configuration.** Verified TLS for the Repo, required
  `PHX_HOST`, `check_origin`, pool and queue settings for Neon, no `localhost`
  AI defaults in production, explicit capability switches.
  Route: delegated (config plus config tests plus `LLMConfig`).
  Checks: `Config.Reader.read!(path, env: :prod)` tests, following
  `test/config/telegram_client_config_test.exs`.
- [x] **T5 — AI capability degradation.** A disabled or failing AI capability
  no longer leaves session closure incomplete; `EmotionAnalysisWorker` does not
  raise per inbound message when the analyzer is disabled.
  Route: delegated (workers plus `Alethea.AI` plus tests).
  Checks: RED/GREEN in `test/alethea_jobs/session_timeout_worker_test.exs` and
  `emotion_analysis_worker_test.exs`; sentiment regression test.
- [x] **T6 — Telegram production bootstrap.** Release-callable, idempotent
  `BotConfig` bootstrap and `setWebhook` registration with `secret_token`,
  verified through `getWebhookInfo`; `Client.Fake` not started in production.
  Route: delegated.
  Checks: Req.Test-backed tests; existing bootstrap task test stays green.
- [x] **T7 — Fly configuration and deployment doc.** `fly.toml` (HTTPS, port,
  checks on `/health/ready`, always-on Machine, `release_command`), plus a
  deployment document covering the Neon connection scheme (direct host, pool,
  migrations, Oban `LISTEN/NOTIFY`), secrets inventory and the AI inventory.
  Route: delegated or inline, decided at execution.
  Blocked on: app name and primary region (pending decision in the issue).
- [x] **T8 — CI.** Build the image and smoke-test the release (migrate, boot,
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
- Running count (native assessment): slice 1 647 lines, T4 951, T5 733.

## Progress and evidence

| Task | Commit | Checks observed | Review tier / outcome |
| --- | --- | --- | --- |
| T1 | `6b0c4ba` | Mix usage test RED (6 offenders) then GREEN; release builds; `bin/alethea eval` passes runtime config | slice 1 |
| T2 | `dcfc015` | Image tags confirmed on Docker Hub; `docker build` NOT RUN (daemon down) | slice 1 |
| T3 | `8f626c3` | Health tests RED 6/13 then GREEN 13/13; parent re-run 14 passed | slice 1 |
| T1 follow-up | `d56b4ae` | `mix compile --force --warnings-as-errors` exit 0 (parent re-run) | slice 1 |
| T1 follow-up | `727d198` | `bin/migrate` 55/55 on empty database with a 38-byte pepper; backfill hash equals `ChatIdHash.hash/2`; `mix precommit` 1926 passed, 5 skipped | slice 1 |

## Next step

Slice 2 on `chore/402-prod-config-ai-telegram`: T4 and T5 through one writer,
then T6.

## Native review

- Slice 1, base `8e3cbac` through `2caeb19`: assessed high (executable mode on
  `rel/overlays/bin/migrate`); consent granted by the user; four lenses;
  approved and acknowledged (lineage `review-5246702de73ab3fa`). Twelve
  non-blocking advisory findings were returned with locations only (six
  warnings: this document 83-86, the migration 130-141, `Dockerfile:13-15`,
  `clinical_record.ex:2408`, `release_test.exs:17-20`,
  `health_controller.ex:84-87`). Reviewed boundary is now `2caeb19`.
- T4, `dc13b79..f0c1892`: medium, slice budget reached; consent granted; one
  reliability lens; approved and acknowledged (lineage
  `review-9730ad3f909df59e`). Advisory, locations only: warnings at
  `config/runtime.exs:171-172`, `:310-314`, `llm_config.ex:250-252`.
- T5, `f0c1892..492bee2`: medium, slice budget reached; consent granted; one
  reliability lens; approved and acknowledged. Advisory, locations only:
  warnings at `session_timeout_worker.ex:235-236`, `:389-394`, `:417-427`.
  Reviewed boundary is now `492bee2`.
- T6, `89af743..c14721f`: high (executable mode on
  `rel/overlays/bin/telegram_bootstrap`, security in `webhook_info.ex`);
  consent granted; four lenses; approved and acknowledged. Ten advisory
  findings, locations only; warnings at `telegram/bootstrap.ex:18-22`,
  `:100-104`, `release.ex:186-195`, `mix/tasks/alethea.telegram.bootstrap.ex:50`.
  Reviewed boundary is now `c14721f`.

## Evidence for T6

- `37142d2` and `c14721f`, delegated: new tests RED 0/26 then GREEN 26 (parent
  re-run with the application test: 34 passed); release smoke on a throwaway
  database: `bin/telegram_bootstrap` created, unchanged, updated; token column
  is ciphertext; `mix precommit` 2017 passed, 5 skipped.
- Not verified: full application boot from the release; webhook registration
  against the real Telegram API (stubs only).
- Decisions for T7: Fly app `alethea-prod` (default chosen by the agent, one
  line to change), primary region `gru` with Neon in AWS `sa-east-1` (user
  choice, 2026-10-07).
- Gap for the user: whether `TELEGRAM_BOT_TOKEN`, `TELEGRAM_WEBHOOK_SECRET` and
  `TELEGRAM_BOT_USERNAME` remain permanent deploy secrets or are supplied once.
- Outside the surface: `BotConfig.upsert` should pass `log: false` itself; the
  debug query log prints the plaintext token before Cloak encrypts it, and
  only the new bootstrap caller guards against it.

## Evidence for T4 and T5

- T4 `f0c1892`, delegated: `mix test test/config` RED 5/27 then GREEN 27
  (parent re-run 27 passed); release `eval` with a complete fake env prints
  `ok`, and raises clearly without `PHX_HOST` or with
  `EMOTION_ANALYZER_ENABLED=true` and no endpoint.
- T5 `492bee2`, delegated: worker tests RED 19/28 then GREEN 28; sentiment
  regression 2 passed; `mix precommit` 1971 passed, 5 skipped.

## Open gaps handed to the user (not decided here)

- With `AI_PROVIDER=cloud` and no `LOCAL_LLM_BASE_URL`, every chain except
  guided conversation is "not configured": summaries fail and retry, and
  consultations and reports return errors. Letting those chains use the hosted
  provider is a privacy decision.
- There is no "LLM disabled" mode, only `local` or `cloud`.
- Enabling the emotion analyzer in production conflicts with its
  development-only posture from issue 198.
- Trends are not resumable after a crash between close and save (needs a
  session reference column).
- Goodbye idempotency relies on `oban_jobs` rows persisting (no Pruner today).
- Outside the delegated surface: `telegram_message_worker.ex:411` still
  enqueues a no-op emotion job per message when the analyzer is off;
  `clinical_record/rag/indexer.ex:296` retries and fails per event when
  embeddings are off; `SessionSummaryChain` returns a map while its behaviour
  documents a string; `.env.example` and README lack the new variables.

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

## Evidence for T7 and T8

- T7 `db1a46e`, delegated: `fly.toml` (app `alethea-prod`, region `gru`, one
  always-on Machine, `release_command = "/app/bin/release"`, check on
  `/health/ready`, `kill_timeout = 40`), `rel/overlays/bin/release`, and
  `docs/deployment/fly-neon.md`. Release smoke on a throwaway database:
  `bin/release` migrates and bootstraps, and skips the bootstrap without
  `TELEGRAM_BOT_TOKEN`. Full server boot from the release: `/health/ready` 200,
  `/health` 200, `/assets/js/app.js` 200, clean exit on SIGTERM.
- T8 `7b32188`, delegated: `release` job in `.github/workflows/elixir.yml`
  (image build plus release smoke test) and `--warnings-as-errors` in the test
  job. YAML parses; the job has never run.
- Follow-up `f87018b`: `?ssl=false` in `DATABASE_URL` overrode the verified TLS
  (reproduced through `Ecto.Repo.Supervisor.init_config/4`); production now
  refuses to boot when the URL carries an `ssl` parameter. Config tests RED
  29/31 then GREEN 31 (parent re-run 31 passed). `mix precommit` 2020 passed,
  5 skipped.
- Native review, `6c41e7d..f87018b`: high (executable mode on
  `rel/overlays/bin/release`, shell in the workflow); consent granted; four
  lenses; approved and acknowledged. Eleven advisory findings, locations only;
  warnings at `.github/workflows/elixir.yml:160-164` and `:168-171`.
  Reviewed boundary is now `f87018b`.

## Final slice map (stacked-to-main)

| PR | Branch | Tip | Contents |
| --- | --- | --- | --- |
| 1 | `chore/402-fly-neon-production` | `dc13b79` | T1, T2, T3, migration and clause fixes |
| 2 | `chore/402-prod-config` | `f0c1892` | T4 |
| 3 | `chore/402-ai-degradation` | `89af743` | T5 |
| 4 | `chore/402-telegram-bootstrap` | `6c41e7d` | T6 |
| 5 | `chore/402-fly-ci` | this document's last commit | T7, T8, `ssl` URL guard |

Nothing is pushed and no pull request exists.

## Still unverified

- `docker build` and image boot (Docker daemon not running locally).
- The CI `release` job, and `--warnings-as-errors` under Elixir 1.19 / OTP 28.
- `fly config validate` (flyctl not installed).
- Guide commands marked "verify before running", notably whether
  `fly ssh console -C` carries the app secrets.
- Everything under "Not achievable from the repository alone".

## Next step

User decisions: AI capability values for launch, Telegram secret policy,
capacity. Then, with explicit authorization per destination: push and open the
five pull requests, create the Neon project, deploy, register the webhook, and
run the verification checklist in `docs/deployment/fly-neon.md`.

## Advisory review follow-up (2026-10-08)

An advisory multi-agent review of pull requests 405–409 confirmed four
findings; the parent verified each against the code and the user asked for all
four to be fixed. Fixes are new commits on the owning branch, carried forward
with merge commits (`21f0b93`, `4d3cf76`, `fda1a08`); no history was rewritten.

| Finding | Branch | Commit | Checks observed |
| --- | --- | --- | --- |
| Chain provider settings lost to global ones | `chore/402-prod-config` | `ea18ae0` | RED 45/48 then GREEN 48 |
| LangChain three-element error broke closure and carried patient text | `chore/402-ai-degradation` | `3ab8dd2` | real chains RED (`CaseClauseError`), GREEN 131 |
| Discarded goodbye could not be recovered | `chore/402-ai-degradation` | `727365c` | RED 20/24 then GREEN 24 |
| Retry decrypted the history although the summary existed | `chore/402-ai-degradation` | `3083f3d` | RED 24/26 then GREEN 26 |

- All seven chains now run through `Alethea.AI.Chains.SafeRun.run/1`, which
  returns `{:error, {:llm_run_failed, type}}` and never keeps the chain, the
  error message or the provider payload. Six chains had the crash.
- The timeout worker no longer returns a changeset as its job result; that put
  `summary_text` into `oban_jobs.errors`.
- Goodbye jobs record `meta["send_started"]` just before the client call. A
  discarded goodbye without the marker is revived with `Oban.retry_job/1`; one
  with the marker, or a cancelled one, is never re-sent and is reported through
  `[:alethea, :session_timeout, :goodbye_unresolved]`.
- `mix precommit` at `fda1a08`: 2062 passed, 5 skipped. Parent re-run of the
  touched suites: 210 passed.
- Native review, `87adddc..fda1a08`: medium; consent granted; one reliability
  lens; approved and acknowledged. Warnings, locations only:
  `session_timeout_worker.ex:492-496`, `safe_run.ex:57-63`,
  `telegram_outbound_worker_test.exs:133`.

Open after the fixes:

- LangChain and `ChatOpenAI` log the provider's error text themselves; with
  the cloud provider that can still reach the logs (needs a Logger filter).
- A goodbye discarded before sending is revived only when the timeout job
  retries, which happens only if the summary failed (needs a reschedule on
  Pacer unavailability, or a sweep job).
- `TelegramOutboundWorker` ignores `{:error, :pacer_timeout}` and sends anyway
  (pre-existing).
- Whether a cancelled goodbye that never ran should be re-sent is undecided.
- `OllamaChat` errors carry no type, so local failures read as `:untyped`.

Tips: `chore/402-prod-config` `ea18ae0`, `chore/402-ai-degradation` `3083f3d`,
`chore/402-telegram-bootstrap` `4d3cf76`, `chore/402-fly-ci` at this
document's last commit.

## Second advisory review follow-up (2026-10-08)

A second advisory pass over pull requests 406–409 approved 407 and 408 and
confirmed three findings, each verified by the parent against the code.

| Finding | Branch | Commit | Checks observed |
| --- | --- | --- | --- |
| Blank LLM endpoint passed as configured | `chore/402-prod-config` | `629807c` | RED 49/53 then GREEN 53 |
| Release command succeeded with no bot configuration | `chore/402-fly-ci` | `fe61ccd` | RED 24/31 then GREEN 35; release smoke in all three branches |
| Operator secrets file not ignored | `chore/402-fly-ci` | `188746c` | `git check-ignore` matches `*.secrets`, `*.key`, `*.pem` |

- A blank endpoint falls through to the next source in the precedence chain;
  `OPENAI_BASE_URL` set to an empty string now resolves to the default. With
  `""`, the local adapter used to fall back silently to `localhost:11434`.
- `bin/telegram_bootstrap check` decrypts the stored row; `bin/release` calls
  it when `TELEGRAM_BOT_TOKEN` is absent and exits non-zero when the row is
  missing or unreadable, before the new version starts.
- Forward merges `d6515c2`, `0a23f38`, `fd6998d`; no conflicts.
- `mix precommit` at `188746c`: 2077 passed, 5 skipped. Parent re-run of the
  touched suites: 92 passed.
- Native review, `386598d..188746c`: high (shell in the workflow); consent
  granted; four lenses; approved and acknowledged. Warnings, locations only:
  `release.ex:123`, `telegram/bootstrap.ex:149-150`,
  `rel/overlays/bin/release:38-40`.

Tips: `chore/402-prod-config` `629807c`, `chore/402-ai-degradation` `d6515c2`,
`chore/402-telegram-bootstrap` `0a23f38`, `chore/402-fly-ci` at this
document's last commit.

## Third advisory review follow-up (2026-10-08)

Route: direct inline (two small, already-understood fixes verified against the
code before the first write).

| Finding | Branch | Commit | Evidence |
| --- | --- | --- | --- |
| Blank or unresolved API key masked the global key | `chore/402-prod-config` | `472a99a` | RED 24/25 then GREEN; `test/alethea/ai` 259 passed |
| Goodbye lookup could not use the `args` GIN index | `chore/402-ai-degradation` | `f53f2fb` | Session worker suites 35 passed; `EXPLAIN` with `enable_seqscan = off`: containment uses `oban_jobs_args_index`, `->>` stays a sequential scan |

- The API key fix also covers a `{:system, "VAR"}` tuple whose variable is
  unset, which masked the global key the same way.
- Containment is equivalent here because `Session` uses a binary id, so
  `session_id` is always stored as a JSON string.
- `f53f2fb` also corrects the stale `send_goodbye/2` arity in a comment.
- Forward merges `ccc2a83`, `430781b`; no conflicts.
- `mix precommit` at `430781b`: 2078 passed, 5 skipped.
- Native assessment, `37f80fa..430781b`: medium, 36 changed lines,
  `under_budget`; no review due.
- Pushed to `origin` on 2026-10-08.

Tips: `chore/402-prod-config` `472a99a`, `chore/402-ai-degradation` `f53f2fb`,
`chore/402-telegram-bootstrap` `ccc2a83`, `chore/402-fly-ci` at this
document's last commit.
