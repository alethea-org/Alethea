# Design: bootstrap-alethea-v2

## Technical Approach

Add a new `Alethea.Foundation.*` namespace parallel to the legacy `Alethea.*` modules, plus three behaviour-only AI adapter interfaces and a KEK envelope primitive. The only removal is `open_api_spex` (one dep + three files). No migration files are deleted in this change. Strict TDD per task.

The design follows three principles:
1. **Additive parallelism**: the new code does not touch legacy code. Future changes migrate slice by slice.
2. **Behaviour-only for AI**: define the swap point, no implementations. Concrete adapters (Groq LLM, HF Embeddings, Groq Whisper) are scoped to their own changes.
3. **Type contracts over wire formats**: the encryption module is a pure function set; the data model that holds wrapped DEKs is the job of a later integration change.

## Architecture Decisions

### Decision: New namespace `Alethea.Foundation.*` instead of modifying `Alethea.*`

**Choice**: new `lib/alethea/foundation/` tree (`accounts/`, `encryption/`, `tenant.ex`).
**Alternatives considered**:
- (a) Modify legacy `Alethea.Accounts.*` in place — REJECTED. Would break 224 tests, force a big-bang migration, and block parallel work.
- (b) Add a top-level `Foundation` app boundary (`AletheaFoundation.Accounts.*`) — REJECTED. Single-app umbrella adds dep complexity and Phoenix 1.8 apps generally do not need this.
**Rationale**: parallel namespace keeps legacy stable, lets strict TDD proceed file-by-file, and the rename/migration is itself a future change with a dedicated design discussion.

### Decision: Tenant helper is a 30-line scope_query, not a multi-tenancy library

**Choice**: `Alethea.Foundation.Tenant.scope_query(query, professional_id)` plus a `tenant_id` FK convention.
**Alternatives considered**:
- (a) Adopt `triplex` or `tenant` — REJECTED. Premature; no team/org requirement in MVP. `CONTEXT.md` explicitly says "Multi-tenant complejo (equipos, organizaciones)" is out.
- (b) Use Postgres RLS — REJECTED for now. Adds operational complexity, not justified by the MVP scope.
**Rationale**: the `psicólogo es el tenant` rule is a single FK column. A scope helper is enough; we revisit if team/org support is later required.

### Decision: AI behaviours are `@callback` declarations only, with Fake adapters in test env

**Choice**: three behaviour modules (`Alethea.AI.{LLM,Embeddings,Whisper}`) + a `config/test.exs` entry pointing to a no-op `Fake` adapter per slot.
**Alternatives considered**:
- (a) Ship one real implementation per behaviour in this change — REJECTED. ADR-001/002/003 require concrete provider decisions (model choice, cost, latency). Those are scoped to provider-specific changes.
- (b) Use LangChain behaviours (already in `mix.exs`) — REJECTED. LangChain is for chains, not adapter swap. We want our own thin behaviours so the swap is provider-agnostic.
**Rationale**: the swap point is the contract; implementations are decisions for their own changes with their own review.

### Decision: KEK/DEK skeleton uses AES-256-GCM via `:crypto.crypto_one_time_aead/6` (the same primitive the legacy `Alethea.Encryption.PatientVault` uses), with a versioned envelope

**Choice**: `Alethea.Foundation.Encryption.KEK` with `wrap/2`, `unwrap/2`, `generate/0`, and a `<<version, iv, ciphertext, tag>>` binary shape (version byte = `0x01`).
**Alternatives considered**:
- (a) Re-export `Alethea.Encryption.PatientVault.encrypt/2` — REJECTED. The legacy API is already in use; the foundation is a v2 contract with a different shape (versioned envelope, return-tuple errors, no `Application.get_env`).
- (b) Use Cloak's `Cipher` directly — REJECTED for the v2 skeleton. Cloak is fine for vault-style fields, but the KEK/DEK envelope wants raw byte handling and self-describing blobs.
**Rationale**: `:crypto.crypto_one_time_aead/6` is the same primitive already used (per `openspec/archive/issues-v1/001-registro-pacientes-boveda-segura.md`), so the v1 and v2 envelopes are wire-compatible, easing the future migration.

### Decision: OpenApiSpex removal is surgical

**Choice**: remove the dep, delete `lib/alethea_web/api_spec.ex`, `lib/alethea_web/api_spec/schemas.ex`, `lib/alethea_web/controllers/open_api_spec_controller.ex`, run `mix deps.unlock --unused`.
**Alternatives considered**:
- (a) Keep OpenApiSpex for legacy compat — REJECTED. The router does not mount it (we verified the three files are the only ones referencing it; if a route uses it, this task surfaces the conflict and defers).
- (b) Migrate to a different OpenAPI lib — REJECTED. ADR-004 and `CONTEXT.md` say "Sin OpenAPI". The future API is LiveView only.
**Rationale**: the smallest, reversible change. If something is missed, revert one commit.

### Decision: Migration files are NOT deleted; a rule is documented

**Choice**: add `06-migration-rule.md` describing the archival policy, but do not delete any `priv/repo/migrations/*.exs` in this change.
**Alternatives considered**:
- (a) Delete legacy migrations — REJECTED. Destroys history; risky on a reset; the user did not ask for it.
- (b) Squash all migrations into one — REJECTED. Loses auditability; no DB is in production.
**Rationale**: keep the history, mark a future change as the owner of any destructive clean-up.

## Data Flow

For each foundation primitive, the data flow at this stage is minimal — no integration yet. The diagrams describe what the primitives WILL look like once integrated (out of scope here, but documented so future changes have a target).

### Tenant Scope Helper (intended use, not wired in this change)

```
LiveView (psicologo-foundation)
  │
  ├── current_scope.professional.id
  │
  ▼
Alethea.Foundation.Tenant.scope_query(Patient, professional_id)
  │
  ▼
Ecto.Query (with WHERE professional_id = ^id)
  │
  ▼
Repo.all/1
  │
  ▼
[Patient rows belonging to that professional only]
```

### KEK/DEK Wrap/Unwrap (pure functions)

```
generate_kek()  ──► kek (32 bytes)
generate_dek()  ──► dek (32 bytes)
wrap(dek, kek)  ──► wrapped = <<0x01, iv, ciphertext, tag>>
unwrap(wrapped, kek) ──► {:ok, dek} | {:error, :corrupted | :version_mismatch}
```

### AI Adapter Swap (runtime)

```
Domain code: Alethea.AI.LLM.chat(messages, opts)
  │
  ▼
Behaviour dispatch via config :alethea, :ai_llm
  │
  ├── test env  → Alethea.AI.LLM.Fake
  ├── dev env   → Alethea.AI.LLM.Groq   (future change: ai-llm-groq-foundation)
  └── prod env  → Alethea.AI.LLM.Groq   (same)
```

## File Changes

| File | Action | Description |
|------|--------|-------------|
| `mix.exs` | Modify | Remove `{:open_api_spex, "~> 3.18"}` from `deps/0`. |
| `lib/alethea_web/api_spec.ex` | Delete | Was the OpenApiSpex plug. |
| `lib/alethea_web/api_spec/schemas.ex` | Delete | OpenApiSpex schemas. |
| `lib/alethea_web/controllers/open_api_spec_controller.ex` | Delete | OpenApiSpex controller. |
| `mix.lock` | Modify | `mix deps.unlock --unused` after dep removal. |
| `lib/alethea/foundation.ex` | Create | Module-level `@moduledoc` for the foundation namespace. |
| `lib/alethea/foundation/tenant.ex` | Create | `Alethea.Foundation.Tenant` with `scope_query/2`. |
| `lib/alethea/foundation/accounts/professional.ex` | Create | `Alethea.Foundation.Accounts.Professional` schema + `register_professional/1`. |
| `lib/alethea/foundation/accounts/patient.ex` | Create | `Alethea.Foundation.Accounts.Patient` schema + `create_patient/2`, `update_patient/2`. |
| `lib/alethea/foundation/accounts/admin.ex` | Create | `Alethea.Foundation.Accounts.Admin` schema + `register_admin/1`. |
| `lib/alethea/foundation/accounts.ex` | Create | `Alethea.Foundation.Accounts` context module wrapping the three schemas. |
| `lib/alethea/ai/llm.ex` | Create | `Alethea.AI.LLM` behaviour. |
| `lib/alethea/ai/embeddings.ex` | Create | `Alethea.AI.Embeddings` behaviour. |
| `lib/alethea/ai/whisper.ex` | Create | `Alethea.AI.Whisper` behaviour. |
| `lib/alethea/ai/llm/fake.ex` | Create | Test/dev no-op adapter (returns `{:ok, default}`). |
| `lib/alethea/ai/embeddings/fake.ex` | Create | Test/dev no-op adapter. |
| `lib/alethea/ai/whisper/fake.ex` | Create | Test/dev no-op adapter. |
| `lib/alethea/foundation/encryption/kek.ex` | Create | `Alethea.Foundation.Encryption.KEK` module. |
| `config/test.exs` | Modify | Add `config :alethea, :ai_llm, Alethea.AI.LLM.Fake` (and equivalents). |
| `test/support/foundation_test_helper.ex` | Create | `professional_fixture/1`, `patient_fixture/2`. |
| `test/alethea/foundation/tenant_test.exs` | Create | Tenant helper test. |
| `test/alethea/foundation/accounts/professional_test.exs` | Create | Professional schema + registration tests. |
| `test/alethea/foundation/accounts/patient_test.exs` | Create | Patient schema + tenant FK tests. |
| `test/alethea/foundation/accounts/admin_test.exs` | Create | Admin schema + role validation tests. |
| `test/alethea/ai/llm_test.exs` | Create | Behaviour existence + Fake adapter round-trip. |
| `test/alethea/ai/embeddings_test.exs` | Create | Behaviour existence + Fake round-trip. |
| `test/alethea/ai/whisper_test.exs` | Create | Behaviour existence + Fake round-trip. |
| `test/alethea/foundation/encryption/kek_test.exs` | Create | Round-trip, tampered ciphertext, version mismatch, empty inputs. |
| `test/alethea_web/api_spec_absence_test.exs` | Create | Smoke test: `mix.exs` does not contain `open_api_spex`. |
| `openspec/sdd/bootstrap-alethea-v2/05-no-go.md` | Create | No-go manifest. |
| `openspec/sdd/bootstrap-alethea-v2/06-migration-rule.md` | Create | Migration archival rule. |
| `priv/repo/migrations/*.exs` | **Untouched** | No deletion in this change. |
| `lib/alethea_web/controllers/page_controller_test.exs` | **Untouched** | Pre-existing failure out of scope. |

## Interfaces / Contracts

```elixir
# Tenant scope
@spec Alethea.Foundation.Tenant.scope_query(Ecto.Queryable.t(), binary()) :: Ecto.Query.t()

# AI behaviours (just the @callback shapes)
@callback Alethea.AI.LLM.chat([%{role: :user | :assistant | :system, content: String.t()}], keyword()) ::
  {:ok, %{content: String.t(), usage: map() | nil, model: String.t()}} | {:error, term()}
@callback Alethea.AI.LLM.generate(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}

@callback Alethea.AI.Embeddings.embed(String.t() | [String.t()], keyword()) ::
  {:ok, [float()]} | {:ok, [[float()]]} | {:error, term()}
@callback Alethea.AI.Embeddings.model() :: String.t()
@callback Alethea.AI.Embeddings.dimensions() :: pos_integer()

@callback Alethea.AI.Whisper.transcribe(binary() | String.t(), keyword()) ::
  {:ok, %{text: String.t(), segments: [%{start: number(), end: number(), text: String.t()}], language: String.t() | nil}}
  | {:error, term()}

# Encryption
@type Alethea.Foundation.Encryption.KEK.dek :: binary()
@type Alethea.Foundation.Encryption.KEK.kek :: binary()
@spec Alethea.Foundation.Encryption.KEK.generate() :: kek()
@spec Alethea.Foundation.Encryption.KEK.wrap(dek(), kek()) ::
  {:ok, binary()} | {:error, :invalid_kek | :invalid_dek}
@spec Alethea.Foundation.Encryption.KEK.unwrap(binary(), kek()) ::
  {:ok, dek()} | {:error, :invalid_kek | :corrupted | :version_mismatch}
```

## Testing Strategy

| Layer | What to Test | Approach |
|-------|-------------|----------|
| Schema | `register_professional/1`, `create_patient/2`, `register_admin/1` — happy path, validation, FK | `ExUnit.Case` + `Ecto.Adapters.SQL.Sandbox`; insert/delete in transaction. |
| Tenant helper | `scope_query/2` returns a query that filters correctly; `nil` raises | Pure function test, no DB. |
| Behaviour | Existence + `behaviour_info(:callbacks)` + Fake adapter round-trip | One test per behaviour. |
| Encryption | Round-trip, tampered ciphertext, version mismatch, empty inputs, determinism check | Pure function tests, no DB. |
| Smoke | `mix.exs` does not contain `open_api_spex`; the three files are gone | File-content assertion. |
| Regression | `mix test` exits with the pre-existing baseline (224 + 1 fail + 5 skip) | Final task. |

## Migration / Rollout

**No data migration.** This is a parallel-additive change. There is no production DB to migrate; the existing one (if any) is dev-only.

**Rollout steps:**
1. `mix deps.unlock --unused` to refresh the lock after dep removal.
2. `mix compile --warnings-as-errors` to ensure no stale references.
3. `mix format --check-formatted`.
4. `mix test` — expect 224 + 1 pre-existing failure + 5 skipped (same as baseline), with the new tests ADDED on top.

**Rollback:** single `git revert` of the bootstrap commit. The change is a single reviewable commit by design (small surface, see Review Workload Forecast).

## Open Questions

- [ ] **Foundation migrations**: do we want a `priv/repo/migrations/9999..._create_foundation_tables.exs` for the three new schemas in this change, or do we defer migration generation to the change that wires `Alethea.Foundation.Accounts` into the actual app? **Default decision: defer.** The schemas in this change are schemas-without-tables; they compile and test but no migration creates them. The `psicologo-foundation` change generates the migration when it actually uses the schemas. This avoids creating unused tables.
- [ ] **Naming of the foundation tables**: `foundation_professionals` vs `professionals` (which would shadow legacy). **Default decision: `foundation_professionals` etc.** — but this is moot until migrations exist. Flagging so the future change picks intentionally.
- [ ] **Phone/telegram field in the new Patient schema**: spec includes `telegram_chat_id` but no `whatsapp_*` field. Legacy uses `whatsapp_number_hash` and `encrypted_whatsapp_number`. **Default decision: foundation Patient has neither.** It is the profile shape from UBIQUITOUS_LANGUAGE.md; the Telegram chat_id is added by `telegram-paciente-foundation`. This is consistent with "this change does not implement Telegram."

These are noted as decisions the next change must ratify, not blockers for this change.
