# Review Workload Forecast: bootstrap-alethea-v2

> PR A (`feat/foundation-accounts`, commit `3dc2adf`, 949 lines actual) is
> **merged**. This file is the per-PR forecast for **PR B** (the last
> implementation PR of the change) plus a final summary of the whole
> `bootstrap-alethea-v2` change.

## PR A — actually landed (no restatement, just a record)

| Field | Forecast | Actual | Delta |
|---|---|---|---|
| `code_lines` | ~205 | ~560 | × 2.7 |
| `test_lines` | ~135 | ~389 | × 2.9 |
| `total_lines` | ~340 | **949** | × 2.8 |
| `files_added` | 11 | 19 | +8 |
| `files_modified` | 0 | 1 (`mix.exs` for the foundation namespace marker — minor) | +1 |
| `budget_risk` | Low (estimated) | **High** (actual) | exception approved |
| `chain_strategy` | stacked-to-main | stacked-to-main | ✅ |
| `decision_needed_before_apply` | No | n/a (already applied) | n/a |

PR A was approved with a `size:exception` because the test multiplier and
the `@moduledoc` density ran ~2.4×–2.9× over forecast. The lesson is
captured in the multipliers below.

## PR B — forecast (with multipliers applied)

### Multiplier source-of-truth

| Bucket | Multiplier | Reason (lesson from PR A) |
|---|---|---|
| `code_lines` | × **1.3** | `@moduledoc` boundary notes ran ~30% longer than the spec-scenario lines alone. |
| `test_lines` | × **1.5** | Original estimate assumed 1 test per spec scenario; PR A landed 1.7 tests/req once triangulation, config-discovery, and compiler-warning checks were added. |
| `files_added` | × **1.0** | File count in PR A was accurate. |

### Per-PR forecast (the math the reviewer can verify)

| Field | Pre-multiplier | × multiplier | Final |
|---|---|---|---|
| `code_lines` | 138 | × 1.3 | **~180** |
| `test_lines` | 92 | × 1.5 | **~140** |
| **`total_lines`** | 230 | — | **~320** |
| `files_added` | 13 | × 1.0 | **13** |
| `files_touched` (legacy-style) | 1 (`config/test.exs`) | × 1.0 | **1** |
| `budget_risk` | — | — | **Low** (~320 < 400) |
| `chained_prs_recommended` | — | — | **No** (this is the last PR) |
| `chain_strategy` | — | — | **stacked-to-main** |
| `decision_needed_before_apply` | — | — | **No** (under budget, no chain to choose) |

### PR B risk register

| Risk | Likelihood | Mitigation |
|---|---|---|
| KEK envelope accidentally wire-compatible with legacy `Alethea.Encryption.PatientVault` (silent data round-trip) | Low | Different AAD constant (`"alethea-foundation-kek-v1"` vs legacy `"alethea-patient-data"`); explicit `@moduledoc` note; the v2 `0x01` version byte is a separate identifier. |
| Test config entries collide with existing `:ai_llm`/`:ai_embeddings`/`:ai_whisper` keys | Low | `grep -r ":ai_llm\|:ai_embeddings\|:ai_whisper" config/` before adding — should be zero matches. If any legacy key matches, the `Alethea.AI.LLM` etc. are new names, but the keys are the wire — pick a different config key in that case. |
| Behaviour module's `@callback` signature diverges from the spec scenario text | Low | Phase 2-4 RED tasks copy the spec's `behaviour_info(:callbacks)` expectations verbatim; the GREEN task adds the exact callback name + arity. |
| `Alethea.AI.llm/0` (`fetch_env!`) crashes tests in unexpected orders | Low | `Alethea.AI.llm/0` only reads env; it does not start workers. Phases 6+7 wire the env before any consumer test runs. |
| `mix format` flagged on the whole repo by CI | Low | Each cycle runs `mix format --check-formatted` on changed files only; final Phase 8.2 verifies before commit. |
| PR B lands > 400 lines despite the multiplier | Low | Hard cap on the breakdown: 11 new files × ~15 lines/file average for behaviour/fake modules + ~70 lines for KEK + ~140 lines of tests = ~320. No new schemas, no migrations, no LiveView. |

Decision needed before apply: No
Chained PRs recommended: No
Chain strategy: stacked-to-main
400-line budget risk: Low

## Final bootstrap change summary

The original 3-PR plan in `00-proposal.md` and `03-tasks.md` was:

| PR | Goal | Forecast | Actual / Final |
|---|---|---|---|
| PR 1 | `open_api_spex` removal + tests still green | ~50 lines | (landed as part of bootstrap PR #66 in pre-PR-A work, already in `main` as of commit `cc01494` / `e67bc84`) |
| PR A | `Alethea.Foundation.Accounts.*` + `Tenant` + helpers | ~340 lines | **949 lines** (exception approved) |
| PR B | AI behaviours + KEK + Fakes + test config | ~230 lines | **~320 lines** (with multipliers) |
| **Total** | | **~620 lines** | **~1269 lines** (the real `git diff` of the change) |

### What actually lands on `main` after PR B merges

| PR | SHA | Lines | Status |
|---|---|---|---|
| Bootstrap pre-work (open_api_spex removal + bootstrap docs) | `cc01494`, `f5fd76b`, etc. | ~120 | merged (pre-PR-A) |
| `feat/foundation-accounts` (PR A) | `3dc2adf` (PR #69) | **949** | merged |
| `feat/ai-behaviours-encryption-kek` (PR B) | (pending) | **~320** | pending apply |
| **Total bootstrap delta on `main`** | | **~1389** | 2 of 2 implementation PRs merged |

PR A was 2.4× over its **own** forecast; this is not a regression in PR B's
plan, it is a recalibration. The forecast for PR B is now honest about
`@moduledoc` density and test triangulation, so the multiplier risk is
priced in.

### Comparison to the original 3-PR plan

- The original plan was 3 PRs; the actual shape is **2 implementation PRs** (PR 1 / `open_api_spex` cleanup landed as commit-level prep, not a separate PR) plus the `state.yaml` / no-go / migration-rule docs that came in with PR A.
- Net effect on `main`: 2 PRs of real code, 1 set of doc artifacts, ~1.4k lines total. Roughly **2× the original estimate** for total code delta — almost entirely due to the test-triangulation lesson learned in PR A and now applied to PR B.
- This is the **last** implementation PR. After it merges, only the `verify` and `archive` SDD phases remain.

### `chained_prs_recommended`

- **No** for PR B itself (single PR, under budget).
- **Already chained** across the change: PR A → PR B is a stacked chain on `main`. The chain is now complete.

### `decision_needed_before_apply`

- **No** for PR B. Forecast is under the 400-line budget. No chain strategy to choose (single PR).
- The orchestrator can proceed to `sdd-apply` without asking the user. If the user wants to gate it, the `delivery_strategy` was cached as `ask-always` — honor it and ask once before apply.

### `chain_strategy_recommendation`

- **`stacked-to-main`** (the same as cached).
- PR B branches off `main` directly (`feat/ai-behaviours-encryption-kek`).
- No feature/tracker branch needed (single PR, not a chain).
- This matches the cached `chain_strategy: stacked-to-main` and PR A's actual delivery.

### Open questions for the user

**None.** All open questions from previous phases are resolved by the PR A result:
- Multiplier math: documented above and in `03-tasks.md`.
- Fake adapter location: confirmed (`lib/alethea/ai/.../fake.ex`).
- KEK wire-incompatibility: confirmed in `02-design.md` and `specs/encryption/spec.md`.
- Legacy file touch surface: confirmed (only `config/test.exs`).
- No new package deps: confirmed.
- No new migrations: confirmed.

The only thing the user might want to confirm is the PR B branch name
(`feat/ai-behaviours-encryption-kek`) — this is conventional for the repo
based on PR A (`feat/foundation-accounts`) and is not a real decision.
