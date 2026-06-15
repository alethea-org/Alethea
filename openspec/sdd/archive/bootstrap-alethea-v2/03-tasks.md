# Tasks: bootstrap-alethea-v2 — PR B (AI behaviours + Encryption KEK)

> PR A (`feat/foundation-accounts`, commit `3dc2adf`, 949 lines) is merged. This
> file is the **PR B** slice of the same change. PR B is the **last**
> implementation PR of `bootstrap-alethea-v2`. After PR B merges, only the
> `verify` and `archive` SDD phases remain.
>
> Strict TDD applies to every code task. Each commit is one logical work unit,
> revertable independently. Conventional commit format. No `Co-Authored-By`.

## Forecast adjustment (lesson from PR A)

PR A was approved with a `size:exception` because it landed 2.4× over the
original forecast (949 actual vs 340 forecast). Root cause: the original
estimate assumed 1 test per spec scenario; actual coverage was ~1.7 tests
per requirement once boundary/triangulation cases were included, and
`@moduledoc` boundary notes were ~30% longer than the spec scenarios alone.

The multipliers used **for this PR B forecast** (re-forecast only — does not
retroactively restate PR A):

| Bucket | Multiplier | Why |
|---|---|---|
| `code_lines` | × **1.3** | `@moduledoc` boundary notes ran ~30% longer in PR A than the spec-scenario lines alone. |
| `test_lines` | × **1.5** | Original estimate = 1 scenario per requirement; actual was 1.7 tests/req including triangulation and config-discovery checks. |
| `files_added` | × **1.0** | File count in PR A was accurate. |

These multipliers are persisted in `04-review-workload.md` so the reviewer
sees the math.

## Review Workload Forecast (PR B)

| Field | Pre-multiplier | × multiplier | Final |
|---|---|---|---|
| `code_lines` | 138 | × 1.3 | **~180** |
| `test_lines` | 92 | × 1.5 | **~140** |
| **`total_lines`** | 230 | — | **~320** |
| `files_added` | 13 | × 1.0 | **13** |
| `files_touched` | 1 (`config/test.exs`) | × 1.0 | **1** |
| `budget_risk` | — | — | **Low** (~320 lines < 400 budget) |
| `chained_prs_recommended` | — | — | **No** (this is the last PR of the change; no further split available) |
| `chain_strategy` | — | — | **stacked-to-main** (off `main` directly, per cached preflight) |
| `decision_needed_before_apply` | — | — | **No** (forecast under budget, no chain to choose) |

Decision needed before apply: No
Chained PRs recommended: No
Chain strategy: stacked-to-main
400-line budget risk: Low

## Scope boundary (hard rules)

- **Only `config/test.exs` is modified** outside the new tree.
- No touch: `lib/alethea/foundation/{accounts,tenant.ex,accounts.ex}` (PR A territory).
- No touch: `lib/alethea/encryption/`, `lib/alethea/ai/{llm_config,phi_worker,roberta_worker,...}.ex` (legacy).
- No touch: `test/support/foundation_test_helper.ex` (PR A territory).
- No new package deps. Behaviour modules are pure Elixir; KEK uses `:crypto` from stdlib.
- No new migrations. KEK is a primitive, not a table. AI behaviours are modules, not tables.
- Fake adapters live under `lib/alethea/ai/.../fake.ex` (NOT `test/support/`) so `:dev` env can run with them too.

## Suggested Work Units (1 PR — `feat/ai-behaviours-encryption-kek`)

| # | Work unit | Commit prefix | Notes |
|---|---|---|---|
| 1 | Scaffold `lib/alethea/ai/` and `test/alethea/ai/` (LLM, Embeddings, Whisper dirs) | `chore(ai):` | Empty modules with `@moduledoc` only. |
| 2 | `Alethea.AI.LLM` behaviour | `chore(ai):` | `@callback chat/2`, `@callback generate/2`. |
| 3 | `Alethea.AI.LLM.Fake` adapter | `feat(ai):` | Implements both callbacks; deterministic output. |
| 4 | `Alethea.AI.Embeddings` behaviour | `chore(ai):` | `@callback embed/2`, `model/0`, `dimensions/0`. |
| 5 | `Alethea.AI.Embeddings.Fake` adapter | `feat(ai):` | Single-text + batch shapes. |
| 6 | `Alethea.AI.Whisper` behaviour | `chore(ai):` | `@callback transcribe/2`. |
| 7 | `Alethea.AI.Whisper.Fake` adapter | `feat(ai):` | Returns empty `transcription()`. |
| 8 | `Alethea.Foundation.Encryption.KEK` | `chore(encryption):` | generate/wrap/unwrap with `<<0x01, iv, ct, tag>>`. |
| 9 | Test config wiring (`config/test.exs`) | `build(config):` | 3 entries: `:ai_llm`, `:ai_embeddings`, `:ai_whisper`. |
| 10 | Top-level `Alethea.AI` namespace marker + adapter discovery | `chore(ai):` | Public `Alethea.AI` module; helpers `llm/0`, `embeddings/0`, `whisper/0` reading `Application.get_env`. |

## Phase 1: Scaffold AI namespace (work unit 1)

- [ ] 1.1 Create empty `lib/alethea/ai/llm.ex`, `lib/alethea/ai/embeddings.ex`, `lib/alethea/ai/whisper.ex` — each with a 3-line `@moduledoc` "Stub — to be replaced in the next commits." Create empty `lib/alethea/ai/llm/`, `lib/alethea/ai/embeddings/`, `lib/alethea/ai/whisper/` subdirs. Create empty `test/alethea/ai/llm_test.exs`, `test/alethea/ai/embeddings_test.exs`, `test/alethea/ai/whisper_test.exs` and `test/alethea/foundation/encryption/` dir. Run `mix compile` to confirm it stays green.
- [ ] 1.2 Commit as `chore(ai): scaffold lib/alethea/ai/ and test/alethea/ai/ directories`.

## Phase 2: LLM behaviour + Fake (work units 2 + 3)

- [ ] 2.1 **RED** — `test/alethea/ai/llm_test.exs`:
  - (a) `Alethea.AI.LLM.behaviour_info(:callbacks)` is a list containing `{:chat, 2}` and `{:generate, 2}`.
  - (b) A module that does `use Alethea.AI.LLM` without `chat/2` triggers a compiler warning (assert via `Code.compile_string/1` + `CaptureIO`).
  - (c) `Alethea.AI.LLM.Fake.chat/2` returns `{:ok, %{content: "fake-response", usage: nil, model: "fake-llm"}}`.
  - (d) `Alethea.AI.LLM.Fake.generate/2` returns `{:ok, "fake-completion"}`.
  Run the 4 tests; (a), (b) fail, (c), (d) fail (Fake doesn't exist).
- [ ] 2.2 **GREEN** — create `lib/alethea/ai/llm.ex` with the `@callback chat/2`, `@callback generate/2`, typespecs (`message()`, `response()`) and `@moduledoc` quoting ADR-001 ("LLM behaviour is the swap point..."). Re-run the 4 tests; (a) and (b) now pass.
- [ ] 2.3 **GREEN** — create `lib/alethea/ai/llm/fake.ex` with `use Alethea.AI.LLM` and deterministic `chat/2` / `generate/2`. Re-run; (c) and (d) now pass.
- [ ] 2.4 **REFACTOR** — extract the fake's deterministic-output literal to a private `defp fake_response/0` so the shape is single-sourced. Add a `@moduledoc` note "this Fake is for tests and :dev; the production swap is in `ai-llm-groq-foundation`." `mix format --check-formatted` on the 3 changed files.
- [ ] 2.5 Commit sequence: `test(ai): add LLM behaviour + Fake scenarios (RED)` → `chore(ai): Alethea.AI.LLM behaviour with chat/generate callbacks` → `feat(ai): Alethea.AI.LLM.Fake adapter implementing the behaviour` → `chore(ai): refactor Fake to single-source its deterministic response`.

## Phase 3: Embeddings behaviour + Fake (work units 4 + 5)

- [ ] 3.1 **RED** — `test/alethea/ai/embeddings_test.exs`:
  - (a) `behaviour_info(:callbacks)` includes `{:embed, 2}`, `{:model, 0}`, `{:dimensions, 0}`.
  - (b) `use Alethea.AI.Embeddings` without `embed/2` emits a warning.
  - (c) `Alethea.AI.Embeddings.Fake.embed("hello", [])` returns `{:ok, [0.0]}`.
  - (d) `Alethea.AI.Embeddings.Fake.embed(["a", "b"], [])` returns `{:ok, [[0.0], [0.0]]}` (batch shape).
  - (e) `Alethea.AI.Embeddings.Fake.model()` and `dimensions/0` return strings/pos_integer.
  Run the 5 tests; (a)–(e) fail.
- [ ] 3.2 **GREEN** — `lib/alethea/ai/embeddings.ex` with callbacks, typespecs, `@moduledoc` quoting ADR-002 ("multilingüe… HF Inference API… e5-large or bge-m3").
- [ ] 3.3 **GREEN** — `lib/alethea/ai/embeddings/fake.ex` with `use Alethea.AI.Embeddings`, single + batch embed, fixed `model/0` and `dimensions/0`.
- [ ] 3.4 **REFACTOR** — typespecs for `embed/2` show both `{:ok, [float()]}` (single) and `{:ok, [[float()]]}` (batch) returns. `mix format --check-formatted` on the 3 files.
- [ ] 3.5 Commit sequence mirrors Phase 2: RED → behaviour → Fake → refactor.

## Phase 4: Whisper behaviour + Fake (work units 6 + 7)

- [ ] 4.1 **RED** — `test/alethea/ai/whisper_test.exs`:
  - (a) `behaviour_info(:callbacks)` is `[{:transcribe, 2}]`.
  - (b) `use Alethea.AI.Whisper` without `transcribe/2` emits a warning.
  - (c) `Alethea.AI.Whisper.Fake.transcribe("path-or-binary", [])` returns `{:ok, %{text: "", segments: [], language: nil}}`.
  - (d) `Alethea.AI.Whisper.Fake` accepts both a binary and a string path (the `transcribe/2` first-arg typespec is `binary() | String.t()`).
  Run the 4 tests; (a)–(d) fail.
- [ ] 4.2 **GREEN** — `lib/alethea/ai/whisper.ex` with `@callback transcribe/2`, `transcription()` typespec, `@moduledoc` noting Whisper is for `Grabación` (per UBIQUITOUS_LANGUAGE.md).
- [ ] 4.3 **GREEN** — `lib/alethea/ai/whisper/fake.ex` with `use Alethea.AI.Whisper` and the empty-shape return.
- [ ] 4.4 **REFACTOR** — typespec on `transcribe/2`'s first arg: `binary() | FileName.t()` (per the spec). `mix format --check-formatted`.
- [ ] 4.5 Commit sequence mirrors Phases 2 and 3.

## Phase 5: KEK primitive (work unit 8)

- [ ] 5.1 **RED** — `test/alethea/foundation/encryption/kek_test.exs`. 7 scenarios from `specs/encryption/spec.md`:
  - (a) round-trip: `wrap(dek, kek)` → `unwrap(wrapped, kek)` returns the original DEK byte-for-byte.
  - (b) wrong KEK: `unwrap(wrapped, kek_b)` returns `{:error, :corrupted}`.
  - (c) tampered ciphertext: flip a byte in the middle; unwrap returns `{:error, :corrupted}`.
  - (d) `generate/0` returns exactly 32 bytes; 100 calls produce no duplicates (collision-check on a small sample).
  - (e) `wrap(dek, <<>>)` returns `{:error, :invalid_kek}`.
  - (f) `wrap(<<>>, kek)` returns `{:error, :invalid_dek}`.
  - (g) version mismatch: `unwrap(<<0x99, ...>>, kek)` returns `{:error, :version_mismatch}`.
  Run the 7 tests; all fail (module does not exist).
- [ ] 5.2 **GREEN** — `lib/alethea/foundation/encryption/kek.ex`:
  - `generate/0` → `:crypto.strong_rand_bytes(32)`.
  - `wrap(dek, kek)` → `<<0x01, iv::12-bytes, ciphertext::binary, tag::16-bytes>>` via `:crypto.crypto_one_time_aead(:aes_256_gcm, kek, iv, dek, aad, true)`. Returns `{:error, :invalid_kek}` if `byte_size(kek) != 32`, `{:error, :invalid_dek}` if `byte_size(dek) != 32` (note: `dek != <<>>` is the spec; the spec says empty DEK fails, so the 32-byte check covers the spec literally only if we treat `<<>>` as 0 bytes — keep both: explicit 32-byte guard + `byte_size(dek) == 0 → :invalid_dek`).
  - `unwrap(<<0x01, iv::12, rest::binary>>, kek)`: parse `<<ct::binary, tag::16>>`; AEAD decrypt; on `:error` return `{:error, :corrupted}`.
  - `unwrap(<<0x99, _::binary>>, _)` → `{:error, :version_mismatch}`.
  - AAD constant: `"alethea-foundation-kek-v1"` (different from legacy `Alethea.Encryption.PatientVault` `"alethea-patient-data"` — note this in the moduledoc).
  Re-run the 7 tests; all pass.
- [ ] 5.3 **REFACTOR** — typespecs for `dek`, `kek`, `wrap/2`, `unwrap/2`. `@moduledoc` with the v2 contract, the wire-incompatibility note vs legacy `PatientVault` (different version byte, different AAD, return-tuple errors), and the link to `UBIQUITOUS_LANGUAGE.md` "cryptographic erasure" mechanism. `mix format --check-formatted` on `kek.ex` and `kek_test.exs`.
- [ ] 5.4 Commit sequence: `test(encryption): add KEK envelope scenarios (RED)` → `chore(encryption): Alethea.Foundation.Encryption.KEK with versioned envelope` → `chore(encryption): refactor KEK with explicit typespecs and v2 boundary moduledoc`.

## Phase 6: Test config wiring (work unit 9)

- [ ] 6.1 **RED** — add to `test/alethea/ai/llm_test.exs` (or a new `test/alethea/ai/adapter_discovery_test.exs`) the assertion: `Application.get_env(:alethea, :ai_llm) == Alethea.AI.LLM.Fake` (and the same for `:ai_embeddings` and `:ai_whisper`). Run; the assertions fail.
- [ ] 6.2 **GREEN** — append 3 lines to `config/test.exs`:
  ```elixir
  config :alethea, :ai_llm, Alethea.AI.LLM.Fake
  config :alethea, :ai_embeddings, Alethea.AI.Embeddings.Fake
  config :alethea, :ai_whisper, Alethea.AI.Whisper.Fake
  ```
  Re-run; the assertions pass.
- [ ] 6.3 Commit as `build(config): wire Fake adapters as configured AI providers in :test env`. Note: this is the **only** legacy-style file PR B touches, per the scope rules.

## Phase 7: Top-level `Alethea.AI` namespace + adapter discovery (work unit 10)

- [ ] 7.1 **RED** — `test/alethea/ai_test.exs`:
  - (a) `Alethea.AI.llm/0` returns the module configured at `:ai_llm` (in test env: `Alethea.AI.LLM.Fake`).
  - (b) `Alethea.AI.embeddings/0` returns the module at `:ai_embeddings` (in test env: `Alethea.AI.Embeddings.Fake`).
  - (c) `Alethea.AI.whisper/0` returns the module at `:ai_whisper` (in test env: `Alethea.AI.Whisper.Fake`).
  - (d) `Alethea.AI.llm/0` raises a clear error if no `:ai_llm` is configured (test with `Application.delete_env` + restore in `on_exit`).
  Run the 4 tests; (a)–(d) fail.
- [ ] 7.2 **GREEN** — create `lib/alethea/ai.ex` with:
  - `def llm, do: Application.fetch_env!(:alethea, :ai_llm)` (and analogously for embeddings/whisper).
  - `@moduledoc` describing the three-slot swap, ADR-001/002/003 reference, and "this module is the discovery surface; behaviour modules are the contract; fakes are the test adapter."
- [ ] 7.3 **REFACTOR** — extract the 3 helpers to a `defp configured!/1` private function. Add typespecs (`@spec llm() :: module()`). `mix format --check-formatted` on `ai.ex` and `ai_test.exs`.
- [ ] 7.4 Commit sequence: `test(ai): add Alethea.AI adapter discovery scenarios (RED)` → `chore(ai): top-level Alethea.AI module with adapter discovery` → `chore(ai): refactor adapter discovery to single-source configured!/1`.

## Phase 8: Final verification

- [ ] 8.1 `mix compile --warnings-as-errors` clean.
- [ ] 8.2 `mix format --check-formatted` clean on every changed file (do NOT format the whole repo).
- [ ] 8.3 `mix test` exits with `248 + N (new tests) = new total, 0 failures, 5 skipped`. The 5 skipped and the 248 baseline come from PR A; PR B adds new tests to the total.
  - Expected new test count: ~22 tests (4 LLM + 5 embeddings + 4 whisper + 7 KEK + 1 config discovery in the LLM test + 4 `Alethea.AI` discovery = ~25; the user's multiplier-aware math says ~25 new tests). Final total: ~273 tests, 0 failures, 5 skipped.
- [ ] 8.4 Verify only the expected files are touched: `git status` shows changes only in:
  - `lib/alethea/ai.ex` (new)
  - `lib/alethea/ai/llm.ex`, `llm/fake.ex` (new)
  - `lib/alethea/ai/embeddings.ex`, `embeddings/fake.ex` (new)
  - `lib/alethea/ai/whisper.ex`, `whisper/fake.ex` (new)
  - `lib/alethea/foundation/encryption/kek.ex` (new)
  - `test/alethea/ai_test.exs` (new)
  - `test/alethea/ai/llm_test.exs`, `embeddings_test.exs`, `whisper_test.exs` (new)
  - `test/alethea/foundation/encryption/kek_test.exs` (new)
  - `config/test.exs` (modified: 3 lines added)
  - Total: **13 new files + 1 modified file**.
- [ ] 8.5 `mix precommit` clean.
- [ ] 8.6 Branch the work on `feat/ai-behaviours-encryption-kek` off `main`. **Do NOT merge to main.** Push and stop; orchestrator handles PR creation.

## Implementation Order (recap)

1. RED test for the new behavior → commit.
2. GREEN minimum implementation → commit.
3. REFACTOR (typespecs, moduledoc, format) → commit.
4. Re-run the narrower test subset (`mix test test/alethea/ai/...` or `mix test test/alethea/foundation/encryption/...`) after each commit. The 248 baseline must never grow in failing tests.
5. Run `mix format --check-formatted` on the changed files at the end of each cycle.
6. Full `mix test` is the gate at the end of Phase 8 only.

## Open questions

None. All design decisions were resolved before this PR started:
- Fake adapters in `lib/alethea/ai/.../fake.ex` (not `test/support/`) — confirmed in proposal Q3.
- KEK envelope wire-incompatible with legacy `PatientVault` (different version byte, different AAD) — confirmed by ADR-003 + the explicit spec scenario in `specs/encryption/spec.md`.
- Only `config/test.exs` is the legacy-style file touched — confirmed in the prompt scope rules.
