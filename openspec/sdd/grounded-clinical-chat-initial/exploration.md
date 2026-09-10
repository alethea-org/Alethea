# Exploration — grounded-clinical-chat-initial (#223)

**Status:** exploration complete
**Date:** 2026-09-10
**Parent issue:** #223 — Consulta clínica fundamentada inicial (implementation projection of approved spec #221)
**Sub-issues:** #226 (contract) → #227 (LiveView shell) → #232 (retrieval + freshness) → #234 (initial response)
**Authority:** ADR-010, ADR-003, `openspec/UBIQUITOUS_LANGUAGE.md`, spec issue #221

## Executive summary

The RAG retrieval layer from #196 (`Alethea.ClinicalRecord.Rag.Retrieval.search/4` + `metadata/2` + `freshness/1`) already provides patient-scoped, structurally-isolated retrieval with a freshness signal and index-level exclusion of tombstoned/discarded material. The initial grounded chat should be built as a new Phoenix-free `Alethea.ClinicalRecord.Consultation` context (behaviour + typed `Answer`/`Source` structs + `Consultation.Fake`) with LLM synthesis behind a new `Alethea.AI.Chains.ClinicalConsultationChain`, sliced exactly as #226 contract → #227 shell → #232 real retrieval adaptation → #234 integration + clinical-search retirement.

## Current state (file:line)

### RAG retrieval — delivered by #196 (`sdd/archive/2026-09-04-clinical-rag-projection`)

- `lib/alethea/clinical_record/rag/retrieval.ex`
  - `search/4(%Professional{}, patient_id, query, opts) :: {:ok, envelope} | {:error, :unauthorized | term()}`
  - `envelope = %{results: [result], chunk_count: non_neg_integer, freshness: %{stale?: boolean, pending: non_neg_integer}}`
  - `result = %{chunk_id, source_resource_type (raw string), source_resource_id, source_occurred_at, target_behavior_id | nil, chunk_index, full_event, content (decrypted plaintext), dense_distance, lexical_score, score}`
  - opts: `:candidate_limit` (50 — ANN window), `:limit` (10), `:dense_weight` (0.7), `:lexical_weight` (0.3). Whole-patient chunk table is the search space, so "complete indexed history" (#232) is satisfied structurally; only the top-50 ANN candidates get scored (a recall bound, acceptable).
  - `metadata/2` → `{:ok, %{chunk_count, freshness}}` | `{:error, :unauthorized | :unavailable}`; authorizes + returns cheap counts, never embeds/decrypts. This is what a shell should call on mount.
  - `freshness/1` (retrieval.ex:302) — ONE `oban_jobs` query: `worker == "AletheaJobs.ClinicalRecordOutboxWorker"`, `state in ~w(available scheduled executing retryable)`, `args->>'patient_id'` match. `stale?: pending > 0`. **Freshness is global per patient** — any pending clinical-record outbox job blocks all consultation.
- Authz primitive: `Alethea.Accounts.get_patient_for_professional/2` (accounts.ex:163) — `id == ? AND professional_id == ? AND status != "deleted"`. Tenant-isolation check every patient-scoped surface uses.
- Per-patient isolation is **structural**: `fetch_candidates/3` `WHERE patient_id` before ANN `ORDER BY`/`LIMIT`; decrypt happens strictly **after** the SQL `LIMIT`; a decrypt failure on an in-window candidate **raises** (fail-loud).
- **CRITICAL**: `search/4` is a pure RANKING function — no relevance/sufficiency cutoff. "no-evidence" is not a retrieval concept. Today `AletheaWeb.PatientLive.ClinicalSearch` hardcodes `@relevance_threshold 0.35` **in the view** (clinical_search.ex:69) to split `:never_indexed` (`chunk_count == 0`) from `:no_match`. #226/#232 must move this evidence-sufficiency judgment into the domain contract and document it as an explicit product decision.

### Freshness / tombstone / discarded-material interaction (#197 ∩ #196)

- Exclusion happens at **index level**, not query time. `lib/alethea/clinical_record/rag/indexer.ex:72`: `eligibility("clinical_record_legally_deleted") -> {:tombstone, :legal_deletion}` → `replace_chunks(resource, [])` deletes all chunks for that resource. `ai_proposal_edited` / `ai_proposal_discarded` → `{:ignore, :not_accepted}`, never indexed; only `ai_proposal_accepted` is indexed.
- Wiring is **live**: `AletheaJobs.ClinicalRecordOutboxWorker` (clinical_record_outbox_worker.ex:42) → `Indexer.index_event/1`. `Alethea.ClinicalRecord.Retention` (retention.ex:266) emits `clinical_record_legally_deleted` via `Outbox.tombstone_event/4` (outbox.ex:66). `Alethea.ClinicalRecord.Tombstone.for_resource/2` gates the authoritative record.
- **Conclusion**: #232 does NOT need query-time tombstone re-filtering on the normal path — freshness covers the delete-propagation race window. **Risk**: an Oban `cancelled`/`discarded` deletion job (not in `@pending_states`) leaves an orphan retrievable chunk that freshness will not flag; consider a query-time `Tombstone` cross-check or a scenario in #232.

### AI orchestration + chain conventions

- `Alethea.AI.Chains.ChainBehaviour` (chain_behaviour.ex): `run/1 :: {:ok, map} | {:error, term}`; optional `run/2`, `run!/1`, `suggested_system_prompt/0`, `suggested_max_tokens/0`, `supported_providers/0`.
- Concrete chains: `SessionSummaryChain`, `WeeklySummaryChain`, `PatternProposalChain` (newest, built for #195). Pattern: pure `build_prompt/1`, pure `parse_*/1` (degrades to `[]` on bad JSON, never raises), private `do_run/2` with `[:alethea,:ai,:chain,:start|:stop]` telemetry, `LLMConfig.get_and_build(:name) -> {:ok, config, llm}`.
- `Alethea.AI.LLMConfig` (llm_config.ex): `@type chain_name` enum at :26 (add `:clinical_consultation`), `chain_module/1` clause at :232. Providers `:local` (`OllamaChat`, `phi4-mini`) or `:cloud` (`ChatOpenAI`, Groq endpoint). `temperature: 0.0` default.
- `Alethea.AI.StructuredOutput` — `json_instruction/0`, `with_json_format/1`, `with_schema/2`, `parse_json_response/1`.
- **Controlled-fake mechanism (exactly what #226 needs)**: `config/test.exs:27-30` wires `config :alethea, :pattern_proposal_chain, Alethea.AI.PatternProposalChainMock`; `test/test_helper.exs:10-12` `Mox.defmock(Alethea.AI.PatternProposalChainMock, for: Alethea.AI.Chains.ChainBehaviour)`; worker: `defp pattern_proposal_chain, do: Application.get_env(:alethea, :pattern_proposal_chain, DefaultChain)` (ai_proposal_worker.ex:43), then `chain().run(%{...})`.
- Embeddings: discovery via `Alethea.AI.embeddings()` (ai.ex:50) reading `config :alethea, :ai_embeddings` (default `Alethea.AI.Embeddings.Fake` — deterministic hashed 1024-dim vectors). `Alethea.AI.EmbeddingsMock` also defined (Mox, test_helper.exs:20).
- `Alethea.AI.Sanitizer.sanitize/1` (sanitizer.ex) redacts email/SSN/phone/document-id. Security Mandate 5: sanitize before ANY external LLM. If the consultation chain runs `:cloud`, patient evidence excerpts leave the box → must sanitize first OR pin consultation to `:local`. **Design decision for #226.**
- `Alethea.AI.ConversationMemory` (conversation_memory.ex) — ETS per-session store, 10 msgs, used by patient journaling. ADR-010 decision 6 + #227 forbid ETS/DB/browser/audit/metadata persistence → consultation follow-up context MUST live only in LiveView socket assigns, lost on remount. Do NOT reuse `ConversationMemory`.

### Authorized LiveView patterns

- `AletheaWeb.PatientLive.ClinicalSearch` (clinical_search.ex) — **the surface #223/#221/#227 retire**. Route: `live "/patients/:patient_id/clinical-search", PatientLive.ClinicalSearch, :index` (router.ex:127) inside `live_session :require_authenticated_professional` (router.ex:111-136, `on_mount [{ProfessionalAuth, :mount_current_professional}, {ProfessionalAuth, :require_authenticated_professional}]`). Thin shell over `Retrieval`; never touches `Repo`/`PatientVault`/`Accounts.load_*`. `mount` authorizes via `Retrieval.metadata/2`; `stream(:results, ..., reset: true)` per query; persistent non-authoritative badge; `source_kind_label/1` human labels; `source_link/2` links to `TargetBehaviorLive.Review` only when `target_behavior_id` present.
- `AletheaWeb.TargetBehaviorLive.Review` (review.ex, #195) — canonical authorized per-patient LiveView. `mount(%{"patient_id" => ...})` → `socket.assigns.current_professional` (from `on_mount`), context returns `{:error, :unauthorized}` → `push_navigate(to: ~p"/patients")`. Every `handle_event/3` re-reads `current_professional` from assigns, never from params.
- `lib/alethea_web/live/dashboard_live/components/patient_search.ex` = patient PICKER, unrelated — keep.

### OpenSpec state

No existing change dir for this feature. Repo convention: active changes at `openspec/sdd/{change-name}/` (`proposal.md`, `exploration.md`, `spec.md`, `design.md`, `tasks.md`, `verify-report.md`), archived at `openspec/sdd/archive/YYYY-MM-DD-{name}/`. `openspec/config.yaml`: `artifact_store: hybrid`, `strict_tdd: true`, `test_command: "mix test"`, `review_budget_threshold: 400`. The shared `openspec-convention.md` says `openspec/changes/` but this repo has no such dir — use `openspec/sdd/`.

## Approaches compared — the #226 orchestration seam

### A. New `Alethea.ClinicalRecord.Consultation` context — behaviour + typed result structs (RECOMMENDED)

`answer/4` → `%Answer{outcome: :synthesis | :no_evidence | :stale | :provider_failure, synthesis, sources: [%Source{excerpt, kind, occurred_at, reference}], pending}`; `Consultation.Live` real + `Consultation.Fake`; swap via `config :alethea, :clinical_consultation`; LLM behind new `Alethea.AI.Chains.ClinicalConsultationChain` + Mock.

- **Pros:** Screaming/hexagonal — consultation is a ClinicalRecord read concern beside `Rag.Retrieval`; core stays Phoenix-free; `outcome` atom + struct give exhaustive downstream matching and a stable "outcome vocabulary" (#226 wording); LLM isolated behind existing ChainBehaviour + Mox proves "server-derived citations, model cannot fabricate" by construction; `Consultation.Fake` lets #227 ship before #232; `Alethea.AI` legacy/discovery namespace untouched.
- **Cons:** New sub-namespace; two indirections (Consultation behaviour + Chain behaviour); more files.
- **Effort:** Medium.

### B. Context function returning tagged tuples on an existing module

`Alethea.AI.ClinicalConsultation.answer/4` → `{:ok, :synthesis, map} | {:no_evidence, map} | {:stale, %{pending: n}} | {:provider_failure, map}`.

- **Pros:** Lighter, fewer files; matches pervasive `{:ok,_}|{:error,_}` idiom; chain-swap fake mechanism already lives in `Alethea.AI`.
- **Cons:** 4+ variant tagged tuples are weakly typed and error-prone downstream; #226 explicitly wants "a deep public interface" with a fixed outcome vocabulary — a named struct serves that better; puts clinical orchestration inside the adapter-discovery/legacy-LLM namespace (against that module's stated purpose); awkward to give #227 a clean fake before #232.
- **Effort:** Low-Medium.

**Seam location:** `lib/alethea/clinical_record/consultation/` — NOT `lib/alethea/ai/`. Authz + retrieval + freshness gating is ClinicalRecord domain logic; only the synthesis step delegates to `Alethea.AI` via `ChainBehaviour`.

## Recommendation

**Approach A.** Ship #226 as `Alethea.ClinicalRecord.Consultation` (behaviour + `Answer`/`Source` structs + `Consultation.Fake`) plus an `Alethea.AI.Chains.ClinicalConsultationChain` skeleton (grounding/no-fallback system prompt, pure `build_prompt`/`parse`, `ClinicalConsultationChainMock`). **Sources are always derived server-side from the `Retrieval.search/4` envelope**; the chain only turns already-retrieved excerpts into synthesis prose. Relocate the evidence-sufficiency threshold out of the `ClinicalSearch` view into the contract, documented as an explicit product decision.

## Slice boundaries (map to sub-issues)

- **#226 (A1)** — `consultation.ex` (behaviour + `answer/4` typed contract), `consultation/answer.ex`, `consultation/source.ex`, `consultation/fake.ex`; `Alethea.AI.Chains.ClinicalConsultationChain` + `LLMConfig` `:clinical_consultation` clause; `config :alethea, :clinical_consultation` + `:clinical_consultation_chain`; `Mox.defmock` in `test_helper.exs`. Tests: 4 outcome variants via fakes; model cannot inject sources. No LiveView, no retrieval change.
- **#227 (A2)** — `lib/alethea_web/live/consultation_live.ex` + route in the `:require_authenticated_professional` live_session. Consumes `Consultation.Fake` only. Visible states: idle, retrieving, synthesis, indexed-no-evidence, stale-pending, provider-error. No persistence; reset on remount/logout/new conversation (socket assigns only). Does NOT retire clinical-search yet. LiveView tests: visible states + reset.
- **#232 (A3)** — implement `Consultation.Live`: `get_patient_for_professional/2` (authorize-before-retrieve) → fresh `Retrieval.search/4` every turn → map envelope: `freshness.stale?` → `:stale`; no results / all below evidence threshold → `:no_evidence`; else → chain call, build `Source` list from envelope. No general-knowledge fallback. Tests: authz-before-retrieve, fresh-per-turn, block semantics, cross-patient/tenant isolation, zero source mutation.
- **#234 (A4)** — point `ConsultationLive` at real `Consultation.Live` (dev/prod config); render "Síntesis basada en evidencia" + "Fuentes" (each: exact excerpt, kind, date, stable reference); provider-error safe state; RETIRE `PatientLive.ClinicalSearch` route + nav entry. Integration LiveView tests.

## Risks

1. Evidence-sufficiency ("no-evidence") is a product judgment currently hardcoded at 0.35 in a view; relocating and calibrating it risks false blocks or false answers.
2. `ConversationMemory` ETS store is tempting for follow-ups but forbidden by ADR-010 decision 6 + #227 — follow-up context must stay in socket assigns.
3. Sanitizer: `:cloud` synthesis sends patient excerpts to Groq (Security Mandate 5). Must sanitize first or pin `:local`.
4. Freshness is global per patient — any pending clinical-record outbox job blocks ALL consultation until the queue drains (matches ADR-010 decision 5 but surprising UX).
5. Orphan-chunk edge: a cancelled/discarded legal-deletion outbox job leaves a retrievable chunk that freshness will not flag; consider a query-time `Tombstone` cross-check in #232.
6. ADR-010 decision 2 "Hipótesis para revisar" is in the #221 surface contract but the 4 sub-issues focus on Síntesis + Fuentes — confirm hypothesis mode is deferred in `sdd-propose`.
7. `source_occurred_at` for clinical notes is derived from `inserted_at`, not a real clinical event date (pre-existing from #196) — citation "date" may mislead.
8. Four slices; keep each a separate PR under the 400-line review budget.

## Key learnings

1. The `Retrieval.search/4` envelope already carries per-patient freshness and structural isolation, so the consultation contract only needs to map its outcomes.
2. Retrieval performs no relevance cutoff, so the "no-evidence" decision currently lives as a hardcoded 0.35 threshold inside the ClinicalSearch LiveView.
3. Tombstoned and discarded clinical material is excluded at index build time by the wired outbox worker, not by any query-time filter.
4. The existing chain-swap plus Mox-against-ChainBehaviour pattern is exactly the controlled-fake mechanism issue #226 requires for typed outcomes.
5. ADR-010 and issue #227 forbid ETS persistence, so the chat's bounded follow-up context must live only in LiveView socket assigns.
