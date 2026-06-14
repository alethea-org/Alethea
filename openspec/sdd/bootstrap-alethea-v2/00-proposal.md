# Proposal: bootstrap-alethea-v2

## Intent

The previous Alethea system is partially built and untidy: legacy code coexists with newer decisions, `open_api_spex` is still in `mix.exs` despite the decision to drop it, schema/field names reference WhatsApp despite ADR-004 mandating Telegram, and there is no clean foundation for the three upcoming changes (`telegram-paciente-foundation`, `psicologo-foundation`, and the AI/encryption slices). This change establishes a **clean foundation** for the v2 reset of Alethea so future changes can build on canonical primitives without refactoring legacy scaffolding.

This is foundational work, **not** a feature. No Telegram bot, no LLM calls, no triggers, no crisis, no RAG. The system must remain usable (login still works, 224 tests still pass) while new clean primitives are added alongside legacy code.

## Scope

### In Scope

| # | Deliverable | Notes |
|---|-------------|-------|
| 1 | **Dependency cleanup**: remove `open_api_spex` from `mix.exs`; remove `lib/alethea_web/api_spec.ex` and `lib/alethea_web/api_spec/schemas.ex` and `lib/alethea_web/controllers/open_api_spec_controller.ex`; `mix deps.unlock --unused`. | Per ADR-004 implication ("sin OpenApiSpex") and `CONTEXT.md` stack section. |
| 2 | **Schema migration rule proposal** (no destructive deletes in this change): document which old migrations are kept, which are marked as "do not re-run on a fresh DB" by archiving with a banner, and which are deleted. **No migration files are deleted in this change** — only the rule and a future-change pointer are produced. | Avoids silent data loss; safe pattern. |
| 3 | **Base schemas** (Ecto) for the three roles with canonical fields from `UBIQUITOUS_LANGUAGE.md`: `Alethea.Accounts.Professional`, `Alethea.Accounts.Patient`, `Alethea.Accounts.Admin` (new). Tenant FK pattern: `patient.professional_id` → `professionals.id`. **No** `JournalEntry`, `Trigger`, `CrisisEvent` — those are feature schemas for their own changes. | New schemas added in a parallel namespace (`Alethea.Foundation.*`) to avoid breaking legacy code. |
| 4 | **Tenant isolation primitive**: a single helper `Alethea.Foundation.Tenant.scope_query(query, professional_id)` that scopes a query to a tenant. No multi-tenancy library — just the FK + scope helper. | Satisfies the "psicólogo es el tenant" hard rule. |
| 5 | **`Alethea.AI` namespace skeleton** with three adapter behaviour modules: `Alethea.AI.LLM`, `Alethea.AI.Embeddings`, `Alethea.AI.Whisper`. **No implementations yet** — only `@callback` declarations so future adapters plug in. | Aligns with ADR-001/002/003 adapter-stable-interface pattern. |
| 6 | **`Alethea.Encryption` skeleton** with KEK/DEK envelope pattern (from archived issue 001): module `Alethea.Foundation.Encryption.KEK` with `wrap/2`, `unwrap/2`, `generate/0` callbacks, and typespecs. **Not integrated** with any schema. | Decoupled from legacy `Alethea.Encryption.Vault` which is production code; foundation is parallel. |
| 7 | **Test infrastructure baseline**: `mix test` runs cleanly. The 1 pre-existing failure (`page_controller_test.exs:6` — "Bienvenido a Alethea" assertion) is **documented as out of scope** for this change. Add a `test/support/foundation_test_helper.ex` with `tenant_fixture/1` and `professional_fixture/1`. | Strict TDD: every new module ships with its failing-then-passing test. |
| 8 | **Linting/format baseline**: confirm `.formatter.exs` is sane (it is — Phoenix HTMLFormatter, ecto imports). Decide on Credo: **out** for this change, document as future decision. | No Credo added; defer until post-bootstrap. |
| 9 | **No-go manifest** (`05-no-go.md`): explicit list of what this bootstrap does NOT include, with pointer to which future change owns each item. | Future changes need a clear "this is where to put it" pointer. |
| 10 | **`state.yaml` workflow state** for sdd-apply/verify tracking. | OpenSpec DAG survives compaction. |

### Out of Scope (deferred to named future changes)

- Telegram bot implementation → `telegram-paciente-foundation`
- LLM adapter concrete implementation → `ai-llm-groq-foundation`
- Embeddings adapter concrete implementation → `ai-embeddings-hf-foundation`
- Whisper adapter concrete implementation → `ai-whisper-groq-foundation`
- RAG ingestion pipeline → `rag-historia-clinica-foundation`
- Crisis detection / protocol → `crisis-protocol-foundation`
- Triggers (pasivos, activos, check-in) → `triggers-foundation`
- Psicólogo dashboard (LiveView) → `psicologo-foundation`
- Admin dashboard / billing → `admin-foundation`
- Multi-tenant complex (teams, orgs) → explicitly out per `PRD.md`
- Wearables integration → post-MVP per `CONTEXT.md`
- Gamification → out of MVP per `UBIQUITOUS_LANGUAGE.md`
- Notebooks (NotebookLM-like view) → `notebook-foundation`
- Full audit log of clinical access → deferred (basic audit exists)
- Migration file DELETION (only documented in this change)
- Renaming `whatsapp_number_hash` → `telegram_*` (deeply embedded; deferred to a dedicated rename change)
- Removing legacy `lib/alethea/whatsapp/`, `lib/alethea_jobs/`, `lib/alethea/alerts/`, `lib/alethea/clinical/` (out — this bootstrap builds parallel foundations, not refactors)

## Capabilities

### New Capabilities

- `accounts-foundation`: canonical schemas for the three roles and tenant scope helper.
- `ai-adapters-foundation`: three behaviour modules for LLM, Embeddings, Whisper — interfaces only.
- `encryption-foundation`: KEK/DEK envelope primitive module, not integrated with schemas.
- `dependency-cleanup`: removal of OpenApiSpex from runtime deps and code.

### Modified Capabilities

None at the spec level. This change is parallel/greenfield, not a modification of existing behavior. Legacy code stays untouched.

## Approach

**Parallel foundations, not refactor.** We add new modules under `Alethea.Foundation.*` namespace and remove only `open_api_spex` (which is explicitly out per stack decision). The legacy `Alethea.Accounts`, `Alethea.Clinical`, `Alethea.AI`, `Alethea.Encryption` stay — they are production code that today's 224 tests depend on. Future changes will incrementally migrate the legacy to the foundation, change-by-change.

**Strict TDD per task.** Every new module is introduced via: RED (failing test) → GREEN (minimum implementation) → REFACTOR. No implementation without a failing test first.

**Tenant primitive as a 30-line function**, not a library. A scope_query helper plus FK convention is sufficient for the "psicólogo es el tenant" rule in `CONTEXT.md`. We do not adopt a multi-tenancy library.

**Adapter behaviours only.** The three `Alethea.AI.*` modules define `@callback` declarations and typespecs. No implementation, no API call, no real HTTP. They are the contract surface that ADR-001/002/003 promise.

**KEK/DEK skeleton, not integration.** The encryption primitive is the function contract (`wrap/unwrap/generate`) plus typespecs. It is NOT wired into a Patient schema, NOT loaded by `Alethea.Accounts.create_patient/2`, and NOT connected to `Alethea.Encryption.Vault`. Wiring is a separate future change.

**Dependency cleanup is surgical.** Remove `open_api_spex` from `mix.exs`, delete the three files that import it, run `mix deps.unlock --unused`. Nothing else.

## Affected Areas

| Area | Impact | Description |
|------|--------|-------------|
| `mix.exs` | Modified | Remove `{:open_api_spex, "~> 3.18"}` from `deps/0`. |
| `lib/alethea_web/api_spec.ex` | Deleted | Was the OpenApiSpex plug. No callers in routes (verify before delete). |
| `lib/alethea_web/api_spec/schemas.ex` | Deleted | OpenApiSpex schemas. |
| `lib/alethea_web/controllers/open_api_spec_controller.ex` | Deleted | OpenApiSpex controller. |
| `lib/alethea/foundation/` | New | New namespace: `accounts/`, `encryption/`, `tenant.ex`. |
| `lib/alethea/ai/llm.ex` | New | Behaviour module, `@callback chat/2` etc. |
| `lib/alethea/ai/embeddings.ex` | New | Behaviour module, `@callback embed/1`. |
| `lib/alethea/ai/whisper.ex` | New | Behaviour module, `@callback transcribe/1`. |
| `test/alethea/foundation/` | New | TDD tests for foundation modules. |
| `test/support/foundation_test_helper.ex` | New | Fixtures: `professional_fixture/1`, `tenant_fixture/1`. |
| `mix.lock` | Modified | By `mix deps.unlock --unused`. |
| `openspec/sdd/bootstrap-alethea-v2/` | New | This change's artifacts + `state.yaml`. |
| `priv/repo/migrations/` | **Untouched** | Rule documented, no deletion in this change. |
| `test/alethea_web/controllers/page_controller_test.exs` | **Untouched** | Pre-existing failure out of scope. |

## Risks

| Risk | Likelihood | Mitigation |
|------|------------|------------|
| Removing `open_api_spex` breaks a route or plug we missed. | Low | Task includes grep across `lib/` for `OpenApiSpex` before deletion. If any caller exists, defer removal and flag. |
| Parallel `Alethea.Foundation.*` causes confusion ("which Accounts do I use?"). | Medium | README comment in `lib/alethea/foundation/accounts/` pointing at the legacy → foundation migration plan. Future changes migrate piece by piece. |
| `state.yaml` diverges from OpenSpec convention (orchestrator put it in `openspec/sdd/`, not `openspec/changes/`). | Low | This is intentional per orchestrator instruction. Note in the file itself. |
| Pre-existing test failure (`page_controller_test.exs:6`) gets accidentally "fixed" and breaks test count expectation. | Low | Task explicitly says: do NOT modify that test. Document it in the no-go manifest. |
| KEK/DEK skeleton overlaps conceptually with legacy `Alethea.Encryption.PatientVault` / `ProfessionalKek` but has different API shape. | Medium | Typespecs and `@moduledoc` must make the boundary explicit: foundation is the v2 contract, legacy is v1. Future migration change renames and replaces. |
| Strict TDD on a "skeleton-only" change may feel like over-testing (3 callback modules, ~20 lines of declarations). | Low | Each behaviour gets one test: "the module exists and exports the expected callbacks." That's the RED. GREEN is `use @behaviour` declarations. |
| `mix deps.unlock --unused` may touch more than `open_api_spex`. | Low | Task scopes the unlock to one dep. If lock file changes are broader, document and proceed. |

### ADR contradictions found

**None.** All four ADRs are respected:
- ADR-001: `Alethea.AI.LLM` is the stable interface — ✅
- ADR-002: `Alethea.AI.Embeddings` is the stable interface — ✅
- ADR-003: RAG = historia clínica navegable — not touched in this change (deferred). ✅
- ADR-004: Telegram único canal — this change does NOT add a Telegram bot, but it does NOT remove the legacy `lib/alethea/whatsapp/` either (out of scope). The bootstrap creates the empty seat for the Telegram adapter, not the adapter itself.

### Language gaps flagged

- **"Fundación" / "Foundation"**: not in `UBIQUITOUS_LANGUAGE.md`. Proposal: this is a meta-namespace, not a domain term. The canonical language is the domain (Paciente, Psicólogo, etc.). The foundation is plumbing. **Recommendation: do NOT add to UBIQUITOUS_LANGUAGE.md.** If the user disagrees, add it as a section header in a future housekeeping change.
- **"Tenant"** IS in UBIQUITOUS_LANGUAGE.md (synonym of Psicólogo at the data level). ✅

## Rollback Plan

1. `git revert` the single commit that removes `open_api_spex` (one dep, three files, one `mix.lock` change).
2. Delete `lib/alethea/foundation/`, `lib/alethea/ai/llm.ex`, `lib/alethea/ai/embeddings.ex`, `lib/alethea/ai/whisper.ex`, and `test/alethea/foundation/`.
3. Run `mix test` — should return to 224 tests, 1 pre-existing failure, 5 skipped (the pre-bootstrap baseline).
4. No data migrations, no schema changes, no production state. This is a non-destructive, additive-with-one-removal change.

## Dependencies

- Existing `mix.exs` must keep `cloak_ecto` (encryption skeleton sits alongside it; not a duplicate, different abstraction layer).
- Existing `Ecto`, `Postgrex`, `pgvector` stay.
- No new runtime deps are added in this change. (Adding an HTTP client, LlamaIndex-style lib, etc. is out of scope.)

## Success Criteria

- [ ] `mix test` reports 224 tests + 1 pre-existing failure + 5 skipped (no regression, no new failures).
- [ ] `mix compile --warnings-as-errors` is clean.
- [ ] `mix format --check-formatted` passes.
- [ ] `open_api_spex` is not in `mix.lock` and is not in `mix.exs`.
- [ ] `Alethea.Foundation.Accounts.{Professional,Patient,Admin}` exist with the canonical fields from `UBIQUITOUS_LANGUAGE.md` and at least one passing test each.
- [ ] `Alethea.Foundation.Tenant.scope_query/2` exists and is tested.
- [ ] `Alethea.AI.{LLM,Embeddings,Whisper}` exist as behaviour modules with `@callback` declarations and one existence test each.
- [ ] `Alethea.Foundation.Encryption.KEK` exists with `wrap/2`, `unwrap/2`, `generate/0` and a round-trip test using a test KEK.
- [ ] `05-no-go.md` exists and lists every deferred item with the future-change name that owns it.
- [ ] `state.yaml` exists with the workflow phase markers.
- [ ] Every new module has its failing test committed before its implementation (RED-GREEN-REFACTOR verifiable in git log).
