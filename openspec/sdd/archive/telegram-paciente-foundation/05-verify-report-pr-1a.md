# Verify Report — `telegram-paciente-foundation` (PR #1a)

**PR:** #1a — Foundations A: Sealed Secrets + HMAC Identity Helper
**Branch:** `feat/telegram-paciente-foundation/pr-1a-foundations-a`
**Base:** `main`
**Verdict:** **PASS** (re-verified after 2 WARNING fixes; 0 CRITICAL, 0 WARNING, 3 SUGGESTION carryover)
**Verifier mode:** Source-driven + `mix test` + `mix precommit` re-run
**Strict TDD:** active (per `openspec/config.yaml`); TDD evidence validated in `apply-progress.md`
**Date (initial):** 2026-06-16
**Date (re-verification):** 2026-06-16

---

## 1. Completeness

| Artifact | Present? | Notes |
|---|---|---|
| `proposal.md` | yes | 145 lines, 7 capabilities (C-1…C-7) |
| `specs/C-2-hmac-chat-id-lookup/spec.md` | yes | 4 REQ-C2-* (pure half in scope for PR #1a) |
| `specs/C-6-vault-sealed-bot-token/spec.md` | yes | 4 REQ-C6-* (all in scope for PR #1a) |
| `design.md` | yes | 656 lines, 19 sections; Decision 4 matches implementation |
| `tasks.md` | yes | 6-slice plan, PR #1a contains 4 tasks |
| `apply-progress.md` | yes | All 4 tasks complete; 4 deviations documented; follow-up section documents W-1 + W-2 fixes |
| `verify-report.md` | this file | — |

All spec / design / task artifacts are present. Verification is full-spec (specs + design + tasks all available).

---

## 2. Test Execution Evidence

### 2.1 `mix precommit` (re-run on the branch after the 2 follow-up commits)

✅ **GREEN** — exit code 0.

```
324 tests, 0 failures, 5 skipped
```

- `compile --warnings-as-errors`: pass
  - The 2 warnings emitted (`unused alias EmotionAnalysisWorker` in `test/alethea_jobs/emotion_analysis_worker_test.exs:4:3` and `variable "call_count" is unused` in `test/alethea_jobs/weekly_report_worker_test.exs`) are **pre-existing** in `main`; this PR does not touch `test/alethea_jobs/` (verified by `git diff main..HEAD -- test/alethea_jobs/ lib/alethea_jobs/` → empty). The follow-up batch added 0 new warnings.
- `deps.unlock --unused`: no changes to `mix.lock`
- `format --check-formatted`: pass (no output)
- `test`: 324 tests, 0 failures, 5 skipped (all 5 pre-existing skipped, none new)

### 2.2 Test counts (delta vs main)

| Stage | Total tests | Delta | Skipped | Failures |
|---|---|---|---|---|
| main (baseline, pre-PR) | 292 | — | 5 | 0 |
| After PR #1a (6 commits) | 319 | +27 | 5 | 0 |
| After W-1 follow-up (f0c878f) | 322 | +3 | 5 | 0 |
| After W-2 follow-up (010ae20) | 324 | +2 | 5 | 0 |
| **Current branch (HEAD)** | **324** | **+32 vs main** | **5** | **0** |

**+5 new tests since the original verify report** (3 W-1 + 2 W-2). All pass. No regressions in the original 319.

### 2.3 Targeted test runs (per-task discipline, re-run)

| Command | Result |
|---|---|
| `mix test test/alethea/telegram/bot_token_test.exs` | 11 passed, 0 failed |
| `mix test test/alethea/telegram/chat_id_hash_test.exs` | 8 passed, 0 failed |
| `mix test test/alethea/foundation/accounts/bot_config_test.exs` | 13 passed, 0 failed |
| `mix test --trace test/alethea/telegram/bot_token_test.exs` | 11 passed; `Logger.error` line fires in the W-1 failure-path tests as expected and the test still passes — confirms the W-1 wiring is correct. |

---

## 3. Spec Compliance Matrix

### 3.1 C-2 (pure half only — DB-rename and lookup are PR #2)

| Requirement | Scenario | In scope here? | Test covering | Status |
|---|---|---|---|---|
| `REQ-C2-chat-id-stored-as-hmac` | onboarding persists the hash, not the raw id | partial (pure helper only) | `ChatIdHash` test "matches `:crypto.mac(:hmac, :sha256, pepper, chat_id)` byte-for-byte" (L55-64) | ✅ |
| `REQ-C2-chat-id-stored-as-hmac` | same chat_id + same pepper yields the same hash | yes | "same chat_id and same pepper produce the same hash" (L25-28) | ✅ |
| `REQ-C2-chat-id-stored-as-hmac` | different pepper yields a different hash | yes | "same chat_id and different pepper produce different hashes" (L35-38) + "module exposes no decoding helper" (L67-78) | ✅ |
| `REQ-C2-lookup-by-hash` | all 3 scenarios | **out of scope (PR #2)** | — | — |
| `REQ-C2-partial-unique-index` | all 3 scenarios | **out of scope (PR #2)** | — | — |
| `REQ-C2-no-plaintext-in-logs` (in-scope slice: ChatIdHash) | no `Logger` line, no `inspect`, no telemetry | yes | ChatIdHash source has no `Logger`, no `inspect`, no telemetry calls | ✅ |

### 3.2 C-6 (all 4 REQs in scope for PR #1a)

| Requirement | Scenario | Test covering | Status |
|---|---|---|---|
| `REQ-C6-bot-token-stored-encrypted` | bot token is sealed at rest | "the raw database row stores ciphertext, not plaintext" (bot_config_test.exs L56-87) — uses raw SQL to assert `:binary.match(blob, plaintext) == :nomatch` | ✅ |
| `REQ-C6-bot-token-stored-encrypted` | webhook secret token is sealed at rest | same test, also asserts `:binary.match(secret_blob, "prod-shared-secret") == :nomatch` | ✅ |
| `REQ-C6-bot-token-stored-encrypted` | decryption is allowed only through the accessor | "the bot_token field on the loaded struct is the plaintext, not the ciphertext" (L42-54) + BotToken tests | ✅ |
| `REQ-C6-distinct-per-env` | only one row per env is allowed | "a second upsert for the same env updates the row in place" (L104-111) | ✅ |
| `REQ-C6-distinct-per-env` | dev and prod tokens are independent | "two different envs coexist as two rows" (L113-118) + "env accepts dev, test, prod" (L91-96) | ✅ |
| `REQ-C6-bot-token-gen-server-accessor` | accessor returns the configured values | "loads the bot_token, secret_token, and bot_username from the env row" (bot_token_test.exs L41-55) | ✅ |
| `REQ-C6-bot-token-gen-server-accessor` | reload picks up a new row | "BotToken.reload/0 (cast path, public API) re-reads the row from the DB" (L72-108) + "send(pid, :reload) (info path) re-reads the row from the DB" (L110-139) — **both paths now directly tested** (S-1 from original report also addressed) | ✅ |
| `REQ-C6-bot-token-gen-server-accessor` | missing row raises on boot, not on first call | "the GenServer refuses to start when no BotConfig row exists for the env" (L58-69) + W-2 regression test "init/1 logs the whitelist tag for the :not_found reason" (L322-343) — asserts `msg =~ "no BotConfig row for env=test"` AND `log =~ "(reason: :not_found)"` | ✅ |
| `REQ-C6-bot-token-gen-server-accessor` | reload failure does not silently break the GenServer | W-1 tests at L172-218 (info path) and L220-261 (cast path) — assert state reset to nil, GenServer still alive, log present, no plaintext in log | ✅ |
| `REQ-C6-no-plaintext-in-env` | no `TELEGRAM_BOT_TOKEN` env var is read in prod | `grep -rn "TELEGRAM_BOT_TOKEN\|TELEGRAM_SECRET_TOKEN" lib/ config/ test/` returns **zero matches** | ✅ |
| `REQ-C6-no-plaintext-in-env` | test env may set a test-only pepper via `Application.put_env` | ChatIdHash is a pure module that takes pepper as an argument — no env var read, so the test-only pepper path is structurally possible. The pepper is not yet consumed in the test suite (consumption is PR #2 / #4), so the scenario is satisfied trivially. | ✅ |
| `REQ-C6-no-plaintext-in-env` | secret-token header check uses the sealed value | **out of scope (PR #2, the plug is downstream)** | — |

**Spec compliance: 100% of in-scope requirements satisfied. Zero missing test cases.** The follow-up batch ALSO satisfies the W-1 and W-2 defensive-logging requirements (which were not in the original C-2/C-6 spec scenarios but were raised as warnings by the first verify report).

---

## 4. TDD Compliance (Strict TDD mode active)

| Check | Result | Details |
|---|---|---|
| TDD Evidence reported | ✅ | `apply-progress.md` §"TDD Cycle Evidence" — 4-task table with RED/GREEN/REFACTOR + follow-up section with W-1 and W-2 TDD cycles |
| All tasks have tests | ✅ | TASK-1a-1 → chat_id_hash_test.exs (8 tests); TASK-1a-2 → bot_config_test.exs (13 tests); TASK-1a-3 → bot_token_test.exs (11 tests after follow-up, was 6); TASK-1a-4 → no test file (infra wiring, covered by full suite) |
| RED confirmed (tests exist) | ✅ | All 3 test files exist on disk; verified by `ls`; 32 new tests across the 3 files |
| GREEN confirmed (tests pass) | ✅ | 32/32 new tests pass; full suite 324/324 |
| Triangulation adequate | ✅ | 8 cases for hash (4 behaviours × 2 axes); 13 cases for BotConfig (4 behaviours: encryption, env, for_env, validation); 11 cases for BotToken (5 behaviours: start, init-fail, reload success on both paths, reload failure on both paths, state source, reason_tag whitelist); each test asserts a different value |
| Safety Net for modified files | ✅ | TASK-1a-4 modifies `application.ex` (added one child spec); covered by `mix test` full suite passing. `config/test.exs` modifies the test config; covered by `mix precommit` green. |
| Follow-up W-1 cycle (RED → GREEN → REFACTOR) | ✅ | `f0c878f` — RED confirmed (capture_log returned `""` before the log call existed), GREEN confirmed (2/2 pass), REFACTOR extracted `do_reload/0` (S-4) and split the cast/info test paths |
| Follow-up W-2 cycle (RED → GREEN → REFACTOR) | ✅ | `010ae20` — RED attempted for the integration test (lock conflict — see §6 deviation), GREEN confirmed on the unit + regression test (2/2 pass), REFACTOR reused `reason_tag/1` from W-1 (DRY) |

### 4.1 Test Layer Distribution

| Layer | Tests | Files | Tools |
|---|---|---|---|
| Unit | 32 | 3 | ExUnit + Alethea.DataCase + ExUnit.CaptureLog |
| Integration | 0 | 0 | — (no HTTP / no Oban workers in this PR) |
| E2E | 0 | 0 | — (out of scope) |
| **Total** | **32** | **3** | |

### 4.2 Assertion Quality

✅ **All assertions verify real behavior.** No trivial assertions found.

- `ChatIdHashTest` assertions check hash structure (64 chars, lowercase hex), hash determinism (same input → same output), hash uniqueness (different input → different output), hash matches `:crypto.mac` byte-for-byte, and a structural assertion that no `decode`/`unhash`/`reverse`/`recover`/`decrypt` function is exported by the module. All assertions would fail if the implementation were wrong.
- `BotConfigTest` assertions check `:binary.match(blob, plaintext) == :nomatch` (proves the raw DB column is opaque), schema round-trip via `Repo.get!`, `Ecto.UUID.dump!` for proper binary id handling, `Repo.aggregate(:count) == 1` (proves unique constraint), and validation rejection via `errors_on/1`. All assertions would fail if the implementation were wrong.
- `BotTokenTest` assertions check `GenServer.call` returns the seeded plaintext, the GenServer raises on missing row, `:sys.get_state/1` synchronization (project discipline per `AGENTS.md`), process state is the source of truth (proves no DB read on every call), `capture_log` content for both reload-failure paths and the init/1 fail-loud path, `Process.alive?` after failure (proves the GenServer is preserved), and the `reason_tag/1` whitelist (proves no payload leaks). All assertions would fail if the implementation were wrong.

### 4.3 Coverage Analysis

`mix test --cover` was not run (would add ~30 s to the verification round-trip and the strict TDD module marks coverage as informational, not blocking). The 32 new tests cover all 11 in-scope spec scenarios plus the 2 defensive-logging WARNINGs, and exercise every public function in the 3 new modules. Spot-check on `BotToken` after the follow-up:

- `start_link/1`: covered
- `bot_token/0`: covered
- `secret_token/0`: covered
- `bot_username/0`: covered
- `reload/0` (cast path, public API): **now directly covered** (L72-108 + L220-261) — S-1 resolved
- `send(pid, :reload)` (info path): covered (L110-139 + L172-218)
- `stop/0`: covered
- `reason_tag/1`: covered (L285-320)
- `init/1` `:not_found` log path: covered (L322-343)

---

## 5. Encryption-Vault Skill Compliance

| Skill restriction | Implementation | Compliance |
|---|---|---|
| Sin PII en claro | `Cloak.Ecto.Binary` on `token_ciphertext` and `secret_token_ciphertext`; raw SQL test confirms plaintext is not a substring of the ciphertext blob | ✅ |
| Sin búsqueda en claro | `ChatIdHash.hash/2` is the only key path; raw chat_id is never the column value | ✅ |
| Sin DEK en claro | Bot token is sealed by the existing `Alethea.Encryption.Vault` (AES-GCM) — the same Vault that protects the legacy WhatsApp fields. The bot token is not a patient-specific DEK; it is app-wide config, so the Vault key is the correct granularity. | ✅ |
| Sin correlación | The chat_id HMAC uses a pepper passed as an argument; per-deployment, not per-psychologist (per design §7 — per-psychologist pepper is a future change). The pepper is read at the call site, not in the helper. | ✅ (foundation scope) |
| Borrado seguro | Out of scope for this PR (Cryptographic Erasure lives in ADR-0008 and is PR #1b). The `BotConfig` row is rotatable via `upsert/1` and `:reload` — see REQ-C6-bot-token-gen-server-accessor scenario "reload picks up a new row". | ✅ (rotation) / n/a (erasure) |

---

## 6. Plaintext Leakage Audit

| Surface | Plaintext bot token? | Plaintext chat_id? | Notes |
|---|---|---|---|
| `lib/alethea/telegram/chat_id_hash.ex` | n/a | **No** | Pure module; no `Logger`, no `inspect`, no telemetry. The function returns the hash only. |
| `lib/alethea/telegram/bot_token.ex` | **No** | n/a | All `Logger.error` calls (init/1 at L121-125, log_and_reset/1 at L206-211) route the `reason` through `reason_tag/1` (L153-156), a **whitelist match** with 3 cases: `:not_found` → `":not_found"`, `{:unexpected, _}` → `":unexpected"`, anything else → `"other"`. **No `inspect/1` call in any log path.** The 3 `inspect` matches in the file (L115, L145, L199) are all in comments documenting the W-2 fix. |
| `lib/alethea/foundation/accounts/bot_config.ex` | **No** | n/a | The schema is the boundary; callers see plaintext (via Cloak decode on load), the DB sees ciphertext. No `Logger` or `inspect` calls on plaintext. |
| `test/alethea/telegram/chat_id_hash_test.exs` | n/a | **No** | Test uses `@chat_id "123456789"` as a fixture value in a `refute` assertion (`refute String.contains?(hash, @chat_id)`). The literal `"123456789"` is a string literal in the test, not a leaked runtime value. |
| `test/alethea/foundation/accounts/bot_config_test.exs` | **Test fixture only** | n/a | Uses `"123456:ABC-DEF-PROD-TOKEN"` and `"prod-shared-secret"` as test inputs. These are test fixtures, not production secrets. They are passed to `BotConfig.upsert/1` and verified to NOT appear in the raw ciphertext blob. |
| `test/alethea/telegram/bot_token_test.exs` | **Test fixture only** | n/a | Uses `"test-bot-token-123"`, `"old-token"`, `"live-token"`, etc. as test inputs. These are test fixtures, not production secrets. The W-1 tests at L172-261 assert `refute log =~ "live-token"` — a positive test that the previously-loaded plaintext does NOT leak into the log after a failed reload. |
| `config/test.exs` | **No** | **No** | Adds `:start_bot_token` config flag and `:start_ai` config flag. No plaintext tokens. |
| Application supervision (`lib/alethea/application.ex`) | **No** | n/a | The BotToken child spec name is `Alethea.Telegram.BotToken` — no plaintext. |

✅ **No plaintext leakage detected anywhere in code, tests, config, or supervision wiring.**

### 6.1 `Logger.error` in `init/1` — deep-dive (post W-2)

```elixir
# bot_token.ex L119-125
require Logger

Logger.error(
  "Alethea.Telegram.BotToken failed to boot: " <>
    "no BotConfig row for env=#{Mix.env()} (reason: #{reason_tag(reason)}). " <>
    "Seed a row via Alethea.Foundation.Accounts.BotConfig.upsert/1 before starting the app."
)
```

`reason_tag/1` is the whitelist match (L153-156). The `reason` is `:not_found` (atom) or `{:unexpected, other}` (tuple). `:not_found` → `":not_found"`, `{:unexpected, _}` → `":unexpected"`, anything else → `"other"`. **No payload can leak.** Verified by the unit test at L285-320 which feeds a `%BotConfig{...sensitive fields...}` struct and asserts the tag does NOT contain the struct's fields.

### 6.2 `Logger.error` in `log_and_reset/1` — deep-dive (post W-1)

```elixir
# bot_token.ex L204-213
require Logger

Logger.error(
  "Alethea.Telegram.BotToken reload failed: " <>
    "no BotConfig row for env=#{Mix.env()} (reason: #{reason_tag(reason)}). " <>
    "Re-seed the row via Alethea.Foundation.Accounts.BotConfig.upsert/1 and send :reload again. " <>
    "Failing closed: bot_token/0 now returns nil until the row is restored."
)

{:noreply, %{bot_token: nil, secret_token: nil, bot_username: nil}}
```

The same `reason_tag/1` whitelist applies. The state is reset to nil (fail-closed). The GenServer is preserved (does not crash). Verified by tests at L172-218 (info path) and L220-261 (cast path) — both assert `Process.alive?(pid) == true` after the failure.

---

## 7. Deviation Assessment

`apply-progress.md` §"Decisions / deviations from tasks.md" lists 6 deviations. The follow-up section lists 1 additional deviation (W-2 integration test infeasibility). Full assessment:

| # | Deviation | Verdict | Note |
|---|---|---|---|
| 1 | TASK-1a-2 — `upsert/1` uses SELECT-then-INSERT-or-UPDATE instead of Postgres `ON CONFLICT`. | **DEFENSIBLE** | Both approaches satisfy `REQ-C6-distinct-per-env`; the SELECT-then-write form is easier to reason about and matches the existing foundation patterns. The test `"a second upsert for the same env updates the row in place"` (L104-111) explicitly verifies the contract. |
| 2 | TASK-1a-3 — GenServer tests use `Alethea.DataCase, async: false` + `Ecto.Adapters.SQL.Sandbox.allow/3`. | **DEFENSIBLE** | The deviation IS the project standard for any GenServer that reads the DB. Cross-referenced with `Alethea.AI` and `Alethea.WhatsApp` test patterns. Required for sandbox correctness. |
| 3 | TASK-1a-4 — `:start_bot_token` flag is `false` in `:test`, `true` in `:dev`/`:prod` (default). | **DEFENSIBLE** | The flag pattern is already used for `:start_ai`. The spec scenario "missing row raises on boot, not on first call" still holds: in `:prod` the flag is `true`, so the supervisor attempts to start the GenServer, the GenServer's `init/1` fails, and the app refuses to boot. Verified by the test `"the GenServer refuses to start when no BotConfig row exists for the env"` (L58-69). |
| 4 | TASK-1a-3 — `handle_cast(:reload)` added alongside `handle_info(:reload)`. | **DEFENSIBLE** (now DRYed in W-1) | The spec says "send `:reload` to the GenServer (e.g. via a future SIGHUP or admin action)" — does not pin the mechanism. Supporting both `cast/2` and `send/2` is a strict superset of the requirement. The W-1 follow-up extracted the byte-for-byte identical logic to a private `do_reload/0` (S-4 cleanup from §8.3) so the duplication is gone. |
| 5 | TASK-1a-1 — `hash/2` accepts integer or string `chat_id`. | **DEFENSIBLE** | The spec does not pin the input type. The coercion is deterministic and tested. Backward-compatible. |
| 6 | No `Cloak.Ecto` migration step needed. | **DEFENSIBLE** | The migration creates `:binary` columns (the right type for `Cloak.Ecto.Binary`). The `mix cloak.migrate.ecto` step is for re-encrypting existing rows on a column type change; since the table is brand-new, no rows exist. Verified by reading the migration file. |
| 7 | **FOLLOW-UP W-2 — Integration test against `{:unexpected, _}` reason is infeasible.** | **DEVIATION ACCEPTED** | The apply agent documented this carefully. The only way to trigger the `:unexpected` path is a `BotConfig` row with a non-binary field (e.g. `bot_username: nil`). The migration has `null: false` on `bot_username` (verified at `priv/repo/migrations/20260616145733_create_foundation_bot_configs.exs:35`). The test would need `ALTER TABLE ... DROP NOT NULL`, but the Ecto sandbox holds a `ROW EXCLUSIVE` lock on the table that conflicts with the `ACCESS EXCLUSIVE` lock required by `ALTER TABLE` on any other connection — deadlocking the test for the 15 s checkout timeout. The unit test on `reason_tag/1` is the substantive substitute: it directly tests the whitelist logic (the actual code change) and includes a sensitive-payload assertion. **The deviation is accepted; it does NOT weaken a requirement.** |

**All 7 deviations are defensible / accepted; none weaken a requirement.**

---

## 8. Findings

### 8.1 CRITICAL

*(none)*

### 8.2 WARNING

| # | Status | Req | File:Line | Description | Recommended fix |
|---|---|---|---|---|---|
| W-1 | **RESOLVED** ✅ | n/a | `lib/alethea/telegram/bot_token.ex:137, 140, 169-174, 201-214` | The reload path now calls `do_reload/0` (L169-174) which routes failures through `log_and_reset/1` (L201-214). The log message (L206-211) is clear, sensitive-data-free (uses `reason_tag/1`), and includes the env and remediation steps. The state is reset to nil (fail-closed) and the GenServer is preserved. New tests at L172-218 (info path) and L220-261 (cast path) assert all four contract properties (log present, state reset, GenServer alive, NO plaintext in log). | n/a — fix is in place. |
| W-2 | **RESOLVED** ✅ | n/a | `lib/alethea/telegram/bot_token.ex:119-128, 153-156, 201-214` | All `Logger.error` calls now use `reason_tag/1` (L153-156) — a public, exhaustive whitelist match: `:not_found` → `":not_found"`, `{:unexpected, _}` → `":unexpected"`, anything else → `"other"`. No `inspect/1` in any log path. New unit test at L285-320 covers all 3 branches with a sensitive-payload assertion. New regression test at L322-343 pins the `init/1` log format for the `:not_found` case. | n/a — fix is in place. |

### 8.3 SUGGESTION (carryover from original report)

| # | Status | Req | File:Line | Description | Recommended fix |
|---|---|---|---|---|---|
| S-1 | **RESOLVED** ✅ | n/a | `test/alethea/telegram/bot_token_test.exs:72-108, 220-261` | The cast path (public `BotToken.reload/0` API) is now directly tested for both the success case (L72-108) and the failure case (L220-261). The info path (`send/2`) is also directly tested (L110-139 and L172-218). Both paths share the same `do_reload/0` private function (L169-174). | n/a — fix is in place. |
| S-2 | OPEN | n/a | `lib/alethea/telegram/bot_token.ex:90-100` | `stop/0` uses `rescue _ -> :ok` which masks any unexpected error. The moduledoc says "Test-only helper" but the function itself does not flag this. | Add a comment making the test-only contract explicit, OR guard with `if Mix.env() == :test do` so a stray call in production raises. |
| S-3 | OPEN | `REQ-C2-chat-id-stored-as-hmac` (scenario "no log line, telemetry event, or row contains the literal 123456789") | `test/alethea/telegram/chat_id_hash_test.exs` | The spec scenario includes a clause about no log line containing the literal `123456789`. The implementation trivially satisfies this (the helper has no `Logger`/`inspect`/telemetry), but the test does not explicitly capture-and-assert "no log line contains 123456789". | Optional: add a `ExUnit.CaptureLog.capture_log/1` test that hashes `"123456789"` and asserts the captured log does not contain `"123456789"`. The current structural test ("module exposes no decoding helper") is stronger. |
| S-4 | **RESOLVED** ✅ | n/a | `lib/alethea/telegram/bot_token.ex:137, 140, 169-174` | The byte-for-byte identical `handle_cast/2` and `handle_info/2` have been extracted to a single `do_reload/0` (L169-174). Both callbacks are now one-liners. | n/a — fix is in place. |
| S-5 | OPEN | n/a | `test/alethea/telegram/chat_id_hash_test.exs:46-50` | The doctest in `chat_id_hash.ex` (L46-50) and the "known-good HMAC vector" test (L55-64) duplicate the reference computation. | Acceptable as-is — the doctest is documentation; the test is a structural guard. No fix needed. |

**Carryover SUGGESTION count: 3 (S-2, S-3, S-5).** All non-blocking, all stylistic / test-coverage / documentation improvements. **No new SUGGESTIONs introduced by the follow-up batch.**

---

## 9. Robustness & Idempotency

| Check | Result | Evidence |
|---|---|---|
| `BotToken.init/1` fail-loud on missing row | ✅ | Test L58-69 + Logger.error + raise in `init/1` (L114-122) + W-2 regression test L322-343 |
| `:reload` safe to call concurrently | ⚠️ (untested) | The `load/0` function is pure (no shared mutable state), so concurrent `:reload` messages are safe by construction. No test explicitly asserts concurrent safety, but it is structurally impossible to corrupt. |
| `:reload` failure preserves the GenServer | ✅ | W-1 tests at L172-218 and L220-261 both assert `Process.alive?(pid) == true` after a `Repo.delete_all(BotConfig)` + `:reload` |
| `:reload` failure fails closed (no stale creds) | ✅ | W-1 tests assert `BotToken.bot_token() == nil` after the failed reload — webhooks will 401, not send with the previous plaintext |
| GenServer startup gated on `:start_bot_token` flag | ✅ | `application.ex:25-34` checks the flag; `config/test.exs:64` sets it to `false` in `:test`; the default is `true` in `:dev`/`:prod` |
| Race where a process calls `BotToken.bot_token/0` before GenServer loads | n/a (mitigated) | In `:test`, the flag is `false` and the test starts the GenServer manually before any accessor call. In `:dev`/`:prod`, the GenServer is supervised and starts before the application returns from `start/2`; the supervisor's `:one_for_one` strategy means a crash restarts the GenServer. |
| `mix precommit` green on the branch (post follow-up) | ✅ | Re-run: 324 tests, 0 failures, 5 skipped; exit code 0 |

---

## 10. Migration Safety

| Aspect | Assessment |
|---|---|
| Forward-only operations | ✅ The migration is `create table(...)` + `create unique_index(...)` — both additive. No `alter`, no `remove`, no data backfill. |
| Data loss on rollback | ✅ A `mix ecto.rollback` would drop the empty table (no rows exist in any env — this is the foundation slice, no bot configs seeded yet). |
| Compatibility with future rollbacks | ✅ The migration uses standard Ecto primitives (`create`, `add :id, :binary_id, primary_key: true`); no PostgreSQL extensions, no custom types. |
| Cloak.Ecto compatibility | ✅ `:binary` columns are the correct type for `Cloak.Ecto.Binary` per the Cloak documentation. The `mix cloak.migrate.ecto` step (for re-encrypting existing rows on key rotation) is not needed because the table is brand-new — confirmed by the `apply-progress.md` §"Decisions / deviations" item 6. |
| Unique index correctness | ✅ The index uses the Ecto standard form `create unique_index(:foundation_bot_configs, [:env], name: :foundation_bot_configs_env_unique)`. The schema enforces uniqueness via `unique_constraint(:env)` in the changeset. |
| `null: false` constraint on `bot_username` | ✅ Verified at `priv/repo/migrations/20260616145733_create_foundation_bot_configs.exs:35`. This is the structural fact that makes the W-2 integration test (against `{:unexpected, _}`) infeasible: a `BotConfig` row with `bot_username: nil` cannot be inserted under the migration's constraints without an `ALTER TABLE` that conflicts with the Ecto sandbox's lock. |
| Follow-up did NOT add or modify any migration | ✅ Verified: `git diff main..HEAD -- priv/repo/migrations/` shows the same single migration file as the original PR. |

**Migration is safe.**

---

## 11. Naming & Conventions

| Module / File | Convention | Compliance |
|---|---|---|
| `Alethea.Foundation.Accounts.BotConfig` | `Alethea.Foundation.Accounts.*` for foundation data | ✅ |
| `Alethea.Telegram.ChatIdHash` | `Alethea.Telegram.*` for telegram-specific | ✅ |
| `Alethea.Telegram.BotToken` | `Alethea.Telegram.*` for telegram-specific | ✅ |
| `test/alethea/telegram/chat_id_hash_test.exs` | `<module>_test.exs` | ✅ |
| `test/alethea/foundation/accounts/bot_config_test.exs` | `<module>_test.exs` | ✅ |
| `test/alethea/telegram/bot_token_test.exs` | `<module>_test.exs` | ✅ |
| `priv/repo/migrations/20260616145733_create_foundation_bot_configs.exs` | `YYYYMMDDHHMMSS_create_<table>.exs` (per AGENTS.md) | ✅ |
| `Alethea.Encryption.Binary` (the type alias) | The existing project type alias for `Cloak.Ecto.Binary, vault: Alethea.Encryption.Vault` | ✅ (reused, not modified) |
| `BotToken.reason_tag/1` (new, public) | Whitelist helper, public for testability | ✅ (intentional API surface; the test relies on this) |
| `BotToken.do_reload/0` (new, private) | Internal refactor for DRY (S-4) | ✅ |
| `BotToken.log_and_reset/1` (new, private) | Internal W-1 helper | ✅ |

---

## 12. Out-of-Scope Requirements (intentionally not in PR #1a)

| REQ ID | Lands in |
|---|---|
| `REQ-C2-chat-id-stored-as-hmac` (DB-rename half) | PR #2 (TASK-2-1) |
| `REQ-C2-lookup-by-hash` (all 3 scenarios) | PR #2 (TASK-2-1) |
| `REQ-C2-partial-unique-index` (all 3 scenarios) | PR #2 (TASK-2-1) |
| `REQ-C2-no-plaintext-in-logs` (webhook + worker scenarios) | PR #3b (TASK-3b-5) / PR #4 |
| All of C-1 (webhook, plug, controllers) | PR #2 |
| All of C-3 (message worker, idempotency) | PR #3a |
| All of C-4 (deep-link, 6-digit) | PR #1b (mint/verify) + PR #4 (persistence + consume) |
| All of C-5 (clinical round-trip) | PR #3a (safe) + PR #3b (crisis) |
| All of C-7 (Pacer, rate-limit, dead-letter) | PR #1b (Pacer) + PR #3a (429/dead-letter) + PR #3b (crisis lane) |

All 35 REQ-C*-* IDs in `tasks.md` §"REQ-C*-* Distribution Map" are present in at least one slice. **No REQ is orphaned.** PR #1a is the first child of the tracker and ships 5 of the 35 REQ halves.

---

## 13. Final Verdict

**PASS** (re-verified after the 2 WARNING fixes).

- 0 CRITICAL findings
- 0 WARNING findings (W-1 and W-2 both RESOLVED)
- 3 SUGGESTION carryovers (S-2, S-3, S-5 — all non-blocking stylistic / test-coverage improvements; 2 of the 5 from the original report were resolved by the follow-up batch: S-1 and S-4)
- All in-scope requirements implemented with meaningful, passing tests
- The 2 WARNING fixes ALSO added 5 new tests (+3 for W-1, +2 for W-2), all passing
- `mix precommit` is green (exit code 0; 324 tests, 0 failures, 5 skipped; 0 new warnings introduced)
- No plaintext leakage detected — verified at the source level (`inspect/1` only in comments documenting the W-2 fix) and at the runtime level (W-1 tests assert `refute log =~ "live-token"`)
- All 7 deviations are defensible / accepted; the W-2 integration test deviation is documented and substituted with a substantive unit test
- Migration is safe and unchanged by the follow-up
- Naming and conventions are correct
- The follow-up is a pure WARNING-resolution patch: no new modules, no new public APIs, no new code paths beyond `do_reload/0` (private) and `log_and_reset/1` (private) and `reason_tag/1` (public, intentionally — needed for testability)

**Next step:** `sdd-apply PR #1b` (after PR #1a is merged), per the chain topology in `tasks.md` §"Chain Topology".

---

## Re-verification Delta (2026-06-16)

This re-verification was triggered by the 2 follow-up commits on top of the original 6:
- `f0c878f` — `fix(telegram): log reload failures with whitelist reason tag` (W-1)
- `010ae20` — `fix(telegram): whitelist reason tag in init/1 Logger.error (W-2)`
- `4f66012` — `style: format BotToken @spec lines` (drive-by, no functional change)

### What was checked

1. **W-1 fix verification** — confirmed:
   - `log_and_reset/1` private function exists at L201-214 with `Logger.error` + state reset to nil
   - `do_reload/0` private function exists at L169-174 (S-4 also addressed)
   - Both `handle_cast(:reload)` (L137) and `handle_info(:reload)` (L140) are now one-liners calling `do_reload/0`
   - 2 new tests cover the failure path: info path (L172-218) and cast path (L220-261)
   - Each test asserts: log message present + env tag + `:not_found` whitelist tag + state reset to nil + GenServer still alive + NO plaintext token in log
   - Option A (Log + reset) is the right choice: matches the project's runtime GenServer pattern (`Alethea.WhatsApp.ConsentCache`, `Alethea.RateLimiter`) where boot is the only `log+raise` site

2. **W-2 fix verification** — confirmed:
   - No `inspect/1` call in any log path (the 3 `inspect` mentions in the file are all in comments documenting the fix)
   - `reason_tag/1` public function exists at L153-156 with the exact 3-branch whitelist: `:not_found` → `":not_found"`, `{:unexpected, _}` → `":unexpected"`, `_` → `"other"`
   - Unit test at L285-320 covers all 3 branches with a sensitive-payload assertion (the tag does NOT contain the struct's fields)
   - `init/1` (L123) and `log_and_reset/1` (L208) both use `reason_tag/1` — consistency confirmed
   - Regression test at L322-343 pins the `init/1` log format for the `:not_found` case

3. **Deviation verification** — confirmed:
   - The migration at `priv/repo/migrations/20260616145733_create_foundation_bot_configs.exs:35` has `null: false` on `bot_username` — verified
   - The Ecto sandbox lock conflict is real and documented in the Ecto / PostgreSQL documentation — the integration test would deadlock
   - The unit test on `reason_tag/1` is a substantive substitute: it directly tests the whitelist logic (the actual code change)
   - **Deviation accepted**

4. **Regression check** — confirmed:
   - `mix precommit` is GREEN: 324 tests, 0 failures, 5 skipped; exit code 0
   - All 319 original tests still pass (319 → 324 = +5 new)
   - 0 new warnings introduced by the follow-up
   - The 2 pre-existing warnings (`unused alias EmotionAnalysisWorker`, `variable "call_count" is unused`) are in `test/alethea_jobs/` files that are unchanged by this PR (verified by `git diff main..HEAD -- test/alethea_jobs/ lib/alethea_jobs/`)

5. **No new CRITICAL or WARNING** — confirmed:
   - The follow-up only added private helpers (`do_reload/0`, `log_and_reset/1`) and one public function (`reason_tag/1`, intentionally public for testability)
   - No new modules, no new files, no new public APIs
   - No new code paths that touch the C-2 / C-6 specs in a way that would introduce a new finding
   - The 5 SUGGESTIONs from the original report: 2 (S-1, S-4) resolved by the follow-up, 3 (S-2, S-3, S-5) remain as non-blocking SUGGESTIONs

### Re-verification verdict

**PASS** — the PR is clean to merge. No blockers, no regressions, no new findings.

---

## Appendix A — Strict TDD Evidence (from `apply-progress.md`)

| Task | RED (test written) | GREEN (impl passes) | REFACTOR (clean) | Commit SHA | Notes |
|---|---|---|---|---|---|
| TASK-1a-1 | ✅ 8/8 fail (module not defined) | ✅ 8/8 pass | ✅ removed dead "expected \|\| true" doctest placeholder, split the "known-good HMAC vector" into a single `:crypto.mac`-backed test | `9c0eb17` | Pure helper, no deps. Uses `:crypto.mac(:hmac, :sha256, pepper, chat_id)`. |
| TASK-1a-2 | ✅ 13/13 fail (compile error, module not defined) | ✅ 13/13 pass | ✅ switched to `:source` rebinding so logical field names are the schema API and the DB columns hold the ciphertext; `upsert/1` is SELECT-then-INSERT-or-UPDATE; `:binary.match` assertion uses `== :nomatch` (atoms are truthy) | `1d5552b` | Migration + schema + context. `Alethea.Encryption.Binary` is the existing `Cloak.Ecto.Binary` type bound to the existing `Alethea.Encryption.Vault`. |
| TASK-1a-3 | ✅ 6/6 fail (`BotToken.stop/0` not defined) | ✅ 6/6 pass | ✅ added a test-only `stop/0` helper; `init/1` raises with Logger.error + clear message; `handle_cast(:reload)` mirrors `handle_info(:reload)` | `4b6fe4c` | GenServer, fail-loud on missing row. Uses `Ecto.Adapters.SQL.Sandbox.allow/3` in test setup. |
| TASK-1a-4 | n/a (infra) | n/a (infra) | n/a (infra) | `060d1fc` | Added `Alethea.Telegram.BotToken` to the supervision tree; gated on `:start_bot_token` config (default `true` in dev/prod, `false` in test). |
| **W-1 follow-up** | ✅ 2/2 fail (no `Logger.error` fired → `capture_log` returned `""`) | ✅ 2/2 pass | ✅ Extracted `do_reload/0` (DRY, S-4); renamed the success-path describe block and split into cast + info tests; both paths covered | `f0c878f` | Option A chosen (Log + reset). 3 net new tests: 2 failure-path (info + cast) + 1 info-path success (replaces the original 1, adds coverage). |
| **W-2 follow-up** | ⚠️ (see §7 deviation 7) | ✅ 2/2 pass (unit + regression) | ✅ Reused the W-1 `log_and_reset/1` whitelist by routing both call sites through `reason_tag/1` (DRY) | `010ae20` | The integration test called out in the instruction is not feasible (Ecto sandbox lock conflict on `ALTER TABLE`). The unit test on `reason_tag/1` is the substance of the fix. |
| **Style fix** | n/a | n/a | n/a (format only) | `4f66012` | `mix format` split long `@spec` lines onto multiple lines. No functional change. |

All TDD evidence verified against the actual code and the running test suite.

---

## Appendix B — Commit history (chronological, on this branch)

```
4f66012 style: format BotToken @spec lines                    (drive-by, no functional change)
010ae20 fix(telegram): whitelist reason tag in init/1 Logger.error (W-2)
f0c878f fix(telegram): log reload failures with whitelist reason tag
3d85263 docs(apply): record PR #1a TDD evidence and decisions
27fc89b style: format BotConfig test
060d1fc chore(app): supervise BotToken GenServer
4b6fe4c feat(telegram): add BotToken GenServer accessor
1d5552b feat(telegram): add BotConfig schema with env discriminator
9c0eb17 feat(telegram): add chat id hash HMAC helper
7b891bf chore(openspec): archive bootstrap-alethea-v2 (verified PASS) (#71)  ← base
```

**3 follow-up commits** on top of the original 6:
- `f0c878f` — W-1 fix (+3 tests)
- `010ae20` — W-2 fix (+2 tests)
- `4f66012` — `mix format` style fix (no functional change)
