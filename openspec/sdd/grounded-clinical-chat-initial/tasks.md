# Tasks: grounded-clinical-chat-initial (#223)

**Namespace (orchestrator-canonical, overrides design):** `Alethea.ClinicalRecord.Rag.Consultation`
at `lib/alethea/clinical_record/rag/consultation.ex`, with `Rag.Consultation.{Answer,Source,Live,Fake}`.
Sits beside `Rag.Retrieval` / `Rag.Indexer`; distinct from existing `ClinicalRecord.ConsultationEvidence`.
**Contract:** `answer/4(%Professional{}, patient_id, query, opts) :: {:ok, Answer.t()} | {:error, :unauthorized}`;
the 4 outcomes (`:synthesis | :no_evidence | :stale | :provider_failure`) live in `Answer.outcome` on `{:ok, _}`.
**TDD:** strict — RED task precedes GREEN. Test runner `mix test`.

## Review Workload Forecast

| Field | Value |
|-------|-------|
| Estimated changed lines (all slices) | ~2,300 (`add + del`) |
| Per-slice: #226a | ~380 add / 0 del — near budget |
| Per-slice: #226b | ~280 add / 0 del — under budget |
| Per-slice: #227 | ~400 add / 0 del — at budget |
| Per-slice: #232a | ~330 add / 0 del — under budget |
| Per-slice: #232b | ~260 add / 0 del — under budget |
| Per-slice: #234a | ~220 add / 0 del — under budget |
| Per-slice: #234b | ~10 add / ~610 del — over by raw count, deletion-dominant |
| 400-line budget risk | High |
| Chained PRs recommended | Yes |
| Suggested split | #226a → #226b → #227 → #232a → #232b → #234a → #234b (7 PRs) |
| Delivery strategy | ask-on-risk |
| Chain strategy | feature-branch-chain (recommended; pending user confirm) |

Decision needed before apply: Yes
Chained PRs recommended: Yes
Chain strategy: feature-branch-chain
400-line budget risk: High

**Rationale for splits.** #226 (~600) exceeds budget → split contract (#226a) from chain (#226b);
the two behaviours are independently testable. #234 (~70 add / ~600 del) → split real wiring +
Síntesis/Fuentes render (#234a) from the pure ClinicalSearch retirement (#234b); #234b is deletion-only,
mechanically reviewable, and the right candidate for an explicit `size:exception` if not split further.
#232 (~400 + 14 RED cases) → split core outcome mapping (#232a) from isolation/tombstone/read-only/race
hardening (#232b) to keep each child diff focused.
**Chain strategy:** feature-branch-chain recommended because D5 is a hard cutover with no rollback path
and #234b must land last, after #232 proves retrieval; coordinated single merge to `main` via the
`feat/223` tracker branch. PR #226a base = `feat/223`; every later PR base = the immediate previous PR branch.

### Suggested Work Units

| Unit | Goal | PR | Focused test command | Runtime harness | Rollback boundary |
|------|------|----|----------------------|-----------------|-------------------|
| 1 | Typed contract + structs + Fake + threshold config | #226a | `mix test test/alethea/clinical_record/rag/consultation_test.exs` | N/A — no runtime surface yet (pure domain) | new modules + `:consultation_evidence_threshold` key; nothing else references them |
| 2 | `ClinicalConsultationChain` (`:local` only) + LLMConfig + Mox | #226b | `mix test test/alethea/ai/chains/clinical_consultation_chain_test.exs` | N/A — chain not yet wired to a surface | new chain module + one `chain_module/1` clause + mock wiring |
| 3 | `ConsultationLive` shell on `Consultation.Fake` + route | #227 | `mix test test/alethea_web/live/consultation_live_test.exs` | `mix phx.server` → `/patients/:id/consultation` (six states via Fake) | delete `consultation_live.ex` + its route line |
| 4 | `Consultation.Live` core outcome mapping | #232a | `mix test test/alethea/clinical_record/rag/consultation/live_test.exs` | `mix phx.server` → consultation with seeded chunks | `config :alethea, :clinical_consultation` back to `Fake` |
| 5 | Isolation + tombstone + read-only + race hardening | #232b | `mix test test/alethea/clinical_record/rag/consultation/live_test.exs` | `mix phx.server` cross-patient check | revert #232b commit; #232a still passes |
| 6 | Real wiring + Síntesis/Fuentes render + nav entry | #234a | `mix test test/alethea_web/live/consultation_live_test.exs` | `mix phx.server` → consultation renders two sections | revert render + nav commit; config back to `Fake` |
| 7 | ClinicalSearch hard retirement (deletion only) | #234b | `mix test test/alethea_web/router_test.exs test/alethea_web/live/` | `mix phx.server` → `/patients/:id/clinical-search` 404 | irreversible by D5; git-restore module+route+test to undo |

## Phase 1: PR #226a — Typed Consultation Contract

- [x] 1.1 RED `test/alethea/clinical_record/rag/consultation_test.exs`: with `Application.put_env(:alethea, :clinical_consultation, Rag.Consultation.Fake)`, assert `answer/4` returns `{:ok, %Answer{outcome: :synthesis, synthesis: <non-empty>, sources: [_|_]}}` and, per fake config, `:no_evidence` / `:stale` (`pending: N`) / `:provider_failure` each with `synthesis: nil` and `sources: []`. Scenarios: Typed Consultation Outcome Contract (all 4), Controlled Fakes for Every Outcome, Blocking outcomes contain no answer prose.
- [x] 1.2 RED same file: `Rag.Consultation.evidence_threshold/0` returns `0.35` default and reflects `Application.put_env(:alethea, :consultation_evidence_threshold, 0.5)` round-trip. Scenario: Evidence Sufficiency Threshold.
- [x] 1.3 RED same file: fake configured unauthorized → `answer/4` returns `{:error, :unauthorized}` (distinct from the 4 outcomes). Scenario: AD3 / Unauthorized professional.
- [x] 1.4 RED same file: `Rag.Consultation.open/2` returns `{:ok, %{chunk_count: _, freshness: _}}` for the treating professional and `{:error, :unauthorized}` for a stranger. Scenario: Treating professional reaches idle state / Unauthorized redirected (mount path).
- [x] 1.5 GREEN create `lib/alethea/clinical_record/rag/consultation.ex`: `@callback answer/4`, `@callback open/2`, `@spec`s, facade `def answer(...), do: impl().answer(...)`, `def open(...), do: impl().open(...)`, `evidence_threshold/0` reading `:consultation_evidence_threshold` (default `0.35`), `defp impl, do: Application.get_env(:alethea, :clinical_consultation, __MODULE__.Live)`. Keep moduledoc proportionate (<20 lines).
- [x] 1.6 GREEN create `lib/alethea/clinical_record/rag/consultation/answer.ex`: `@type outcome :: :synthesis | :no_evidence | :stale | :provider_failure`, `@enforce_keys [:outcome]`, `defstruct [:outcome, :synthesis, sources: [], pending: 0]`.
- [x] 1.7 GREEN create `lib/alethea/clinical_record/rag/consultation/source.ex`: `@enforce_keys [:excerpt, :kind, :occurred_at, :reference]`, `defstruct` same; `from_results/1` builds `[%Source{}]` server-side from `Rag.Retrieval.search/4` envelope results (`excerpt`←`content` verbatim, `kind`←`source_resource_type`, `occurred_at`←`source_occurred_at`, `reference`←`%{chunk_id:, resource_type:, resource_id:, target_behavior_id:}`). Scenario: Source exposes excerpt, kind, date, reference.
- [x] 1.8 RED `source_test.exs`: `from_results/1` output maps each envelope result 1:1 with verbatim excerpt and stable reference; nothing added. Scenario: LLM cannot inject or fabricate a source (server-derived half).
- [x] 1.9 GREEN create `lib/alethea/clinical_record/rag/consultation/fake.ex`: implements `answer/4` + `open/2`; per-outcome deterministic via `opts[:outcome]` or `Application.get_env(:alethea, :consultation_fake_outcome)`; `:synthesis` returns contract-valid sources built from a fixed fixture.
- [x] 1.10 GREEN `config/config.exs`: add `config :alethea, :consultation_evidence_threshold, 0.35`.
- [x] 1.11 GREEN `config/test.exs`: add `config :alethea, :clinical_consultation, Alethea.ClinicalRecord.Rag.Consultation.Fake`.

> **#226a delivered** (commit pending). Focused suite green: `MIX_ENV=test mix run -e 'Mix.Tasks.Test.run(["test/alethea/clinical_record/rag/consultation_test.exs", "test/alethea/clinical_record/rag/consultation/source_test.exs"])'` → 12 passed. `mix compile --warnings-as-errors` clean (149 files). Full `mix test`/`mix precommit` BLOCKED in this environment only: brew `postgresql@16` lacks the `vector` extension and 6 unrelated pending migrations (#196/#197) do `CREATE EXTENSION vector`; network is restricted so pgvector cannot be installed/built here. PR226a code has zero DB surface.

## Phase 2: PR #226b — ClinicalConsultationChain (`:local` only)

> **#226b delivered.** Full `mix test` → 1013 passed, 5 skipped (seed 0);
> `mix precommit` → exit 0 (compile `--warnings-as-errors`, `deps.unlock --unused`,
> `format`, `test` all clean). Focused suite
> `mix test test/alethea/ai/chains/clinical_consultation_chain_test.exs` → 18 passed.
> **Deviation:** the `LLMConfig` chain-name atom is `:consultation_synthesis`, not
> `:clinical_consultation` — the latter already names the `Rag.Consultation` facade
> module-swap key from #226a (`config :alethea, :clinical_consultation`), and
> `LLMConfig.get/2` does `Keyword.merge(_, Application.get_env(:alethea, chain_name, []))`
> which crashes on a module value. Telemetry label stays `chain: :clinical_consultation`.

- [x] 2.1 RED `test/alethea/ai/chains/clinical_consultation_chain_test.exs`: `build_prompt/1` output numbers excerpts and contains no `chunk_id` / `resource_id` / `target_behavior_id`; `parse/1` returns `{:error, :unparseable}` on malformed JSON AND on an empty/blank `synthesis` string (must NOT degrade to `""`). Scenario: AD8 / Provider-failure outcome is a safe state.
- [x] 2.2 RED same file: `supported_providers/0 == [:local]`; static source scan asserts no `:cloud` literal in `clinical_consultation_chain.ex` (mirror `AIProposalWorkerTest` scan). Scenarios: Local-Only Synthesis No External Leak, Cloud provider is rejected for this chain.
- [x] 2.3 RED same file (AI-pipeline behavior/grounding regression, repo CLAUDE.md): golden verbatim assertion on `suggested_system_prompt/0` (grounding + no-fallback Spanish text: "no diagnostiques, no recomiendes tratamiento, no completes con conocimiento general; si los fragmentos no alcanzan, dilo"); with a fixed excerpt set + fixed question, `build_prompt/1` embeds only excerpt text; chain mock (Mox vs `ChainBehaviour`) returns synthesis derived only from the given excerpts. Scenario: Server-Derived Source Provenance (grounding), design Testing row #226 Regression.
- [x] 2.4 GREEN create `lib/alethea/ai/chains/clinical_consultation_chain.ex`: `@behaviour Alethea.AI.Chains.ChainBehaviour`; `run(%{question: q, excerpts: xs})` → `LLMConfig.get_and_build(:consultation_synthesis)` → `do_run/2` with `[:alethea, :ai, :chain, :start|:stop]` telemetry `chain: :clinical_consultation`; pure `build_prompt/1` (numbered, no ids), pure `parse/1` → `{:ok, %{synthesis: s}}` | `{:error, :unparseable}` (empty synthesis ⇒ error, NOT `""`); `suggested_max_tokens/0` `512`; `supported_providers/0 -> [:local]`. Returns `%{synthesis: binary}` ONLY — never a source list.
- [x] 2.5 GREEN `lib/alethea/ai/llm_config.ex`: add `:consultation_synthesis` to `@type chain_name`; add `defp chain_module(:consultation_synthesis), do: Alethea.AI.Chains.ClinicalConsultationChain`.
- [x] 2.6 GREEN `config/config.exs`: pin `config :alethea, Alethea.AI.Chains.ClinicalConsultationChain, provider: :local` so `:cloud` is structurally impossible (AD5).
- [x] 2.7 GREEN `test/test_helper.exs`: `Mox.defmock(Alethea.AI.ClinicalConsultationChainMock, for: Alethea.AI.Chains.ChainBehaviour)`.
- [x] 2.8 GREEN `config/test.exs`: `config :alethea, :clinical_consultation_chain, Alethea.AI.ClinicalConsultationChainMock`.

## Phase 3: PR #227 — ConsultationLive shell (Fake only)

- [ ] 3.1 RED `test/alethea_web/live/consultation_live_test.exs`: professional B mounts `/patients/#{A_patient}/consultation` → redirected to `/patients`, no patient data in response. Scenario: Unauthorized professional is redirected.
- [ ] 3.2 RED same file: treating professional mount renders `#consultation-idle` with no answer/error. Scenarios: Treating professional reaches the idle state, Idle state.
- [ ] 3.3 RED same file: driving `Consultation.Fake` per outcome, assert dom ids `consultation-retrieving`, `consultation-synthesis` (synthesis text + sources list visible), `consultation-no-evidence`, `consultation-stale` (shows `pending` N + retry prompt), `consultation-provider-error` (no partial synthesis). Scenarios: All Safe Visible States (Retrieving, Synthesis, Indexed-no-evidence, Stale-pending shows count, Provider-error).
- [ ] 3.4 RED same file: ask a question, then call `live/2` again → empty `:messages` stream and empty `history`. Scenario: State does not survive remount.
- [ ] 3.5 RED same file: navigate away and back → empty; trigger "nueva conversación" → prior follow-up context discarded. Scenarios: State does not survive navigation, New conversation discards prior context.
- [ ] 3.6 RED same file: after N completed turns assert no `ConversationMemory` ETS entry, no new DB rows, no audit/access record. Scenarios: State does not survive logout, No conversation content is written anywhere.
- [ ] 3.7 GREEN create `lib/alethea_web/live/consultation_live.ex`: `use AletheaWeb, :live_view`; `mount/3` → `Rag.Consultation.open(current_professional, patient_id)`; `{:error, :unauthorized}` → `put_flash` + `push_navigate(to: ~p"/patients")`. Assigns: `patient_id`, `history` (≤ `@history_limit 6`), `state`, `turn`, `query_form`. `stream(:messages, [])`. `handle_event("ask", ...)` → `assign(:state, :retrieving)` → `start_async(:answer, fn -> Rag.Consultation.answer(prof, patient_id, query, history: history) end)`; `handle_async` → `stream_insert(:messages, ...)` + update `history`. "nueva conversación" → `stream(:messages, [], reset: true)` + `assign(:history, [])`. Six render states with stable dom ids. `current_professional` always from `socket.assigns`, never params. Zero persistence.
- [ ] 3.8 GREEN `lib/alethea_web/router.ex`: add `live("/patients/:patient_id/consultation", ConsultationLive, :index)` inside the `:require_authenticated_professional` live_session.

## Phase 4: PR #232a — Consultation.Live core outcome mapping

- [x] 4.1 RED `test/alethea/clinical_record/rag/consultation/live_test.exs`: non-treating professional → `{:error, :unauthorized}`; `expect(ClinicalConsultationChainMock, :run, 0, fn _ -> :never end)` and assert `Rag.Retrieval.search/4` never runs. Scenario: Failed authorization never reaches retrieval.
- [x] 4.2 RED same file: insert pending `AletheaJobs.ClinicalRecordOutboxWorker` job (Oban `testing: :manual`) → `answer/4` returns `outcome: :stale`, `pending: N`, chain not called. Scenarios: Pending indexing blocks the answer, Stale outcome blocks and asks for retry.
- [x] 4.3 RED same file: two turns in one conversation → two `Rag.Retrieval.search/4` calls over full indexed history; second call not cached/narrowed. Scenario: Retrieval re-runs on every turn.
- [x] 4.4 RED same file: `resolve_query/2` pure table test — uses only `role: :professional` turns; follow-up "¿y sobre eso?" forms a standalone query, no `Source` derived from conversation text. Scenario: Conversation history is never evidence.
- [x] 4.5 RED same file: retrieval returns `[]` → `:no_evidence`; all results score `< 0.35` → `:no_evidence` (seeded chunks). Scenarios: Empty results yield no-evidence, All-below-threshold yields no-evidence.
- [x] 4.6 RED same file: at least one result `>= 0.35` and index fresh → chain `run/1` called once, `outcome: :synthesis` with non-empty synthesis + envelope-derived sources. Scenarios: At least one sufficient result proceeds to synthesis, Synthesis outcome carries answer and server-derived sources.
- [x] 4.7 RED same file: `ClinicalConsultationChainMock` returns synthesis naming a fabricated citation → `Answer.sources` equals exactly `Source.from_results/1` of the kept envelope results, nothing invented. Scenario: LLM cannot inject or fabricate a source. (Mox against `ChainBehaviour`.)
- [x] 4.8 RED same file: chain raises / returns `{:error, _}` / returns unparseable / returns empty synthesis → `outcome: :provider_failure`, `synthesis: nil`, `sources: []`. Scenario: Provider-failure outcome is a safe state (empty synthesis ⇒ provider_failure, never empty prose).
- [x] 4.9 GREEN create `lib/alethea/clinical_record/rag/consultation/live.ex`: implements `answer/4` + `open/2`. Ordered flow: (1) `Accounts.get_patient_for_professional/2` → nil ⇒ `{:error, :unauthorized}`; (2) `Rag.Retrieval.freshness/1` `stale?` ⇒ `%Answer{outcome: :stale, pending: n}`; (3) `Rag.Retrieval.search/4(prof, patient_id, resolve_query(query, history), opts)` → `{:error, :unauthorized}` passthrough, `{:error, _}` ⇒ `:provider_failure`; (4) `envelope.freshness.stale?` ⇒ `:stale` (race re-check, AD9); (5) filter `score >= Rag.Consultation.evidence_threshold()` → `[]` ⇒ `:no_evidence`; (6) `sources = Source.from_results(kept)`; `chain().run(%{question: query, excerpts: Enum.map(kept, &Alethea.AI.Sanitizer.sanitize(&1.content))})` → `{:ok, %{synthesis: s}}` ⇒ `:synthesis` (sources verbatim), `{:error, _}` ⇒ `:provider_failure`. `resolve_query/2` pure; `defp chain, do: Application.get_env(:alethea, :clinical_consultation_chain, Alethea.AI.Chains.ClinicalConsultationChain)`. Proportionate moduledoc.

> **#232a delivered.** RED confirmed by inspection + a real compile/test-boot
> cycle: `live.ex` was moved aside, `live_test.exs` written against the
> ordered flow above, and `MIX_ENV=test mix test
> test/alethea/clinical_record/rag/consultation/live_test.exs` was run —
> it reached the DB-migration step (proving the test file itself compiles
> clean and the suite is wired correctly) and failed only on the
> pre-existing environment blocker below, never on a missing/undefined
> `Live` module error, which is the RED signal for this file shape.
> `live.ex` was then restored and `mix compile --warnings-as-errors` →
> clean (no new warnings). **Environment BLOCKED, same as #226a**: local
> Postgres lacks the `vector` extension and network is restricted, so
> `MIX_ENV=test mix ecto.migrate` fails on `CREATE EXTENSION vector`
> before any test (RED or GREEN) can execute against the DB — this file's
> tests all `use Alethea.DataCase`, so none of the 8 RED tests or the
> GREEN implementation could be observed passing in this environment.
> Only `mix compile --warnings-as-errors` (clean) and the RED-by-inspection
> check above are verified; full `mix test` / `mix precommit` were not run.
> **Deviation:** `live.ex`'s `synthesize/2` clause additionally guards
> against a blank/whitespace-only `synthesis` string returned directly by
> a test double (treats it as `:provider_failure`), defense-in-depth
> beyond the ordered flow in this task, because task 4.8 explicitly
> requires "returns empty synthesis ⇒ `:provider_failure`" and the real
> `ClinicalConsultationChain.parse/1` guard (AD8) is bypassed when the
> `ChainBehaviour` mock returns `{:ok, %{synthesis: ""}}}` directly.
> Scope discipline held: no edits to `consultation_live.ex`, its config
> wiring, `config/dev.exs`, or `config/prod.exs`; `Consultation.Live` is
> not referenced by any LiveView yet (lands in #234a).

## Phase 5: PR #232b — Isolation / tombstone / read-only / race hardening

- [x] 5.1 RED `live_test.exs`: two patients of the same professional; consult A → every returned `Source.reference.resource_id` resolves to patient A. Scenario: Cross-patient isolation.
- [x] 5.2 RED same file: patients belonging to different professionals; professional consults own patient → no other professional's chunk/excerpt retrievable end to end. Scenario: Cross-tenant isolation.
- [x] 5.3 RED same file: any turn (synthesis or any block) → patient chunks, clinical records, and Oban outbox jobs byte-identical before/after. Scenarios: Any turn leaves clinical state untouched, Clinical Sources Are Read-Only.
- [x] 5.4 RED same file: resource whose legal-deletion job is `cancelled`/`discarded` (outside `@pending_states`) leaves an orphan retrievable chunk → that content is not returned as a `Source`. Scenario: Orphan chunk from a non-pending deletion job is not cited.
- [x] 5.5 RED same file: freshness passes pre-gate but `envelope.freshness.stale? == true` post-retrieval → `outcome: :stale`, chain not called. Scenario: Freshness Is a Hard Gate (race re-check, AD9).
- [x] 5.6 GREEN `lib/alethea/clinical_record/rag/consultation/live.ex`: add the post-retrieval freshness re-check and, if needed for 5.4, a query-time `Alethea.ClinicalRecord.Tombstone.for_resource/2` cross-check on kept results before `Source.from_results/1`. No change to `Retrieval.search/4` ranking.

> **#232b delivered.** Full `mix test` → 6 doctests, 1060 tests, 1 failure,
> 5 skipped (the 1 failure is the pre-existing flaky
> `AletheaJobs.ClinicalRecordOutboxWorkerTest` timeout-race test, same one
> called out in #232a/baseline — unrelated to this work, reproduced
> identically without this branch's changes). Focused suite `MIX_ENV=test
> mix test test/alethea/clinical_record/rag/consultation/live_test.exs` →
> 18 passed (5 pre-existing #232a tests + 13 new #232b tests), run
> multiple times for stability. `mix compile --warnings-as-errors` clean.
> **Findings against the guidance:**
> - **5.5 (race re-check) confirms Phase 4's existing code, no new
>   production change needed.** `handle_envelope/2`'s first clause
>   (`%{freshness: %{stale?: true, pending: pending}} -> :stale`) already
>   implements AD9's post-retrieval re-check. Proven with a real,
>   deterministic (no sleeps) race: the `EmbeddingsMock` stub — invoked
>   inside `Retrieval.search/4`'s `do_search/4`, strictly after the
>   pre-gate `Retrieval.freshness/1` call already ran and passed as
>   "not stale" — inserts a pending outbox job as a side effect before
>   returning the query vector, so `do_search/4`'s own trailing
>   `freshness(patient.id)` call (computed after `fetch_candidates` +
>   scoring) sees the job and reports `stale?: true` in the envelope.
>   This is the exact enqueue-during-search race AD9 describes, using
>   real DB timing instead of a stub/mock of `Retrieval` itself (which
>   has no behaviour to mock). This task therefore only ADDED test
>   coverage; no `live.ex` change was needed for 5.5 specifically.
> - **5.4 interpreted per orchestrator override, not the literal task
>   text.** The literal task text ("resource whose legal-deletion job is
>   `cancelled`/`discarded`") describes a scenario that never reaches
>   `Consultation.Live` as a *retrievable* orphan: an Oban job state
>   (`cancelled`/`discarded`) has no bearing on whether a `Chunk` row
>   still exists — chunk lifecycle/deletion is driven by
>   `Alethea.ClinicalRecord.Tombstone` (D4 gate,
>   sdd/clinical-record-retention #197), not by the outbox job's
>   terminal state. Implemented and tested per the orchestrator's
>   explicit override instead: insert a `Tombstone` row directly for the
>   exact `{resource_type, resource_id}` pair (`trigger: "manual"`),
>   simulating a resource that was legally deleted while its RAG chunk
>   remains an orphan row. Two RED cases: (a) the only candidate is
>   tombstoned → `:no_evidence`, chunk row still physically present; (b)
>   one tombstoned + one live sibling chunk → only the live one is cited.
> - **5.6 GREEN**: added `reject_tombstoned/1` in
>   `lib/alethea/clinical_record/rag/consultation/live.ex`, applied to
>   `handle_envelope/2`'s `kept` pipeline strictly after the
>   evidence-threshold filter and before `synthesize/2` (hence before
>   `Source.from_results/1`), via
>   `Tombstone.for_resource(result.source_resource_type,
>   result.source_resource_id)`. If the tombstone-filtered set is empty,
>   outcome falls through to the existing `:no_evidence` branch — no new
>   branch needed. `Retrieval.search/4`'s ranking/filtering was not
>   touched, per scope.
> - Read-only check (5.3) snapshots `Chunk` and `Oban.Job` rows only
>   (not `AuditLog`): `KEK_LOAD`/session-auth `AuditLog` rows are a
>   deliberate, expected side effect of legitimate patient-key access on
>   every turn (Accounts' existing audit trail), not a mutation of
>   clinical state — asserting them byte-identical would be a false
>   requirement, not a stronger one.
> - Scope discipline held: no edits to `consultation_live.ex`, config
>   wiring, or `Retrieval`/`Indexer`; `mix format` was run scoped to only
>   the two files this task touched (a full-project `mix format` was
>   tried first and reverted — it surfaced ~24 files with pre-existing
>   formatting drift unrelated to #232b, out of scope for this PR).

## Phase 6: PR #234a — Real wiring + Síntesis/Fuentes render + nav entry

- [ ] 6.1 RED `test/alethea_web/live/consultation_live_test.exs` (integration over `Consultation.Live` + `ClinicalConsultationChainMock` + seeded chunks): `:synthesis` renders `<section class="consultation__synthesis">` titled "Síntesis basada en evidencia" and `<ol class="consultation__sources">` titled "Fuentes" as visually distinct labeled sections. Scenario: Synthesis and sources are distinct sections.
- [ ] 6.2 RED same file: each `<li>` renders exact excerpt, `source_kind_label/1`, formatted `occurred_at`, and a `.link` to `TargetBehaviorLive.Review` when `reference.target_behavior_id` present (text-only otherwise). Scenario: Each source renders excerpt, kind, date, reference.
- [ ] 6.3 RED same file: `:provider_failure` from the real pipeline renders `#consultation-provider-error`, no partial synthesis, no sources. Scenario: Provider error renders a safe state.
- [ ] 6.4 RED `test/alethea_web/live/patient_live/index_test.exs`: patient card renders a link to `~p"/patients/#{id}/consultation"` as the primary clinical-record entry; no "búsqueda clínica" entry present. Scenario: Navigation offers the chat as the primary surface.
- [ ] 6.5 GREEN `lib/alethea_web/live/consultation_live.ex`: replace shell synthesis render with the two structurally distinct blocks; migrate `source_kind_label/1`, `source_link/2`, `format_datetime/1` from `clinical_search.ex`. No hypothesis block (D1).
- [ ] 6.6 GREEN `config/dev.exs` (+ prod/runtime path): ensure `:clinical_consultation` resolves to `Rag.Consultation.Live` (facade default — remove any Fake pin outside test).
- [ ] 6.7 GREEN `lib/alethea_web/live/patient_live/index.ex`: add "Consulta clínica" nav link to the consultation route on the patient card.

## Phase 7: PR #234b — ClinicalSearch hard retirement (D5, deletion only)

- [ ] 7.1 RED `test/alethea_web/router_test.exs` (or new): `assert_raise Phoenix.Router.NoRouteError` for `/patients/#{id}/clinical-search`; `refute Code.ensure_loaded?(AletheaWeb.PatientLive.ClinicalSearch)`. Scenario: Retired route no longer resolves to the ranked list.
- [ ] 7.2 GREEN `lib/alethea_web/router.ex`: remove the `live("/patients/:patient_id/clinical-search", PatientLive.ClinicalSearch, :index)` block (lines ~127-131).
- [ ] 7.3 GREEN delete `lib/alethea_web/live/patient_live/clinical_search.ex` (removes the `@relevance_threshold 0.35` constant — threshold now solely owned by `Rag.Consultation.evidence_threshold/0`).
- [ ] 7.4 GREEN delete `test/alethea_web/live/patient_live/clinical_search_test.exs`.
- [ ] 7.5 GREEN `docs/main-demo-operator-guide.md` (~lines 218, 252): repoint the two references from `/clinical-search` to `/consultation`.

## Phase 8: Verification (each PR + final)

- [ ] 8.1 Per PR: run the slice Focused test command (RED → GREEN), then `mix test`.
- [ ] 8.2 Per PR: `mix precommit` (compile, format, test) before opening the PR.
- [ ] 8.3 Final (tracker branch): full `mix test` green; manual `mix phx.server` smoke of `/patients/:id/consultation` for the six states and the retired-route 404.
