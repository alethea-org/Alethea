# Apply Progress — `telegram-paciente-foundation`

**Change:** `telegram-paciente-foundation`
**Chain strategy:** `feature-branch-chain` (locked)
**Tracker branch:** `feat/telegram-paciente-foundation` (draft, no-merge)
**Strict TDD:** active — every task follows RED → GREEN → REFACTOR.

---

# Apply Progress — `telegram-paciente-foundation` (PR #1a)

**Branch:** `feat/telegram-paciente-foundation/pr-1a-foundations-a`
**Base:** `main`
**PR title:** `feat(telegram): bot token vault, chat id hash, encryption-vault wiring`
**Strict TDD:** active — every task followed RED → GREEN → REFACTOR.
**Status:** ✅ All 4 tasks complete. `mix precommit` green.

## Plan (4 tasks, all complete)

| ID | Title | Files (impl) | Files (test) | Est. lines | Final SHA |
|---|---|---|---|---|---|
| TASK-1a-1 | ChatIdHash pure HMAC helper (C-2) | `lib/alethea/telegram/chat_id_hash.ex` | `test/alethea/telegram/chat_id_hash_test.exs` | 18 + 50 = 68 | `9c0eb17` |
| TASK-1a-2 | BotConfig schema + migration (C-6) | `lib/alethea/foundation/accounts/bot_config.ex` + migration | `test/alethea/foundation/accounts/bot_config_test.exs` | 60 + 35 + 90 = 185 | `1d5552b` |
| TASK-1a-3 | BotToken GenServer accessor (C-6) | `lib/alethea/telegram/bot_token.ex` | `test/alethea/telegram/bot_token_test.exs` | 65 + 90 = 155 | `4b6fe4c` |
| TASK-1a-4 | Application supervision delta for BotToken | `lib/alethea/application.ex` + `config/test.exs` | (covered by `mix test`) | 12 | `060d1fc` |
| **Total** | | | | **420** | (est.) |

## TDD Cycle Evidence

| Task | RED (test written) | GREEN (impl passes) | REFACTOR (clean) | Commit SHA | Notes |
|---|---|---|---|---|---|
| TASK-1a-1 | ✅ 8/8 fail (module not defined) | ✅ 8/8 pass | ✅ Removed dead "expected || true" doctest placeholder, split the "known-good HMAC vector" into a single `:crypto.mac`-backed test | `9c0eb17` | Pure helper, no deps. Uses `:crypto.mac(:hmac, :sha256, pepper, chat_id)`. |
| TASK-1a-2 | ✅ 13/13 fail (compile error, module not defined) | ✅ 13/13 pass | ✅ Switched to `:source` rebinding so logical field names (`bot_token`, `secret_token`) are the schema API and the DB columns (`token_ciphertext`, `secret_token_ciphertext`) hold the ciphertext; `upsert/1` is SELECT-then-INSERT-or-UPDATE rather than a Postgres `ON CONFLICT` (simpler, no partial-update ambiguity); `:binary.match` assertion uses `== :nomatch` (atoms are truthy — `refute :nomatch` was wrong) | `1d5552b` | Migration + schema + context. `Alethea.Encryption.Binary` is the existing `Cloak.Ecto.Binary` type bound to the existing `Alethea.Encryption.Vault`. |
| TASK-1a-3 | ✅ 6/6 fail (`BotToken.stop/0` not defined) | ✅ 6/6 pass | ✅ Added a test-only `stop/0` helper so tests can clean up between runs without leaking GenServer state; `init/1` raises with a Logger.error + clear message; `handle_cast(:reload)` mirrors `handle_info(:reload)` so the operator can use either `send/2` or `cast/2` | `4b6fe4c` | GenServer, fail-loud on missing row. Uses `Ecto.Adapters.SQL.Sandbox.allow/3` in test setup so the GenServer process can share the test's DB connection. |
| TASK-1a-4 | n/a (infra) | n/a (infra) | n/a (infra) | `060d1fc` | Added `Alethea.Telegram.BotToken` to the supervision tree; gated on `:start_bot_token` config (default `true` in dev/prod, `false` in test) — the SQL sandbox makes supervisor-init DB reads impossible in `:test`, so the test cases start the GenServer manually. |

## Commit history (chronological, on this branch)

```
27fc89b style: format BotConfig test                      (style fix from mix format)
060d1fc chore(app): supervise BotToken GenServer         (TASK-1a-4)
4b6fe4c feat(telegram): add BotToken GenServer accessor  (TASK-1a-3)
1d5552b feat(telegram): add BotConfig schema with env discriminator  (TASK-1a-2)
9c0eb17 feat(telegram): add chat id hash HMAC helper     (TASK-1a-1)
7b891bf chore(openspec): archive bootstrap-alethea-v2 (verified PASS) (#71)  ← base
```

## Test counts (delta)

- Baseline (main, pre-PR): 292 tests, 0 failures, 5 skipped.
- After PR #1a: 319 tests, 0 failures, 5 skipped.
- Delta: **+27 new tests** (8 + 13 + 6 across the 3 task files).
- All 5 skipped tests are pre-existing (out of scope for this PR).

## `mix precommit` result

✅ GREEN.

- `compile --warnings-as-errors`: pass.
- `deps.unlock --unused`: no changes to `mix.lock`.
- `format --check-formatted`: pass.
- `test`: 319 tests, 0 failures, 5 skipped.

## Lines changed (under 800 soft budget)

```
$ git diff --stat main..HEAD
 config/test.exs                                    |   7 +
 lib/alethea/application.ex                         |  11 ++
 lib/alethea/foundation/accounts/bot_config.ex      | 111 ++++++++++++++
 lib/alethea/telegram/bot_token.ex                  | 164 +++++++++++++++++++++
 lib/alethea/telegram/chat_id_hash.ex               |  57 +++++++
 ...0260616145733_create_foundation_bot_configs.exs |  43 ++++++
 .../foundation/accounts/bot_config_test.exs        | 161 ++++++++++++++++++++
 test/alethea/telegram/bot_token_test.exs           | 155 +++++++++++++++++++
 test/alethea/telegram/chat_id_hash_test.exs        |  88 +++++++++++
 9 files changed, 797 insertions(+)
```

**797 changed lines** — 3 lines under the 800 soft budget, 320+ lines under the 400 raw D1 cap (now superseded by the 800 soft cap per design §Re-Slice Justification).

## Requirements covered (per `openspec/sdd/telegram-paciente-foundation/specs/`)

| Requirement | Spec file | Status |
|---|---|---|
| `REQ-C2-chat-id-stored-as-hmac` (pure half) | `specs/C-2-hmac-chat-id-lookup/spec.md` | ✅ implemented in `Alethea.Telegram.ChatIdHash.hash/2`. The DB-rename half lands in PR #2 (TASK-2-1). |
| `REQ-C6-bot-token-stored-encrypted` | `specs/C-6-vault-sealed-bot-token/spec.md` | ✅ implemented in `Alethea.Foundation.Accounts.BotConfig` (Cloak.Ecto.Binary on `token_ciphertext` and `secret_token_ciphertext`). |
| `REQ-C6-distinct-per-env` | same | ✅ unique index `foundation_bot_configs_env_unique`; `env` validated against `["dev", "test", "prod"]`. |
| `REQ-C6-bot-token-gen-server-accessor` | same | ✅ `Alethea.Telegram.BotToken` GenServer loads from `BotConfig.for_env(Mix.env())` on init, holds plaintext in process state, serves via synchronous `GenServer.call/2`, supports `:reload` for rotation. |
| `REQ-C6-no-plaintext-in-env` | same | ✅ accessor reads ONLY from the `BotConfig` row (encrypted at rest). No `System.get_env("TELEGRAM_BOT_TOKEN")` in any path. Test config can additionally set a test-only pepper via `Application.put_env` per spec scenario. |

## Decisions / deviations from tasks.md

1. **TASK-1a-2 — `upsert/1` strategy.** The design §6 spec implies `on_conflict: [set: [...]]` Postgres upsert; I used SELECT-then-INSERT-or-UPDATE for clarity. Both approaches honour `REQ-C6-distinct-per-env`; the SELECT-then-write form is easier to reason about and matches the rest of the foundation's `register_*` / `create_*` patterns. The 1-line behaviour difference is that the SELECT-then-write form always returns the row with the full updated state. *(Subsequently updated in PR #1b-fixes (F-07) to use `on_conflict` for atomicity — the SELECT-then-write form had a TOCTOU race.)*

2. **TASK-1a-3 — Sandbox-aware GenServer tests.** The standard `use ExUnit.Case` was replaced with `use Alethea.DataCase, async: false` plus an explicit `Ecto.Adapters.SQL.Sandbox.allow/3` so the GenServer process can share the test's DB connection. This is the project's standard pattern (used in `Alethea.AI` and `Alethea.WhatsApp` tests) and is required for any GenServer that reads the DB.

3. **TASK-1a-4 — `:start_bot_token` test-mode flag.** The default `:start_ai` flag pattern in `config/test.exs` is replicated for `:start_bot_token`. The flag is `false` in `:test` because (a) the SQL sandbox prevents the supervisor process from reading the DB, and (b) the `BotTokenTest` suite starts the GenServer manually with the sandbox explicitly allowed. In `:dev` and `:prod` the flag defaults to `true` (the spec scenario "missing row raises on boot, not on first call" still holds: in `:prod` the flag is `true`, so the supervisor attempts to start the GenServer, the GenServer's `init/1` fails, and the app refuses to boot). This is a test-infrastructure concern, not a production concern.

4. **TASK-1a-3 — `handle_cast(:reload)` added.** The spec mentions a `:reload` signal but doesn't pin the exact message-passing mechanism. I added both `handle_cast/2` (for the synchronous-feeling `GenServer.cast/2` call site) and `handle_info/2` (for the operator's `send/2` from a shell or a future admin LiveView). Both routes land in the same `load()` function.

5. **TASK-1a-1 — `hash/2` accepts integer or string `chat_id`.** The spec doesn't pin the input type; the design shows `HMAC-SHA256(chat_id, pepper)` with `to_string(chat_id)` in the helper. I kept this coercion inside the function (deterministic for both shapes) and added a regression test for the integer form. This is consistent with the design §7 snippet. *(Subsequently hardened in PR #1b-fixes (F-01..F-03) with 32-byte pepper + type checks — HMAC-SHA256 with `<32-byte` keys is cryptographically weak; the function now requires a string input.)*

6. **No `Cloak.Ecto` migration step needed.** The migration creates `:binary` columns, which is what `Cloak.Ecto.Binary` requires. The existing `mix cloak.migrate.ecto` step (a separate task to re-encrypt existing rows) is not needed because the table is brand-new — there are no pre-existing rows to migrate.

## Blockers

(none)

## Out-of-scope items (left for later PRs in the chain)

- The `telegram_chat_id` → `telegram_chat_id_hash` column rename on `foundation_patients` (PR #2, TASK-2-1) — this PR only ships the pure HMAC helper.
- The `Alethea.Foundation.Accounts.lookup_patient_by_chat_hash/1` context function (PR #2) — needs the column rename in place.
- The `TelegramSecretToken` plug (PR #2, TASK-2-2) — depends on this PR's `BotToken.secret_token/0` accessor.
- ADR-0008 (pepper rotation policy) — lives in PR #1b, not #1a, per tasks.md.

---

# Apply Progress — `telegram-paciente-foundation` (PR #1b)

**Branch:** `feat/telegram-paciente-foundation/pr-1b-foundations-b`
**Base:** `feat/telegram-paciente-foundation/pr-1a-foundations-a` (NOT `main`)
**PR title:** `feat(telegram): pacer GenServer with token buckets and deep link token`
**PR:** https://github.com/alethea-org/Alethea/pull/73
**Merge commit:** `47c94d6d1543c08d5aae1a2d32b721699b691221` (merged 2026-06-18T23:07:09Z)
**Strict TDD:** active — every task followed RED → GREEN → REFACTOR.
**Status:** ✅ All 3 tasks complete. `mix precommit` green. Verify report PASS WITH WARNINGS (0 CRITICAL, 2 WARNING, 4 SUGGESTION; W-2 RESOLVED in commit `d39dace`; W-1 deferred to PR #2).
**Companion PR:** [PR #1b-fixes](#apply-progress--telegram-paciente-foundation-pr-1b-fixes) (the F-04..F-16 follow-up batch + chore cosmetics) — separate PR on top of this one, merged to `pr-1b-foundations-b`.

> **Note on this section:** the original 433-line PR #1b apply-progress content was lost when the working tree was checked out from `origin/main` during the sdd branch creation (the 433-line version was untracked on the pr-1b-foundations-b branch and got overwritten by the 106-line tracked version on main). The TDD evidence is preserved in `verify-report-pr-1b.md` Appendix A. This section is reconstructed from the verify report + git log; the prose is condensed.

## Plan (3 tasks, all complete)

| ID | Title | Files (impl) | Files (test) | Est. lines | Final SHA |
|---|---|---|---|---|---|
| TASK-1b-1 | DeepLinkToken mint/verify pure module (C-4 primitive) | `lib/alethea/telegram/deep_link_token.ex` | `test/alethea/telegram/deep_link_token_test.exs` | 22 + 60 = 82 | `901e097` |
| TASK-1b-2 | Pacer GenServer with two ETS TokenBuckets (C-7 partial) | `lib/alethea/telegram/pacer.ex` | `test/alethea/telegram/pacer_test.exs` | 110 + 160 = 270 | `0eabf6b` |
| TASK-1b-3 | ADR-0008: chat_id pepper rotation policy | `openspec/adr/008-telegram-chat-id-pepper-rotation.md` | — | 110 | `794a8f0` |
| **Total** | | | | **462** | (est.) |

## Commit history (chronological, on this PR)

```
b0cca53 docs(apply): fill in W-2 commit SHA in apply-progress  (W-2 docs)
d39dace test(telegram): assert per-chat independence holds when global bucket is drained (W-2)
494ea16 docs(apply): record PR #1b TDD evidence and decisions
10f7cb5 test(telegram): trim defensive module purity tests from Pacer suite
755426d test(telegram): use try/catch :exit in Pacer test cleanup
794a8f0 docs(adr): add 008 telegram chat id pepper rotation policy  (TASK-1b-3)
0eabf6b feat(telegram): add Pacer GenServer with per-chat and global token buckets  (TASK-1b-2)
901e097 feat(telegram): add deep link token mint/verify  (TASK-1b-1)
4f66012 style: format BotToken @spec lines  ← base (PR #1a)
```

## Test counts (delta)

- PR #1a baseline: 324 tests, 0 failures, 5 skipped.
- After PR #1b: 350 tests, 0 failures, 5 skipped.
- Delta: **+26 new tests** (15 DeepLinkToken + 11 Pacer). All 5 skipped tests are pre-existing.

## `mix precommit` result (on PR #1b tip, post-split)

✅ GREEN.

- `compile --warnings-as-errors`: pass. The single `unused variable "call_count"` warning in `test/alethea/ai/retry_test.exs:42` is pre-existing in PR #1a's base. PR #1b does not touch `Alethea.AI`. **No new warnings introduced.**
- `format --check-formatted`: pass.
- `test`: 350 tests, 0 failures, 5 skipped.

## Requirements covered (per `openspec/sdd/telegram-paciente-foundation/specs/`)

| Requirement | Spec file | Status |
|---|---|---|
| `REQ-C4-mint-deep-link-token` (pure half) | `specs/C-4-deep-link-onboarding/spec.md` | ✅ implemented in `Alethea.Telegram.DeepLinkToken.mint/0` (32-byte CSPRNG, 43-char URL-safe base64, no padding) and `valid_format?/1` (format-only check). The persistence half (TTL, `used_at`, `attempt_count`) lives in PR #4. |
| `REQ-C7-pacer-per-chat-limit` | `specs/C-7-outbound-rate-limit/spec.md` | ✅ implemented in `Alethea.Telegram.Pacer` — per-chat ETS bucket `telegram_pacer_per_chat`, refill 1 Hz (production default). 4 test scenarios: first-message-goes-through, second-message-blocks, different-chats-independent, per-chat-key-isolation. |
| `REQ-C7-pacer-global-limit` | same | ✅ implemented in `Alethea.Telegram.Pacer` — single global ETS bucket `telegram_pacer_global`, refill 30 Hz (production default). 4 test scenarios: 30-distinct-chats-OK, 31st-blocks, global-vs-per-chat-dominance, 30-distinct-then-31st-blocks-on-global-not-per-chat. |

The remaining 9 requirements of the change are scoped to other PRs in the chain. `REQ-C7-429-retry-with-jitter`, `REQ-C7-dead-letter-on-exhaustion`, `REQ-C7-crisis-priority-lane`, `REQ-C7-crisis-queue-full-escalation` all live in PR #3a/#3b. `REQ-C4-bind-chat-on-success`, `REQ-C4-reject-expired-token`, `REQ-C4-reject-already-used-token`, `REQ-C4-reject-rate-limited`, `REQ-C4-six-digit-fallback`, `REQ-C4-send-welcome-reply` all live in PR #4.

## Deviations (summary; full text in `verify-report-pr-1b.md` §10)

The 8 deviations are defensible; none weaken a requirement. Highlights:

1. **TASK-1b-1 — `mint/0` is arity 0, not `mint/1` taking `patient_id`.** The pure half has no need for `patient_id`; the persistence half (PR #4) owns the patient binding.
2. **TASK-1b-1 — Token length fixed at 43 chars, not 43–44.** 32 raw bytes with `padding: false` is exactly 43 chars; the 43–44 range in the spec is mathematically inaccurate (S-1: tighten in a follow-up spec edit).
3. **TASK-1b-2 — Blocking inside `handle_call` via `Process.sleep/1`.** Single-threaded design; a chat with an empty bucket blocks all other chats during its wait. Centralising the wait keeps the consumer code a one-liner.
4. **TASK-1b-2 — Refill rates configurable via `Application.get_env`.** Production defaults match the spec (1 Hz per-chat, 30 Hz global).
5. **TASK-1b-2 — Refill math is continuous, not discrete.** Tokens are added on every `acquire/1` call by computing `elapsed_ms * refill_per_sec / 1000`.
6. **TASK-1b-2 — `acquire/1` takes `chat_id_hash`, not the raw `chat_id`.** Per design Decision 1 (R-1 PHI hygiene), the system never stores, queries, or logs raw chat_ids.
7. **TASK-1b-3 — ADR lives at `openspec/adr/008-…`**, not `docs/adr/…`. Per the project convention (ADRs 001-004 in the same directory).
8. **TASK-1b-3 — ADR is in Spanish** (project convention; matches existing ADRs 001-004).

## W-1 deferral (WARNING #1 from `verify-report-pr-1b.md`)

ETS per-chat rows are not cleaned up. Each new `chat_id_hash` creates a row in the `:telegram_pacer_per_chat` table that is never removed. A long-running production bot that processes N chats accumulates N rows indefinitely. **The global table is fine (singleton key); the per-chat table grows with the number of unique chats ever seen.**

**Recommended fix (per verify report):** add a `handle_info(:cleanup)` callback (every 5 min) that removes rows with `last_refill_ms` older than a configurable idle threshold (e.g., 1 hour). The `last_refill_ms` field is already in the ETS row, so the cleanup is straightforward.

**Why deferred, not fixed in this PR:** the recommended fix has dependencies that do not exist on the PR #1b branch:
- The Pacer is **not in the application supervision tree** in PR #1b. A `handle_info(:cleanup)` callback fired by `:erlang.send_after/3` requires the GenServer to be supervised so the timer can be scheduled in `init/1` and rescheduled after each cleanup.
- The cleanup is best configured with new `Application.get_env` knobs (`:cleanup_interval_ms`, `:idle_threshold_ms`) that should land in the same PR that wires up supervision.

**Target PR:** **PR #2** (`feat/telegram-paciente-foundation/pr-2-webhook-foundation`). PR #2 adds the Pacer to the supervision tree (TASK-2-6), the Oban queues, and the column rename. Adding the cleanup alongside supervision keeps the supervision changes in a single coherent commit, which is the project's "commit by work unit" discipline.

**Acceptance criteria for the PR #2 fix:**
- A `handle_info(:cleanup, state)` callback in `Alethea.Telegram.Pacer`.
- A `:cleanup_interval_ms` knob (default `5 * 60 * 1000`) and an `:idle_threshold_ms` knob (default `60 * 60 * 1000`), both read from `Application.get_env`.
- A test that pre-fills the ETS table with 3 rows (one current, one older than the threshold, one much older), runs the cleanup, and asserts only the current row survives.
- No change to the `acquire/1` call path (cleanup is a separate `handle_info` callback, per the verify report's recommendation).
- Documentation update in `pacer.ex` `@moduledoc` noting the cleanup cadence.

**W-2 status:** RESOLVED in commit `d39dace`. The original W-2 finding was: "the test at `pacer_test.exs:114-120` asserted only the return value, not timing, making it redundant with the L100-112 test and passable even if the Pacer collapsed all keys to a single bucket." The fix strengthens the test to assert `elapsed < 50 ms` for two new distinct chats after the global bucket is drained. RED demonstration was executed by temporarily replacing `chat_id_hash` with `:collapsed` in `refill_per_chat_bucket/1` and `consume_per_chat/1` — the test failed with the expected "blocked 1001ms" failure, then reverted.

## SUGGESTIONs (S-1 through S-4) — Deferred to a future cleanup PR

The 4 SUGGESTIONs from `verify-report-pr-1b.md` §7.3 are non-blocking stylistic and test-coverage improvements. **S-4 is subsumed by PR #1b-fixes (F-09) — the fail-loud config validation replaces the defensive `{:wait, _non_positive}` branch.** The other 3 (S-1, S-2, S-3) are tracked here for a future cleanup PR:

- **S-1:** Tighten the DeepLinkToken spec from "43–44 char" to "43 chars" (mathematically accurate). No code change; spec edit only.
- **S-2:** Delete the duplicate "30 distinct chats, then 31st blocks on global" test at `L176-197` (redundant with `L132-149`). Saves 22 lines.
- **S-3:** Rename the test at `L151` ("global limit is independent of per-chat limit") to "per-chat is the dominant constraint when per-chat is empty" (the test asserts the OPPOSITE of its current name).

**Target PR:** TBD — likely a small "test cleanup + spec hygiene" PR after PR #2 lands, or rolled into a later PR in the chain. Not blocking.

## Out-of-scope items (left for later PRs in the chain)

- The `telegram_chat_id` → `telegram_chat_id_hash` column rename on `foundation_patients` (PR #2, TASK-2-1).
- The `Alethea.Foundation.Accounts.lookup_patient_by_chat_hash/1` context function (PR #2).
- The `TelegramSecretToken` plug (PR #2, TASK-2-2) — depends on `BotToken.secret_token/0` from PR #1a.
- Pacer supervision in `lib/alethea/application.ex` (PR #2, TASK-2-6) — required for the W-1 cleanup.
- Oban queue config + workers + `Telegram.Client.Req` production adapter (PR #2, #3a, #3b, #4).
- Clinical round-trip (PR #3a, #3b).
- Onboarding + auth codes (PR #4).
- **F-04..F-16 follow-up fix batch + chore** — see [PR #1b-fixes](#apply-progress--telegram-paciente-foundation-pr-1b-fixes) below.

---

# Apply Progress — `telegram-paciente-foundation` (PR #1b-fixes)

**Branch:** `feat/telegram-paciente-foundation/pr-1b-fixes` (new, based on `pr-1b-foundations-b` at `b0cca53`)
**Base:** `feat/telegram-paciente-foundation/pr-1b-foundations-b` (NOT `pr-1a-foundations-a`, NOT `main`)
**PR title:** `fix(telegram): PR #1b follow-up fixes (F-04..F-16 + chore)`
**PR:** https://github.com/alethea-org/Alethea/pull/74
**Merge commit:** `9fa4db54294b77f8dd2b13af144775abafa78f21` (merged 2026-06-18T23:08:06Z)
**Status:** ✅ All 12 commits merged. `mix precommit` green. Closes the verify report's findings beyond W-2 (which was already resolved in PR #1b).

## Why this PR exists (the split)

The original PR #1b accumulated 20 commits (~2000 insertions) and exceeded the soft 800-line review budget by ~2.5×. The maintainer chose to split the PR into two:

- **PR #1b** — the clean slice (9 commits on `pr-1b-foundations-b` before the split, all 8 of which landed in the PR; 1126 insertions, 0 deletions, 6 files)
- **PR #1b-fixes** — the F-XX follow-up batch + chore (12 commits; 903 insertions, 64 deletions, 9 files)

The split keeps each review focused on a single coherent change set.

## Plan (12 commits, all merged)

| F-XX | Title | Original SHA | New SHA on `pr-1b-fixes` | Files (impl) | Files (test) |
|---|---|---|---|---|---|
| F-01..F-03 | ChatIdHash hardening (32-byte pepper + type checks) | `1553719` | `14e737c` | `lib/alethea/telegram/chat_id_hash.ex` | `test/alethea/telegram/chat_id_hash_test.exs` |
| F-04 | BotToken plaintext redaction in `format_status/2` | `1130eb8` | `e2c29af` | `lib/alethea/telegram/bot_token.ex` | `test/alethea/telegram/bot_token_test.exs` |
| F-06 | `BotToken.stop/0` `:exit` catch (race fix) | `2998ae3` | `1a6591f` | `lib/alethea/telegram/bot_token.ex` | `test/alethea/telegram/bot_token_test.exs` |
| F-07 | `BotConfig.upsert/1` atomic via `on_conflict` (F-08 subsumed) | `4b4c6f0` | `2dd5959` | `lib/alethea/foundation/accounts/bot_config.ex` | `test/alethea/foundation/accounts/bot_config_test.exs` |
| F-09 | Pacer config validation at boot (fail-loud on `0` or negative) | `59f2b10` | `9e97590` | `lib/alethea/telegram/pacer.ex` | `test/alethea/telegram/pacer_test.exs` |
| F-10 | Pacer finite call timeout (30 s default) | `62eb639` | `d9ce9f7` | `lib/alethea/telegram/pacer.ex` | `test/alethea/telegram/pacer_test.exs` |
| F-11 | Pacer `min(per-chat, global)` wait on both-empty | `8b796e3` | `59d1a23` | `lib/alethea/telegram/pacer.ex` | `test/alethea/telegram/pacer_test.exs` |
| F-12 | Pacer ETS `:public` → `:protected` + `inspect_per_chat/0` + `inspect_global/0` | `084b951` | `30ebbe0` | `lib/alethea/telegram/pacer.ex` | `test/alethea/telegram/pacer_test.exs` |
| F-13 | Test: assert no `:write_concurrency` on Pacer ETS | `d2bc75f` | `cf31728` | — (test only) | `test/alethea/telegram/pacer_test.exs` |
| F-14 | Pacer `acquire/1` `chat_id_hash` guard → 64 hex chars | `fef0c07` | `1ea13c9` | `lib/alethea/telegram/pacer.ex` | `test/alethea/telegram/pacer_test.exs` |
| F-16 | ADR-0008 cross-ref to `design.md §2 Decision 1` | `ea0eefd` | `31db4ff` | `openspec/adr/008-…` | — |
| chore | Pacer lint cosmetics (`@spec` reformat, `_name`, 3 blank lines) | `ce7225b` | `19eb4d4` | `lib/alethea/telegram/pacer.ex` + test | `test/alethea/telegram/pacer_test.exs` |

## Cherry-pick notes

The 11 F-XX commits and the chore were cherry-picked (`git cherry-pick -x`) from their original SHAs onto a new branch based on PR #1b's tip at the time of the split (`b0cca53`). The new SHAs differ from the originals (because cherry-pick creates new commit objects) but the code state is identical to what was on the original `pr-1b-foundations-b` before the split. **No code logic changed; only the commit topology and the SHA references in this apply-progress were updated.**

The PR #1b branch's commit SHAs are preserved exactly (no rebase, no cherry-pick) because the split was a pure `git reset --hard b0cca53` followed by a force-push; the 8 commits on PR #1b are byte-identical to their pre-split state.

## Why the chore (`ce7225b`) lives on PR #1b-fixes, not PR #1b

The chore's diff touches `Pacer.inspect_per_chat/0` (added in `F-12`) and `Pacer.validate_positive!/2` (added in `F-09`) — functions that do not exist on the pre-F-XX `pr-1b-foundations-b` branch (which is PR #1b's tip after the split). The diff cannot apply cleanly to PR #1b's tip. The chore lives on PR #1b-fixes so the diff applies cleanly against the post-F-XX code state.

## Test counts (delta)

- PR #1b baseline: 350 tests, 0 failures, 5 skipped.
- After PR #1b-fixes: 379 tests, 0 failures, 5 skipped.
- Delta: **+29 new tests** (the F-XX follow-up assertions: F-04/F-06 in BotToken, F-09/F-10/F-11/F-12/F-13/F-14 in Pacer, F-01..F-03 in ChatIdHash, F-07 in BotConfig). F-16 is a docs change (no test).

## `mix precommit` result (on PR #1b-fixes tip)

✅ GREEN.

- `compile --warnings-as-errors`: pass. No new warnings introduced.
- `format --check-formatted`: pass.
- `test`: 379 tests, 0 failures, 5 skipped.

## Chain state after the split + merges

```
main  (4d6e8cf — PR #1a merge #72, unchanged)
  └─ pr-1a-foundations-a  (47c94d6d — PR #1b clean merge #73)
       └─ pr-1b-foundations-b  (9fa4db54 — PR #1b-fixes merge #74)
            └─ pr-1b-fixes  (cherry-picked F-XX + chore)
```

Per the `feature-branch-chain` strategy, only the tracker branch (`feat/telegram-paciente-foundation`, draft, no-merge) eventually lands to `main`. PR #1a's content is on `main`; PR #1b's content is on `pr-1a-foundations-a` (the chain); PR #1b-fixes' content is on `pr-1b-foundations-b` (the chain).

## Out-of-scope items (left for later PRs in the chain)

- **W-1 (ETS per-chat row cleanup)** — still deferred to PR #2 (TASK-2-6 wires supervision). The fix is straightforward: a `handle_info(:cleanup)` callback in `Alethea.Telegram.Pacer` with new `Application.get_env` knobs (`:cleanup_interval_ms`, `:idle_threshold_ms`). See the PR #1b section above for the acceptance criteria.
- The full re-slice rationale (PR #2..#4) — separate PRs in the chain.

---

## Next step

The PR #1b chain is complete (PR #1b merged to `pr-1a-foundations-a`; PR #1b-fixes merged to `pr-1b-foundations-b`). The next recommended action is:

- **Proceed to `sdd-apply PR #2`** to land the webhook + plug + skeleton controllers + Oban queues + Pacer supervision (including the W-1 cleanup).
- PR #2 is the third of six chained PRs. Estimated lines: 642 (under the 700 target; soft budget 800, risk: medium).
- PR #2 also wires the `telegram_chat_id` → `telegram_chat_id_hash` column rename on `foundation_patients` (TASK-2-1) and the `lookup_patient_by_chat_hash/1` context function, which the clinical round-trip (PR #3a/#3b) will consume.
