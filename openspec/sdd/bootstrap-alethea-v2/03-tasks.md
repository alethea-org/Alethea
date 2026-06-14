# Tasks: bootstrap-alethea-v2

## Review Workload Forecast

| Field | Value |
|-------|-------|
| Estimated changed lines | ~650 (60% code, 40% tests) |
| 400-line budget risk | Medium |
| Chained PRs recommended | Yes |
| Suggested split | PR 1 = dependency cleanup + foundation namespace; PR 2 = accounts schemas; PR 3 = AI behaviours + encryption primitive |
| Delivery strategy | ask-always (orchestrator preflight) |
| Chain strategy | feature-branch-chain (changes are stacked on `bootstrap/foundation` branch) |

Decision needed before apply: Yes
Chained PRs recommended: Yes
Chain strategy: feature-branch-chain
400-line budget risk: Medium

### Suggested Work Units

| Unit | Goal | Likely PR | Notes |
|------|------|-----------|-------|
| 1 | `open_api_spex` removal + tests still green | PR 1 → `bootstrap/foundation` | Pre-flight cleanup; lowest risk; verifies the dep removal first. |
| 2 | `Alethea.Foundation.Accounts.*` schemas + `Tenant` scope helper + tests | PR 2 → PR 1 branch | Three new schemas, context, tenant helper. Largest single piece. |
| 3 | AI behaviour trio + KEK/DEK primitive + Fake adapters | PR 3 → PR 2 branch | Behaviours + encryption; isolated from accounts. |

Strict TDD applies: every code task has its RED test committed first. Each PR has its own review boundary.

## Phase 1: Dependency Cleanup (PR 1)

- [ ] 1.1 **RED** — write `test/alethea_web/api_spec_absence_test.exs` that asserts `mix.exs` does not contain the string `open_api_spex`. Run the test: it should fail (the dep is still there).
- [ ] 1.2 **GREEN prep** — grep the codebase for `OpenApiSpex` references. Document the matches in `openspec/sdd/bootstrap-alethea-v2/01-1-grep-openapi-results.md`. Confirm the only files importing it are the three known files. If anything else, stop and flag.
- [ ] 1.3 **GREEN** — remove `{:open_api_spex, "~> 3.18"}` from `mix.exs`; delete `lib/alethea_web/api_spec.ex`, `lib/alethea_web/api_spec/schemas.ex`, `lib/alethea_web/controllers/open_api_spec_controller.ex`.
- [ ] 1.4 **GREEN** — run `mix deps.unlock --unused` to refresh `mix.lock`. Run `mix compile --warnings-as-errors` and `mix test`. The new test (1.1) passes; the 224 + 1 fail + 5 skip baseline is preserved.
- [ ] 1.5 **REFACTOR** — `mix format`. Commit as `chore(bootstrap): remove open_api_spex`.

## Phase 2: Foundation Namespace & Tenant Helper (PR 2, part A)

- [ ] 2.1 **RED** — `test/alethea/foundation/tenant_test.exs`: test that `Alethea.Foundation.Tenant.scope_query(Patient, "prof-id")` returns a query with the `WHERE professional_id = ^"prof-id"` clause. Test that `scope_query(q, nil)` raises `ArgumentError`. (Use the existing legacy `Alethea.Accounts.Patient` schema as the queryable for now; the foundation Patient arrives in 2.x.)
- [ ] 2.2 **GREEN** — create `lib/alethea/foundation.ex` and `lib/alethea/foundation/tenant.ex`. The `Tenant` module exports `scope_query/2` using `Ecto.Query.from/2` with a `where` clause. Add `@moduledoc` explaining "psicólogo es el tenant".
- [ ] 2.3 **REFACTOR** — extract the `where` clause to a private function. Add a `@type professional_id :: binary()`. Run the tenant test plus `mix test` to confirm no regression.

## Phase 3: Foundation Accounts — Professional Schema (PR 2, part B)

- [ ] 3.1 **RED** — `test/alethea/foundation/accounts/professional_test.exs`: write 4 failing tests per the accounts spec scenarios (register happy path, duplicate email, invalid email, short password).
- [ ] 3.2 **GREEN** — create `lib/alethea/foundation/accounts/professional.ex` with the schema from the spec, `register_professional/1`, password hashing via `:pbkdf2` (already a dep).
- [ ] 3.3 **REFACTOR** — add `@moduledoc`, typespecs, format. All 4 tests pass.

## Phase 4: Foundation Accounts — Patient Schema (PR 2, part C)

- [ ] 4.1 **RED** — `test/alethea/foundation/accounts/patient_test.exs`: 3 scenarios (create bound to pro, create without pro rejected, invalid status rejected).
- [ ] 4.2 **GREEN** — create `lib/alethea/foundation/accounts/patient.ex` with the canonical profile fields from `UBIQUITOUS_LANGUAGE.md` (Perfil del paciente). `create_patient/2` takes the professional + attrs.
- [ ] 4.3 **GREEN** — update `lib/alethea/foundation/tenant.ex` to also accept the new `Alethea.Foundation.Accounts.Patient` as the queryable (the test in 2.1 should now also run against the new schema; if signatures diverge, document).
- [ ] 4.4 **REFACTOR** — add the `professional_id` FK convention to the schema `@moduledoc`.

## Phase 5: Foundation Accounts — Admin Schema (PR 2, part D)

- [ ] 5.1 **RED** — `test/alethea/foundation/accounts/admin_test.exs`: 2 scenarios (admin signup independent of pros, invalid role rejected).
- [ ] 5.2 **GREEN** — create `lib/alethea/foundation/accounts/admin.ex` with the schema from the spec, `register_admin/1`, and the role enum.
- [ ] 5.3 **REFACTOR** — add `@moduledoc` linking back to `CONTEXT.md` (Admin has no clinical access).

## Phase 6: Foundation Accounts Context Module (PR 2, part E)

- [ ] 6.1 **RED** — `test/alethea/foundation/accounts_test.exs`: test that `Alethea.Foundation.Accounts` exports `register_professional/1`, `create_patient/2`, `register_admin/1` and they delegate to the schema modules. Smoke test only.
- [ ] 6.2 **GREEN** — create `lib/alethea/foundation/accounts.ex` as the public context.
- [ ] 6.3 **REFACTOR** — add `@moduledoc` describing the boundary with legacy `Alethea.Accounts`. **Critical:** add a `@moduledoc` note "future changes migrate legacy slice by slice; do NOT import both from a single caller until the migration is complete."

## Phase 7: AI Behaviour — LLM (PR 3, part A)

- [ ] 7.1 **RED** — `test/alethea/ai/llm_test.exs`: 3 tests (behaviour module loaded, `behaviour_info(:callbacks)` includes `chat/2` and `generate/2`, Fake adapter round-trips with `{:ok, %{content: "...", ...}}`).
- [ ] 7.2 **GREEN** — create `lib/alethea/ai/llm.ex` with `@callback chat/2`, `@callback generate/2`, typespecs, and `@moduledoc` quoting ADR-001.
- [ ] 7.3 **GREEN** — create `lib/alethea/ai/llm/fake.ex` as a `use Alethea.AI.LLM` implementation that returns `{:ok, %{content: "fake", usage: nil, model: "fake"}}`. Add `config :alethea, :ai_llm, Alethea.AI.LLM.Fake` to `config/test.exs` (test env only).
- [ ] 7.4 **REFACTOR** — `@moduledoc` note that the Fake is for tests/dev only and the prod swap happens in `ai-llm-groq-foundation`.

## Phase 8: AI Behaviour — Embeddings (PR 3, part B)

- [ ] 8.1 **RED** — `test/alethea/ai/embeddings_test.exs`: behaviour loaded, callbacks include `embed/2`/`model/0`/`dimensions/0`, Fake returns `{:ok, [0.0]}` for single text and `{:ok, [[0.0]]}` for batch.
- [ ] 8.2 **GREEN** — `lib/alethea/ai/embeddings.ex` + `lib/alethea/ai/embeddings/fake.ex`. Test config entry.
- [ ] 8.3 **REFACTOR** — link to ADR-002 in `@moduledoc`.

## Phase 9: AI Behaviour — Whisper (PR 3, part C)

- [ ] 9.1 **RED** — `test/alethea/ai/whisper_test.exs`: behaviour loaded, callback `transcribe/2`, Fake returns `{:ok, %{text: "", segments: [], language: nil}}`.
- [ ] 9.2 **GREEN** — `lib/alethea/ai/whisper.ex` + `lib/alethea/ai/whisper/fake.ex`. Test config entry.
- [ ] 9.3 **REFACTOR** — `@moduledoc` notes the input can be a binary or a file path.

## Phase 10: Encryption Foundation Primitive (PR 3, part D)

- [ ] 10.1 **RED** — `test/alethea/foundation/encryption/kek_test.exs`: 7 scenarios from the encryption spec (round-trip, wrong KEK, tampered ciphertext, generate 32 bytes, empty KEK, empty DEK, version mismatch on `<<0x99>>` blob, version byte `0x01` on first byte of wrapped).
- [ ] 10.2 **GREEN** — `lib/alethea/foundation/encryption/kek.ex` with `generate/0` (`:crypto.strong_rand_bytes(32)`), `wrap/2` (`:crypto.crypto_one_time_aead/6` with prefix-byte envelope `<<0x01, iv, ciphertext, tag>>`), `unwrap/2` (parses version byte, returns `{:error, :version_mismatch}` on `0x99`, `{:error, :corrupted}` on AEAD failure).
- [ ] 10.3 **REFACTOR** — typespecs, `@moduledoc` explaining the v2 contract and the link to cryptographic erasure in `UBIQUITOUS_LANGUAGE.md`.

## Phase 11: Test Helper Fixtures (PR 2 part F / PR 3 part E)

- [ ] 11.1 **RED** — `test/support/foundation_test_helper.ex`: write a smoke test that calls `Alethea.FoundationTestHelper.professional_fixture/1` and expects a persisted `%Professional{}`.
- [ ] 11.2 **GREEN** — implement the helper with sensible defaults (random email, 12+ char password, random full name).
- [ ] 11.3 **REFACTOR** — add `patient_fixture/2` (professional + attrs) reusing the helper.

## Phase 12: Documentation & No-Go Manifest (any PR, end of stack)

- [ ] 12.1 Write `openspec/sdd/bootstrap-alethea-v2/05-no-go.md` listing every deferred item with the future change that owns it (per the "Out of Scope" section of the proposal).
- [ ] 12.2 Write `openspec/sdd/bootstrap-alethea-v2/06-migration-rule.md` describing the migration archival policy (rule only, no deletions).
- [ ] 12.3 Update `state.yaml` to reflect the current phase after each PR is merged.

## Phase 13: Final Verification (after PR 3 lands)

- [ ] 13.1 `mix compile --warnings-as-errors` clean.
- [ ] 13.2 `mix format --check-formatted` clean.
- [ ] 13.3 `mix test` shows: 224 (legacy) + ~25 (new foundation tests) + 1 pre-existing failure + 5 skipped. The pre-existing failure in `page_controller_test.exs:6` is **not fixed** in this change.
- [ ] 13.4 `grep -r "open_api_spex\|OpenApiSpex" lib/ config/ mix.exs mix.lock` returns zero matches.
- [ ] 13.5 Run `mix precommit` per `AGENTS.md`. Fix any new issues.

## Implementation Order (within each PR)

1. RED test for the new behavior → commit.
2. GREEN minimum implementation → commit.
3. REFACTOR (typespecs, moduledoc, format) → commit.
4. Re-run `mix test` after each commit. The 224-test baseline + 1 failure + 5 skipped must never grow in failing tests.
