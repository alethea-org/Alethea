# Design: Revisable Hypothesis Policy (#229)

**Issue:** #229 (sub-issue of #225) · **ADR:** 010 §2 · **Proposal:** `openspec/sdd/grounded-chat-229-hypothesis-policy/proposal.md` (D1–D4 locked)
**Base branch:** `feat/grounded-clinical-chat-hypotheses` (#226a/#226b present)

## Technical Approach

Three units, each independently testable, none wired into the real consultation flow (#235's scope):

1. `Consultation.Hypothesis` — value object that **cannot exist** without `statement`, non-empty `sources`, and the D2 `disclaimer`.
2. `Consultation.HypothesisPolicy` — pure module, the **sole constructor** of `Hypothesis`. Owns the D1 intent heuristic and the D3 fail-closed lexical gate.
3. `AI.Chains.ClinicalHypothesisChain` — `:local`-only sibling of `ClinicalConsultationChain`, byte-identical in shape (pure `build_prompt/1` + `parse/1`, fails loud), registered as `:consultation_hypothesis` in `LLMConfig`'s closed `chain_name` type.

The chain produces **only prose**. It never sees `chunk_id`/`resource_id` (mirrors AD4, so it cannot fabricate a citation), never writes the disclaimer, and never constructs a `Hypothesis`. Trust flows one way: chain → untrusted text → policy gate → typed value object.

## Architecture Decisions

| # | Decision | Choice | Rejected alternative | Rationale |
|---|---|---|---|---|
| AD1 | Intent classification | Pure Spanish-marker heuristic on a normalized query (D1) | LLM classifier | Issue demands a *testable* policy; an LLM runs on the factual path too and is non-deterministic. |
| AD2 | Factual-marker precedence | Factual marker **vetoes** an interpretive marker → `false` | Interpretive wins / score-based | Fail-closed toward "no hypothesis", which D1 declares never harmful. Deterministic, one rule to test. |
| AD3 | Accent handling | Normalize (downcase + accent-fold, keep `ñ`) once; markers and forbidden patterns are stored accent-free | Match raw text with accent-alternation regexes | Psychologists type without accents; one normalization path serves both gates and halves the pattern surface. |
| AD4 | Disclaimer ownership | `@disclaimer` constant + `Hypothesis.disclaimer/0` on the **value object**; policy reads it (D2) | Constant on `HypothesisPolicy` | The invariant belongs to the type that enforces it. Tests and #235 assert against the accessor; one test pins the verbatim literal as a golden. |
| AD5 | Forbidden scan target | Scans `candidate_text` **only**, never the assembled struct | Scan the whole `Hypothesis` | **Gotcha:** the D2 disclaimer literally contains `diagnóstico` and `recomendación terapéutica`. Scanning the struct would reject every hypothesis. Non-negotiable. |
| AD6 | Rejection granularity | Whole-hypothesis reject, single fixed reason precedence (D3) | Partial redaction / retry with stricter prompt | A scrubbed clinical statement reads as an endorsed conclusion. Fixed precedence makes the reason atom assertable. |
| AD7 | Output citation type | `Consultation.Source` via `Source.from_results/1` **verbatim** (D4) | `Rag.Citation` (#230) | Contract-canonical and server-derived. Reconciliation is #235's job. |
| AD8 | `Answer` integration | Additive optional `hypothesis` field, no new `outcome` value | 5th outcome `:hypothesis` | ADR-010 §2 says "puede incluir **además**" — additive, not terminal. Keeps #226a's outcome vocabulary byte-stable. |
| AD9 | Chain registration | New `:consultation_hypothesis` clause; `ClinicalConsultationChain` untouched | Extend the synthesis chain's schema | #226b carries a verbatim-asserted system-prompt regression test; touching it risks regressing merged work. |

## Data Flow

```
query ──► HypothesisPolicy.interpretive_intent?/1 ──false──► (no hypothesis; normal synthesis only)
                        │ true
                        ▼
      retrieval results (already fetched for the synthesis — NO second retrieval)
                        │
        excerpts only ──┴──► ClinicalHypothesisChain.run/1 ──► {:ok, %{hypothesis: text}}
                        │                                     │ {:error, :unparseable} ──► (no hypothesis)
                        ▼                                     ▼
                     results ───────────► HypothesisPolicy.evaluate/2
                                                │
                            ┌───────────────────┼───────────────────┐
                            ▼                   ▼                   ▼
                   {:reject, :no_evidence}  {:reject, :*_language}  {:ok, %Hypothesis{}}
                                                                     │
                                          sources = Source.from_results(results)
                                          disclaimer = Hypothesis.disclaimer()
```

The dashed boundary matters: **the chain receives `excerpts` (strings), `evaluate/2` receives `results` (maps).** Same underlying list, two projections — the model gets no identifiers, the server keeps them.

## File Changes

| File | Action | Description |
|---|---|---|
| `lib/alethea/clinical_record/rag/consultation/hypothesis.ex` | Create (#229a) | Value object + `disclaimer/0` |
| `lib/alethea/clinical_record/rag/consultation/hypothesis_policy.ex` | Create (#229a) | `interpretive_intent?/1`, `evaluate/2`, pattern accessors |
| `lib/alethea/clinical_record/rag/consultation/answer.ex` | Modify (#229a) | `+ :hypothesis` in `defstruct`/`@type`, `alias`, moduledoc line |
| `lib/alethea/ai/chains/clinical_hypothesis_chain.ex` | Create (#229b) | `:local`-only sibling chain |
| `lib/alethea/ai/llm_config.ex` | Modify (#229b) | `\| :consultation_hypothesis` in `chain_name` + one `chain_module/1` clause |
| `config/test.exs` | Modify (#229b) | `config :alethea, :clinical_hypothesis_chain, Alethea.AI.ClinicalHypothesisChainMock` |
| `test/test_helper.exs` | Modify (#229b) | `Mox.defmock(Alethea.AI.ClinicalHypothesisChainMock, for: Alethea.AI.Chains.ChainBehaviour)` |
| `test/alethea/clinical_record/rag/consultation/hypothesis_policy_test.exs` | Create (#229a) | Table-driven purity/gate tests |
| `test/alethea/ai/chains/clinical_hypothesis_chain_test.exs` | Create (#229b) | Pure-function + Mox + static source-scan tests |

**Unchanged #226a files (confirmed):** `consultation.ex` (facade/behaviour — no new callback), `source.ex` (reused verbatim), `fake.ex` (`hypothesis` defaults to `nil`; emitting a fake hypothesis is #235/#231), `consultation_test.exs` (all existing pattern matches still match). `clinical_consultation_chain.ex` and its test are byte-unchanged.

## Interfaces / Contracts

### 1. `Alethea.ClinicalRecord.Rag.Consultation.Hypothesis`

```elixir
defmodule Alethea.ClinicalRecord.Rag.Consultation.Hypothesis do
  alias Alethea.ClinicalRecord.Rag.Consultation.Source

  @disclaimer "Hipótesis para revisar: no es un diagnóstico ni una recomendación terapéutica."

  @type t :: %__MODULE__{
          statement: String.t(),
          sources: [Source.t(), ...],   # non-empty by construction
          disclaimer: String.t()
        }

  @enforce_keys [:statement, :sources, :disclaimer]
  defstruct [:statement, :sources, :disclaimer]

  @doc "The mandatory, server-owned disclaimer (D2). Never LLM-authored."
  @spec disclaimer() :: String.t()
  def disclaimer, do: @disclaimer
end
```

`[Source.t(), ...]` documents the non-empty invariant; `HypothesisPolicy.evaluate/2` enforces it at runtime (Dialyzer cannot). `disclaimer` is in `@enforce_keys` with **no default** — a caller bypassing the policy must still supply it consciously, and the golden test proves the policy supplies the exact literal.

### 2. `Alethea.ClinicalRecord.Rag.Consultation.HypothesisPolicy`

```elixir
@type reject_reason :: :no_evidence | :empty_statement | :diagnostic_language | :prescriptive_language

@spec interpretive_intent?(String.t()) :: boolean()
@spec evaluate(String.t(), [Retrieval.result()]) :: {:ok, Hypothesis.t()} | {:reject, reject_reason()}
```

**Normalization (shared by both gates):** `String.downcase/1`, then fold `á é í ó ú ü` → `a e i o u` (keep `ñ`), then collapse whitespace. `normalize/1` is private but exercised through both public functions.

**Interpretive markers** (substring match on normalized text — any one triggers):

| Group | Markers (accent-folded) |
|---|---|
| Causal | `por que`, `a que se debe`, `podria deberse`, `puede deberse`, `se debe a`, `que explica`, `como se explica` |
| Relational | `que relacion`, `relacion entre`, `tiene que ver con`, `esta relacionado`, `correlacion`, `influye`, `influencia` |
| Pattern | `patron` (covers `patrón`/`patrones`), `tendencia`, `se repite`, `recurrente` |
| Interpretive | `que significa`, `como interpret`, `interpretacion`, `tendria sentido que`, `hipotesis` |

**Factual veto markers** (any one forces `false`, per AD2):

`cuando`, `cuantas veces`, `cuantos`, `cuantas`, `que dijo`, `que dia`, `que fecha`, `en que sesion`, `quien`, `lista`, `enumera`, `ultima vez`

**Worked examples for #229a's table:**

| Query | Result | Why |
|---|---|---|
| `¿Por qué empeoró el ánimo en marzo?` | `true` | causal `por que` |
| `¿Qué relación hay entre el insomnio y las discusiones?` | `true` | relational |
| `¿Hay un patrón en sus crisis?` | `true` | pattern |
| `¿A qué se debe la irritabilidad?` | `true` | causal |
| `¿Podría deberse al cambio de trabajo?` | `true` | causal |
| `¿Cuándo reportó insomnio por última vez?` | `false` | factual |
| `¿Cuántas veces mencionó a su pareja?` | `false` | factual |
| `¿Qué dijo el paciente sobre su hermana?` | `false` | factual |
| `Lista las sesiones de este mes` | `false` | factual |
| `¿Por qué faltó? ¿Qué día fue?` | `false` | **veto wins** over `por que` (AD2) |
| `Resume la última sesión` | `false` | no interpretive marker |
| `""` / `"   "` | `false` | blank guard |

**Forbidden patterns** (matched against **normalized `candidate_text` only** — AD5). Exposed via `@doc false` accessors `diagnostic_patterns/0` and `prescriptive_patterns/0` (mirrors `ClinicalConsultationChain.synthesis_schema/0`'s precedent) so tests assert without duplicating literals:

```elixir
@diagnostic_patterns [
  ~r/\bdiagnostic\w*\b/,        # diagnóstico, diagnóstica, diagnosticar, diagnosticado
  ~r/\btrastorno\w*\b/,
  ~r/\bpatolog\w*\b/,
  ~r/\bpadec\w*\b/,             # padece, padecería
  ~r/\bsufre de\b/,
  ~r/\bcumple criterios\b/,
  ~r/\bcuadro clinico\b/,
  ~r/\bdsm-?\s?(iv|v|5)\b/,
  ~r/\bcie-?\s?1[01]\b/
]

@prescriptive_patterns [
  ~r/\brecom(iend|end)\w*\b/,   # recomiendo, recomendación, recomendamos
  ~r/\btratamiento\b/,
  ~r/\biniciar terapia\b/,
  ~r/\bprescri\w*\b/,           # prescribir, prescripción
  ~r/\bmedica(r|cion|mento)\w*\b/,
  ~r/\bderivar\s+(a|al)\b/,
  ~r/\bdeberia\w*\s+(iniciar|comenzar|empezar|tomar|suspender|derivar|indicar)\b/,
  ~r/\bhay que\s+(iniciar|indicar|derivar|medicar)\b/,
  ~r/\bse sugiere\s+(iniciar|indicar|tratamiento)\b/
]
```

**Deliberately NOT banned:** bare `sugiere` / `sugieren` / `podria` / `es posible`. Legitimate tentative hypothesis prose depends on them; banning them would reject nearly every valid hypothesis. Only the prescriptive bigrams are caught.

**`evaluate/2` gate precedence** (fixed, documented, test-pinned):

1. `results == []` → `{:reject, :no_evidence}`
2. `String.trim(candidate_text) == ""` → `{:reject, :empty_statement}`
3. any `@diagnostic_patterns` match → `{:reject, :diagnostic_language}`
4. any `@prescriptive_patterns` match → `{:reject, :prescriptive_language}`
5. otherwise → `{:ok, %Hypothesis{statement: String.trim(candidate_text), sources: Source.from_results(results), disclaimer: Hypothesis.disclaimer()}}`

`:empty_statement` is a fourth reason beyond the proposal's three — required because `Hypothesis` must never hold a blank statement, and the chain's `{:error, :unparseable}` path does not cover a caller passing `""` directly. Precedence rule 1-before-3 means a diagnostic statement with zero evidence reports `:no_evidence`; this is arbitrary but fixed and asserted.

`statement` is stored **trimmed and otherwise verbatim** — the disclaimer is never concatenated into it (D2).

### 3. `Alethea.AI.Chains.ClinicalHypothesisChain`

Mirrors `ClinicalConsultationChain` clause-for-clause: `@behaviour ChainBehaviour`, `run/1`, `run!/1`, `suggested_system_prompt/0`, `suggested_max_tokens/0` → `384`, `supported_providers/0` → `[:local]`, `@doc false hypothesis_schema/0`, pure `build_prompt/1`, pure `parse/1`, private `do_run/2` with telemetry `chain: :clinical_hypothesis`.

```elixir
def hypothesis_schema do
  %{"type" => "object",
    "properties" => %{"hypothesis" => %{"type" => "string"}},
    "required" => ["hypothesis"]}
end

@spec parse(String.t()) :: {:ok, %{hypothesis: String.t()}} | {:error, :unparseable}
```

`parse/1` returns `{:error, :unparseable}` on malformed JSON, missing key, non-binary value, or an empty/blank string — identical fail-loud contract to #226b (AD8). `build_prompt/1` takes `%{question: String.t(), excerpts: [String.t()]}` and numbers the excerpts; it emits **no** `chunk_id`/`resource_id`/`target_behavior_id`.

**System prompt (exact text, distinct from the synthesis prompt):**

```
Eres Alethea, un asistente clínico. Propones UNA hipótesis interpretativa breve, para que el psicólogo la revise, ÚNICAMENTE a partir de los fragmentos de evidencia clínica numerados que se te entregan.

Una hipótesis es una lectura tentativa de un patrón o una relación entre los fragmentos. NO es un diagnóstico ni una recomendación terapéutica.

Regla estricta, sin excepción: no nombres trastornos ni cuadros clínicos, no indiques tratamiento, medicación ni derivación, no completes con conocimiento general; si los fragmentos no permiten una hipótesis, dilo.

- Usa solo la información contenida en los fragmentos.
- Formula en modo tentativo ("podría", "es posible que"), nunca como conclusión.
- No enumeres ni cites fuentes: devuelve solo el enunciado de la hipótesis.
- No escribas ninguna advertencia ni descargo de responsabilidad: el servidor lo añade.
```

Wrapped by `StructuredOutput.with_schema(base, hypothesis_schema())`, exactly as #226b does. The last bullet is the prompt-layer half of D2; the policy is the structural half.

### 4. `LLMConfig` additions (two lines)

```elixir
@type chain_name :: ... | :consultation_synthesis | :consultation_hypothesis
defp chain_module(:consultation_hypothesis), do: Alethea.AI.Chains.ClinicalHypothesisChain
```

The closed type means a missing clause fails loud at compile time.

### 5. `Answer` additive change (the only #226a contact point)

```elixir
alias Alethea.ClinicalRecord.Rag.Consultation.{Hypothesis, Source}

@type t :: %__MODULE__{
        outcome: outcome(),
        synthesis: String.t() | nil,
        sources: [Source.t()],
        pending: non_neg_integer(),
        hypothesis: Hypothesis.t() | nil
      }

@enforce_keys [:outcome]                                    # unchanged
defstruct [:outcome, :synthesis, :hypothesis, sources: [], pending: 0]
```

`outcome` vocabulary unchanged (AD8). `hypothesis` defaults to `nil`, so every existing construction site (`Fake`) and every existing pattern match (`consultation_test.exs`, `consultation_live_test.exs`) compiles and passes untouched. A doc-level invariant — `hypothesis` is non-nil only alongside `outcome: :synthesis` — is stated in the moduledoc and enforced at the #235 wiring boundary, not by a struct guard (a guard would need a constructor, which #226a deliberately does not have).

## Retrieval-shape alignment (#235 readiness)

`evaluate/2`'s second argument is typed `[Alethea.ClinicalRecord.Rag.Retrieval.result()]` — the identical list `Rag.Retrieval.search/4` returns under `envelope.results`, and the identical list `Source.from_results/1` already consumes to build `Answer.sources`. `evaluate/2` **calls `Source.from_results/1` verbatim** and re-maps nothing.

`from_results/1` dot-accesses exactly six keys: `content`, `source_resource_type`, `source_occurred_at`, `chunk_id`, `source_resource_id`, `target_behavior_id`. The envelope's remaining keys (`chunk_index`, `score`, `dense_distance`, `lexical_score`, `full_event`) are ignored — harmless extras, so no filtering step is needed.

**Consequence for #235:** the wiring is `HypothesisPolicy.evaluate(chain_text, envelope.results)` — the same `envelope.results` already passed to `Source.from_results/1` for the synthesis. Zero adaptation, zero second retrieval.

**Consequence for #229a fixtures:** because `from_results/1` uses dot-access, a test fixture missing any of the six keys raises `KeyError`, not a soft failure. Fixtures mirror `Consultation.Fake`'s `canned_sources/0` map shape exactly.

## Testing Strategy

| Layer | What to test | Approach | Slice |
|---|---|---|---|
| Unit — intent | ~16 interpretive `true` phrases, ~12 factual `false` phrases, veto precedence, blank/whitespace, accent-free input parity (`"por que"` ≡ `"por qué"`) | `for phrase <- @phrases, do: test ...` comprehensions — keeps ~30 cases inside ~14 lines | #229a |
| Unit — evidence gate | `evaluate(text, [])` → `{:reject, :no_evidence}`; one result → exactly one `%Source{}`; N results → N sources, order preserved | Direct, `Fake`-shaped fixtures | #229a |
| Unit — language gate | One rejection case per pattern in `diagnostic_patterns/0` and `prescriptive_patterns/0`, driven by the exported accessors; plus explicit `deberías iniciar tratamiento`, `presenta un trastorno de ansiedad`, `recomiendo derivar a psiquiatría` | Table-driven over the accessor lists | #229a |
| Unit — no false rejection | Legitimate tentative prose using `sugiere`/`podría`/`es posible que` is **accepted** | Explicit positive cases | #229a |
| Unit — disclaimer | Returned `disclaimer == Hypothesis.disclaimer()`; one golden asserting the verbatim literal; `statement` does **not** contain the disclaimer substring | Direct assertions | #229a |
| Unit — struct invariant | `struct!(Hypothesis, %{})` raises on missing `@enforce_keys` | `assert_raise ArgumentError` | #229a |
| Static — policy purity | `hypothesis_policy.ex` source contains no `Repo`, no `create_clinical_note`, no `accept_ai_proposal` | `File.read!` + `refute =~` | #229a |
| Unit — chain purity | `build_prompt/1` numbers excerpts, embeds the question, and contains no `chunk_id`/`resource_id`/`target_behavior_id`; `parse/1` returns `{:error, :unparseable}` on malformed JSON, missing key, `""`, and whitespace-only | Mirrors `clinical_consultation_chain_test.exs` | #229b |
| Unit — prompt golden | `suggested_system_prompt/0` carries the verbatim `NO es un diagnóstico ni una recomendación terapéutica` and the verbatim `no indiques tratamiento, medicación ni derivación` and the server-owns-disclaimer bullet | `assert prompt =~ ...` | #229b |
| Unit — provider | `supported_providers() == [:local]`; source contains no `":cloud"` | Mirrors #226b | #229b |
| Integration — config | `LLMConfig.get_and_build(:consultation_hypothesis)` resolves an `OllamaChat` with `provider == :local` | Direct | #229b |
| Integration — Mox | `:test` maps `:clinical_hypothesis_chain` to the mock; mock `run/1` returns text derived only from the excerpts given | `import Mox`, `setup :verify_on_exit!` | #229b |
| Static — source scan (D3 layer 3) | See below | `File.read!` + `refute =~` | #229b |
| E2E | None — #229 is deliberately unwired | N/A (#235 owns it) | — |

### Static source-scan test (D3 layer 3)

Precedent: `test/alethea_jobs/ai_proposal_worker_test.exs:135-155`. Same shape, same reasoning — a textual check catches "someone added a write call", which a behavioural test would miss if the call sits behind an unexercised branch.

```elixir
describe "structural safety" do
  test "the chain module source never references a diagnosis-writing or note-creating function" do
    source =
      Path.join([File.cwd!(), "lib", "alethea", "ai", "chains", "clinical_hypothesis_chain.ex"])
      |> File.read!()

    # Mutation entry points — verified to exist at lib/alethea/clinical_record.ex:
    refute source =~ "create_clinical_note"              # :102
    refute source =~ "accept_ai_proposal"                # :366
    refute source =~ "edit_ai_proposal"                  # :386
    refute source =~ "discard_ai_proposal"               # :412
    refute source =~ "upsert_functional_analysis_draft"  # :438

    # Superset guard: the chain is pure text-in/text-out and must not
    # reach into the clinical write context or the repo at all.
    refute source =~ "Alethea.ClinicalRecord"
    refute source =~ "Repo."
  end
end
```

The five names are the actual public mutation functions in `Alethea.ClinicalRecord`, confirmed by reading `lib/alethea/clinical_record.ex`. The `"Alethea.ClinicalRecord"` guard holds because the chain returns plain `%{hypothesis: text}` and never touches `Hypothesis`/`Source`/`Answer` — the policy owns all typed construction.

**Scan-scope note:** this is a *call-target* scan, not a vocabulary scan. The chain's system prompt legitimately contains the Spanish words `diagnóstico`, `trastornos`, and `tratamiento` (as prohibitions), so asserting on those words would produce a false failure. Symmetrically, AD5's rule — the lexical gate reads `candidate_text` only — exists because the D2 disclaimer contains those same words.

## Threat Matrix

`N/A` — no routing, shell command, subprocess, VCS/PR automation, executable-file classification, or process-integration boundary is introduced. `ClinicalHypothesisChain`'s only outbound call is the existing in-process LangChain → local Ollama path already covered by `ClinicalConsultationChain`, pinned to `[:local]` so no decrypted clinical narrative leaves the box. The clinical-safety guarantees (D3) are covered by the Testing Strategy table above rather than by the threat matrix.

## Migration / Rollout

No migration. No persisted data, no schema change, no feature flag. `Answer.hypothesis` defaults to `nil` and no production code path populates it until #235. Rollback = delete three new modules plus their tests, drop one `defstruct`/`@type` field, remove two `LLMConfig` lines and two test-wiring lines.

## Per-Slice PR Breakdown

**#229a — struct + policy** (targets the `feat/grounded-clinical-chat-hypotheses` tracker branch)

| File | Est. lines |
|---|---|
| `hypothesis.ex` | ~35 |
| `hypothesis_policy.ex` | ~115 |
| `answer.ex` (modify) | ~+8 |
| `hypothesis_policy_test.exs` (incl. struct + static-purity tests) | ~155 |
| **Total** | **~315** |

`400-line budget risk: Medium.` Table-driven `for` comprehensions are load-bearing for staying under budget — writing ~30 marker cases as individual `test` blocks would add ~90 lines and push the slice to ~400. Contingency if it overruns: split the marker-table tests into `hypothesis_intent_test.exs` as a third stacked PR.

**#229b — chain + LLMConfig** (targets #229a's branch)

| File | Est. lines |
|---|---|
| `clinical_hypothesis_chain.ex` | ~130 |
| `llm_config.ex` (modify) | ~+2 |
| `config/test.exs` (modify) | ~+1 |
| `test/test_helper.exs` (modify) | ~+1 |
| `clinical_hypothesis_chain_test.exs` | ~150 |
| **Total** | **~284** |

`400-line budget risk: Low.`

`Decision needed before apply: No` — both slices fit the 400-line budget.
`Chained PRs recommended: Yes` — #229a → tracker, #229b → #229a (Feature Branch Chain; retarget/rebase if #229a's diff appears inside #229b).

Each slice ships independently: #229a is complete and green without any chain; #229b adds generation without changing #229a's gate semantics.

## Open Questions

- [ ] Should `Consultation.Fake` gain an opt-in canned hypothesis (`opts[:hypothesis]`) so #231's panel has a deterministic fixture? Deferred to #235/#231 — this design leaves `Fake` untouched.
- [ ] The interpretive marker set is a first pass tuned from ADR-010's vocabulary, not from a corpus of real psychologist queries. Widening it is cheap and non-breaking (one list entry + one table row); no structural change is implied.
