# Design — grounded-clinical-chat-initial (#223)

**Status:** design complete
**Date:** 2026-09-10
**Authority:** proposal D1–D5, ADR-010, exploration `Current state (file:line)`
**Prior phase:** `openspec/sdd/grounded-clinical-chat-initial/proposal.md`

## Technical approach

New Phoenix-free `Alethea.ClinicalRecord.Consultation` context: a behaviour + a dispatcher facade + typed `Answer`/`Source` structs, with two swappable implementations (`Live`, `Fake`) and LLM synthesis isolated behind a new `Alethea.AI.Chains.ClinicalConsultationChain` (`ChainBehaviour`, `:local` only). `AletheaWeb.ConsultationLive` is a thin adapter that only ever calls `Consultation` public functions. Sources are built server-side from the `Retrieval.search/4` envelope; the chain receives sanitized excerpts and returns prose only, so ADR-010 decision 3 holds by construction.

## Architecture decisions

| # | Decision | Alternative rejected | Rationale |
|---|---|---|---|
| AD1 | Seam at `lib/alethea/clinical_record/consultation/` | `Alethea.AI.ClinicalConsultation` | authz + retrieval + freshness are ClinicalRecord read concerns; only synthesis delegates to `Alethea.AI` |
| AD2 | `%Answer{outcome: atom}` struct | 4-variant tagged tuples | exhaustive downstream matching; one shared outcome vocabulary (proposal §4) |
| AD3 | `answer/4 :: {:ok, Answer.t()} \| {:error, :unauthorized}` | `:unauthorized` as a 5th outcome | authz failure is a precondition, not a consultation outcome; keeps the vocabulary at exactly 4 and mirrors `Retrieval.search/4` + `TargetBehaviorLive.Review`'s redirect branch |
| AD4 | Chain returns `%{synthesis: binary}` only; never a source list | model-emitted citations | the model has no channel to fabricate a citation (ADR-010 d3) |
| AD5 | `supported_providers/0 -> [:local]`, `provider: :local` pinned in `config/config.exs` | config default only | D2: `:cloud` must be structurally impossible, not discouraged |
| AD6 | Conversation history is **never** sent to the LLM; it feeds only a pure server-side `resolve_query/2` | pass history as prompt context | ADR-010 d1 — history resolves follow-ups, never evidence. Excluding it from the prompt removes the channel entirely |
| AD7 | Prompt copy of an excerpt is `Sanitizer.sanitize/1`-ed; the displayed `Source.excerpt` is the verbatim retrieved content | sanitize once, display sanitized | ADR-010 d3 requires the *exact* fragment on screen; Security Mandate 5 wants the model to see no structured PII |
| AD8 | `parse/1` failure → `{:error, :unparseable}` → `:provider_failure` | degrade to `""` like `PatternProposalChain.parse_proposals/1` | an empty synthesis rendered beside real sources reads as "the record says nothing"; must fail loud |
| AD9 | Freshness pre-gate via `Retrieval.freshness/1` **before** `search/4`, plus a post-retrieval re-check of `envelope.freshness` | envelope check only | blocks before any decryption when already stale; the re-check closes the enqueue-during-search race |
| AD10 | Threshold owned by `Consultation.evidence_threshold/0`, key `:consultation_evidence_threshold` (float), separate from `:clinical_consultation` (module swap) | one keyword-list key | avoids module/keyword ambiguity in `Application.get_env` |
| AD11 | Follow-up context in socket assigns, bounded to `@history_limit 6` turns | `Alethea.AI.ConversationMemory` (ETS) | ADR-010 d6 forbids any persistence; assigns die on remount by construction |

## Data flow

```
ConsultationLive (assigns: current_professional, patient_id, history, state)
  │ handle_event("ask") → assign(:state, :retrieving) → start_async(:answer, ...)
  ▼
Alethea.ClinicalRecord.Consultation.answer/4          # facade → impl()
  ├─ Consultation.Fake   (test, #227)
  └─ Consultation.Live   (#232)
       1. Accounts.get_patient_for_professional/2  → nil ⇒ {:error, :unauthorized}
       2. Retrieval.freshness/1  stale? ⇒ %Answer{outcome: :stale, pending: n}
       3. Retrieval.search/4(resolve_query(query, history))
            {:error, :unauthorized} ⇒ {:error, :unauthorized}
            {:error, _}             ⇒ :provider_failure
       4. envelope.freshness.stale? ⇒ :stale (race re-check)
       5. results |> filter(score >= evidence_threshold())
            [] ⇒ :no_evidence
       6. sources = Source.from_results(kept)          # server-derived
          chain().run(%{question: query,
                        excerpts: Enum.map(kept, &Sanitizer.sanitize(&1.content))})
            {:ok, %{synthesis: s}} ⇒ :synthesis (sources kept verbatim)
            {:error, _}            ⇒ :provider_failure
  ▼
{:ok, %Answer{}} → handle_async → stream_insert(:messages, ...) → render
```

Envelope→outcome table (the `#232` contract under test):

| Condition (evaluated in order) | Outcome | Payload |
|---|---|---|
| patient not treated / deleted | `{:error, :unauthorized}` | — |
| `freshness.stale?` (pre or post) | `:stale` | `pending: n`, `sources: []` |
| `chunk_count == 0` or `results == []` | `:no_evidence` | `sources: []` |
| all `score < evidence_threshold()` | `:no_evidence` | `sources: []` |
| search/embedding error, chain error, unparseable | `:provider_failure` | `sources: []` |
| otherwise | `:synthesis` | `synthesis`, `sources: [%Source{}]` |

No branch produces prose without sources, and no branch falls back to general knowledge.

## Interfaces / contracts

```elixir
defmodule Alethea.ClinicalRecord.Consultation do
  alias Alethea.ClinicalRecord.Consultation.Answer

  @callback answer(Professional.t(), Ecto.UUID.t(), String.t(), keyword()) ::
              {:ok, Answer.t()} | {:error, :unauthorized}

  @spec answer(Professional.t(), Ecto.UUID.t(), String.t(), keyword()) ::
          {:ok, Answer.t()} | {:error, :unauthorized}
  def answer(professional, patient_id, query, opts \\ []),
    do: impl().answer(professional, patient_id, query, opts)

  @spec evidence_threshold() :: float()
  def evidence_threshold,
    do: Application.get_env(:alethea, :consultation_evidence_threshold, 0.35)

  defp impl, do: Application.get_env(:alethea, :clinical_consultation, __MODULE__.Live)
end

defmodule Alethea.ClinicalRecord.Consultation.Answer do
  @type outcome :: :synthesis | :no_evidence | :stale | :provider_failure
  @enforce_keys [:outcome]
  defstruct [:outcome, :synthesis, sources: [], pending: 0]
end

defmodule Alethea.ClinicalRecord.Consultation.Source do
  @enforce_keys [:excerpt, :kind, :occurred_at, :reference]
  defstruct [:excerpt, :kind, :occurred_at, :reference]
  # excerpt   :: String.t()      verbatim decrypted chunk content
  # kind      :: String.t()      raw `source_resource_type`
  # occurred_at :: DateTime.t()  `source_occurred_at`
  # reference :: %{chunk_id:, resource_type:, resource_id:, target_behavior_id:}
end
```

`opts`: `:history` (`[%{role: :professional | :assistant, content: binary}]`, bounded), `:limit`, `:candidate_limit`.

Chain: `run(%{question: binary, excerpts: [binary]}) :: {:ok, %{synthesis: binary}} | {:error, term}`; pure `build_prompt/1` (already-retrieved sanitized excerpts, numbered, no ids), pure `parse/1`, `suggested_system_prompt/0` (grounding + no-fallback + "no diagnostiques, no recomiendes tratamiento, no completes con conocimiento general; si los fragmentos no alcanzan, dilo"), `suggested_max_tokens/0 512`, `supported_providers/0 -> [:local]`, `[:alethea, :ai, :chain, :start|:stop]` telemetry with `chain: :clinical_consultation` — mirroring `PatternProposalChain` except AD8.

`LLMConfig` deltas: `:clinical_consultation` added to the `chain_name` type (llm_config.ex:26) and `defp chain_module(:clinical_consultation), do: Alethea.AI.Chains.ClinicalConsultationChain` (after :236).

## ConsultationLive

Route inside the existing `:require_authenticated_professional` live_session (router.ex:111-136): `live("/patients/:patient_id/consultation", ConsultationLive, :index)`.

- `mount/3` authorizes through the context only (`Consultation.answer` is per-turn, so mount uses `Retrieval.metadata/2`'s established pattern **via** the context — expose `Consultation.open/2` returning `{:ok, %{chunk_count:, freshness:}} | {:error, :unauthorized}` so the LiveView never calls `Retrieval` directly). `{:error, :unauthorized}` → flash + `push_navigate(to: ~p"/patients")`.
- Assigns: `patient_id`, `history` (≤6 turns), `state`, `turn` counter, `query_form`. Streams: `stream(:messages, [])`, `stream_insert/3` per turn; "nueva conversación" → `stream(:messages, [], reset: true)` + `assign(:history, [])`.
- Six visible states with stable dom ids: `consultation-idle`, `consultation-retrieving`, `consultation-synthesis`, `consultation-no-evidence`, `consultation-stale` (renders `pending`), `consultation-provider-error`.
- Every `handle_event/3` and the `start_async` closure read `socket.assigns.current_professional`; no professional id ever comes from params.
- A synthesis message renders two structurally distinct blocks: `<section class="consultation__synthesis">` titled **Síntesis basada en evidencia** and `<ol class="consultation__sources">` titled **Fuentes**, one `<li>` per `%Source{}` with excerpt, `source_kind_label/1`, formatted `occurred_at`, and a `.link` to `TargetBehaviorLive.Review` when `reference.target_behavior_id` is present (the `source_kind_label/1` + `source_link/2` + `format_datetime/1` helpers migrate here from `clinical_search.ex`). No hypothesis block anywhere (D1).
- Zero persistence: no ETS, no DB write, no `ConversationMemory`, no access/audit metadata.

## File changes

| File | Action | Slice |
|---|---|---|
| `lib/alethea/clinical_record/consultation.ex` | Create — behaviour, facade, threshold | #226 |
| `lib/alethea/clinical_record/consultation/answer.ex`, `.../source.ex` | Create — structs | #226 |
| `lib/alethea/clinical_record/consultation/fake.ex` | Create — deterministic per-outcome fakes | #226 |
| `lib/alethea/ai/chains/clinical_consultation_chain.ex` | Create | #226 |
| `lib/alethea/ai/llm_config.ex` | Modify — `:clinical_consultation` (type :26, `chain_module/1`) | #226 |
| `config/config.exs` | Modify — chain `provider: :local`, `:consultation_evidence_threshold, 0.35` | #226 |
| `config/test.exs`, `test/test_helper.exs` | Modify — `:clinical_consultation_chain` mock, `Mox.defmock(ClinicalConsultationChainMock, for: ChainBehaviour)` | #226 |
| `lib/alethea_web/live/consultation_live.ex` | Create | #227 |
| `lib/alethea_web/router.ex` | Modify — add route (#227), remove clinical-search route :127-131 (#234) | #227/#234 |
| `lib/alethea/clinical_record/consultation/live.ex` | Create — real impl | #232 |
| `config/dev.exs` / `config/prod` path | Modify — point at `Consultation.Live` | #234 |
| `lib/alethea_web/live/patient_live/clinical_search.ex` (268 L) | Delete | #234 |
| `test/alethea_web/live/patient_live/clinical_search_test.exs` (331 L) | Delete | #234 |
| `docs/main-demo-operator-guide.md:218,252` | Modify — repoint at the consultation route | #234 |

**Retirement finding:** there is no in-app navigation link to `/patients/:patient_id/clinical-search`. A repo-wide scan finds the route only in `router.ex:127-131`, the module itself, its test, and two doc lines. D5's "nav entry" removal therefore reduces to the doc references; the design adds a nav entry for the consultation route instead (`PatientLive.Index` patient card) so the surface is reachable.

## PR breakdown and 400-line budget

| Slice | Scope | Est. added | Est. deleted | Budget risk |
|---|---|---|---|---|
| #226 | contract + structs + fake + chain skeleton + config + tests | ~600 | ~0 | **High — split** |
| #227 | `ConsultationLive` + route + LiveView tests on the fake | ~400 | ~0 | Medium/High |
| #232 | `Consultation.Live` + domain tests | ~400 | ~0 | Medium/High |
| #234 | real wiring + Fuentes render + retirement | ~70 | ~600 | **High — split or `size:exception`** |

Recommended stacking (each child targets its parent branch):

- **#226a** contract: `consultation.ex`, `answer.ex`, `source.ex`, `fake.ex`, config, tests (~350).
- **#226b** chain: `clinical_consultation_chain.ex`, `LLMConfig` clause, Mox mock, chain tests (~280).
- **#234a** wiring + Síntesis/Fuentes render + integration tests (~200 added).
- **#234b** retirement only: pure deletion of route + module + test + doc repoint (~600 deleted, ~10 added) — deletion-dominant and mechanically reviewable; the right candidate for an explicit `size:exception` if it is not split further.

This repo's moduledoc convention is unusually verbose (`retrieval.ex` opens with 60 lines of prose), which is the dominant inflator; slices #227 and #232 land near the line only because of it. `sdd-tasks` owns the binding forecast.

## Testing strategy (strict TDD, `mix test`)

| Slice | Layer | What | How |
|---|---|---|---|
| #226 | Unit | all 4 outcomes reachable through the facade | `Consultation.Fake` per-outcome; `Application.put_env(:alethea, :clinical_consultation, Fake)` |
| #226 | Unit | `evidence_threshold/0` reads config, defaults 0.35 | `put_env` round-trip |
| #226 | Unit | `supported_providers/0 == [:local]` and no `:cloud` path exists | assert + static source scan for `:cloud` in the chain module (mirrors `AIProposalWorkerTest`'s scan) |
| #226 | Unit | `build_prompt/1` contains no chunk/resource ids; `parse/1` returns `{:error, :unparseable}` on malformed JSON and on an empty `synthesis` | pure functions, no LLM |
| #226 | Regression (AI pipeline, CLAUDE.md) | grounded-behavior regression: a fixed excerpt set + fixed question yields a synthesis containing no claim absent from the excerpts; the no-fallback system prompt text is asserted verbatim | golden-style assertion on `suggested_system_prompt/0` + `build_prompt/1` |
| #232 | Unit | **the LLM cannot inject sources**: `ClinicalConsultationChainMock` returns a synthesis naming a fabricated citation; assert `Answer.sources` equals exactly the envelope-derived list | Mox against `ChainBehaviour` |
| #232 | Integration | authorize-before-retrieve: a non-treating professional gets `{:error, :unauthorized}` and `Retrieval` is never reached | `expect(Mock, :run, 0, ...)` + a stranger fixture |
| #232 | Integration | fresh-per-turn: two turns ⇒ two retrievals; stale pre-gate blocks with `pending` and never calls the chain | Oban `testing: :manual` job insert + `expect(..., 0, ...)` |
| #232 | Integration | `:no_evidence` on empty results and on all-below-threshold; cross-patient isolation | seeded chunks for two patients |
| #232 | Unit | `resolve_query/2` is pure and uses only professional turns | table test |
| #227 | LiveView | six visible states render their dom ids; unauthorized mount redirects to `/patients` | `Phoenix.LiveViewTest` over `Consultation.Fake` |
| #227 | LiveView | **no survival on remount**: ask, then `live/2` again ⇒ empty message stream and empty history | two `live/2` calls in one test |
| #234 | LiveView | Síntesis and Fuentes render as distinct sections; each source shows excerpt, kind, date, reference | integration over `Consultation.Live` with seeded chunks + chain mock |
| #234 | Regression | the clinical-search route returns 404 and `PatientLive.ClinicalSearch` is undefined | `assert_raise Phoenix.Router.NoRouteError` |

## Threat matrix

| Boundary | Applicability | Reason |
|---|---|---|
| Documentation-like paths | N/A | no file classification or execution of repo content |
| Git repository selection | N/A | no VCS automation in the change |
| Commit state | N/A | no index/worktree manipulation |
| Push state | N/A | no ref resolution |
| PR commands | N/A | no command composition |

The real adversarial boundary here is authorization + tenancy, covered by the #232 authorize-before-retrieve and cross-patient isolation RED tests above, and by the rule that no professional id is ever read from params.

## Migration / rollout

No data migration. Additive through #232; the only irreversible step is #234's hard cutover (D5), which lands last, after #232 has proven retrieval behaviour. Rollback for #226–#232 is `config :alethea, :clinical_consultation` pointing back at the fake or removing the route; after #234b there is no fallback surface, by decision.

## Open questions

- [ ] AD3 (`{:ok, Answer.t()} | {:error, :unauthorized}` rather than a bare `%Answer{}`) must be reconciled with `spec.md` if the parallel spec phase asserts a bare struct return.
- [ ] Naming: `Alethea.ClinicalRecord.Consultation` sits beside the pre-existing `ClinicalRecord.ConsultationEvidence` (and the `"consultation_evidence"` source kind), which are a different concept. Confirm the name with `UBIQUITOUS_LANGUAGE.md` or prefix the surface (e.g. `Consultation.Chat`).
- [ ] Orphan-chunk edge (proposal risk 6): whether #232 adds a query-time `Tombstone` cross-check or only an explicit scenario. Design currently assumes the scenario only.
