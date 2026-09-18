# Design — grounded-chat-235-integration

**Change:** grounded-chat-235-integration (issue #235) | **Store:** hybrid (mirrored to Engram `sdd/grounded-chat-235-integration/design`)
**Inputs:** `proposal.md` (1fbcc84), `spec.md` (47e43d9, 12 requirements). **Approach fixed by PD1** — sequential in-flow; not re-litigated here.
**Scope of this document:** the HOW. Concrete code shape, the four architecture decisions the spec left open, the AST-walker reuse call, and the slice/test mapping.

## Technical Approach

One new private function in the domain (`maybe_hypothesis/3`) hangs off the success branch of `Consultation.Live.synthesize/2` behind its own rescue. One function component mounts as a sibling `<section>` in `ConsultationLive`. One value passes through `Consultation.Fake` untouched. The `HypothesisPolicy` call site count is enforced by a shared, AST-aware test-support scanner extracted from the PR #273 Sole Constructor Gate. Citation unification ships last and alone.

## Architecture Decisions

### AD1 — `maybe_hypothesis/3` sits on the success branch, with a function-level `rescue`

```elixir
# lib/alethea/clinical_record/rag/consultation/live.ex
defp synthesize(kept, query) do
  # ...unchanged through the chain().run/1 case...
      trimmed ->
        {:ok,
         %Answer{
           outcome: :synthesis,
           synthesis: trimmed,
           sources: sources,
           hypothesis: maybe_hypothesis(query, excerpts, kept)   # NEW
         }}
  # ...unchanged, including synthesize/2's own `rescue _ -> provider_failure`...
end

# PD2/PD4. Own rescue boundary: an inner function-level rescue always wins over
# synthesize/2's, so no hypothesis defect can downgrade a valid synthesis.
defp maybe_hypothesis(query, excerpts, kept) do
  if HypothesisPolicy.interpretive_intent?(query) do
    citable = Enum.filter(kept, &(String.trim(&1.content) != ""))

    with false <- citable == [],
         {:ok, %{hypothesis: prose}} <- hypothesis_chain().run(%{question: query, excerpts: excerpts}),
         {:ok, hypothesis} <- HypothesisPolicy.evaluate(prose, citable) do
      hypothesis
    else
      _ -> nil
    end
  else
    nil
  end
rescue
  _error -> nil
end

defp hypothesis_chain,
  do:
    Application.get_env(
      :alethea,
      :clinical_hypothesis_chain,
      Alethea.AI.Chains.ClinicalHypothesisChain
    )
```

| Sub-decision | Choice | Rejected | Rationale |
|---|---|---|---|
| Rescue placement | Function-level `rescue` on `maybe_hypothesis/3` | Inline `try/rescue` inside `synthesize/2` | Distinct boundary the spec demands (R3); the inner clause catches first, structurally, so `synthesize/2`'s clause is unreachable from the hypothesis path. |
| `catch` clauses | `rescue` only | `rescue` + `catch :throw/:exit` | Parity with the existing `synthesize/2` boundary. A chain adapter returns tuples or raises; a `throw` would already escape today's synthesis path, so this is not a new hole. |
| Gate order | `interpretive_intent?/1` before the chain | classify after generation | PD4 — a factual turn makes zero LLM calls. |
| Empty-excerpt guard | filter `kept` to non-blank `content`; return `nil` without calling `evaluate/2` when the filtered list is empty | let `evaluate/2` return `{:reject, :no_evidence}` | Closes the proposal's `source_to_citation/1` raise risk (`hypothesis_panel.ex:121`) *and* preserves the spec's literal claim that `evaluate/2` never sees `results == []` through `answer/4`. Filtering is scoped to the hypothesis's sources only — `Answer.sources` (Síntesis) is untouched. |
| Query used | `query` (the raw arg `synthesize/2` already receives) | `resolved_query` | `resolve_query/2` is identity today (#232a); using `query` keeps the diff to zero extra plumbing. #233 revisits. |

`hypothesis_chain/0` mirrors `chain/0` verbatim. `config/test.exs:32` already points `:clinical_hypothesis_chain` at `Alethea.AI.ClinicalHypothesisChainMock` — no config change is needed in any env.

### AD2 — `Consultation.Fake` carries an injected hypothesis; it never calls `HypothesisPolicy`

This is the decision that keeps R9/R11 satisfiable. `fake.ex` lives under `lib/`, so the "exactly one call site" AST scan globs it. A fake that called `HypothesisPolicy.evaluate/2` would be a second call site and would force an allowlist that hollows out the invariant.

```elixir
# lib/alethea/clinical_record/rag/consultation/fake.ex
:synthesis ->
  {:ok,
   %Answer{
     outcome: :synthesis,
     synthesis: canned_synthesis(),
     sources: canned_sources(),
     hypothesis: selected_hypothesis(opts)   # NEW — pass-through, never constructed here
   }}

defp selected_hypothesis(opts),
  do: Keyword.get(opts, :hypothesis) ||
        Application.get_env(:alethea, :consultation_fake_hypothesis)
```

The `%Hypothesis{}` itself is built in **test-support** (`test/support/fixtures/rag_fixtures.ex`, already imported by `consultation_live_test.exs`), through the real policy, matching the proposal's "never hand-rolled" constraint:

```elixir
# test/support/fixtures/rag_fixtures.ex
def canned_hypothesis! do
  {:ok, hypothesis} =
    HypothesisPolicy.evaluate(
      "Podría existir una relación entre las caminatas pactadas y la mejoría del ánimo.",
      canned_results()
    )

  hypothesis
end

def set_fake_hypothesis(h), do: Application.put_env(:alethea, :consultation_fake_hypothesis, h)
def reset_fake_hypothesis, do: Application.delete_env(:alethea, :consultation_fake_hypothesis)
```

`test/**` is outside the `lib/**/*.ex` scan glob, so the invariant holds with no allowlist. `fake.ex` also constructs no `%Hypothesis{}`, so PR #273's Sole Constructor Gate stays green. `canned_sources/0` is refactored to `Source.from_results(canned_results())` so the fake's sources and the fixture's hypothesis cite the same fragment. `reset_fake_hypothesis/0` joins `reset_fake_outcome/0` in the existing `on_exit`.

### AD3 — Panel mounts as a guarded sibling after `#consultation-sources`

```heex
<%!-- lib/alethea_web/live/consultation_live.ex, after the sources <section> --%>
<.hypothesis_panel
  :if={@state == :synthesis}
  id={"consultation-hypothesis-turn-#{@turn}"}
  hypothesis={@last_answer.hypothesis}
/>
```

plus `import AletheaWeb.GroundedChat.HypothesisPanel, only: [hypothesis_panel: 1]`.

| Sub-decision | Choice | Rationale |
|---|---|---|
| `:if={@state == :synthesis}` at the call site | required | `@last_answer` is unassigned on `:idle`/`:stale`/`:no_evidence`; a function-component attribute is evaluated at the call site, so `@last_answer.hypothesis` would raise `KeyError` without the guard. The panel's own `:if={@hypothesis}` still owns structural absence for `hypothesis: nil` (R4). |
| DOM order Síntesis → Fuentes → Hipótesis | after `#consultation-sources` | Siblings under `<div class="consultation">` (R12, closes #231 PD2); Fuentes physically separating the two panels reinforces ADR-010 §2's *separación visible*. |
| `id` keyed on `@turn` | per-turn id | `@turn` increments on every answer, so a new turn yields a new DOM id and LiveView replaces the node instead of patching a stale `<details open>` state across turns. |

### AD4 — `citation/1` gains an optional `:link` slot rendered inside `<summary>` (#235c, Q2/b)

```elixir
# lib/alethea_web/components/core_components.ex
slot :link, doc: "optional navigation affordance; the caller owns the route"

# inside <summary>, after the ref span:
<span :if={@link != []} class="citation__link">{render_slot(@link)}</span>
```

Call site:

```heex
<.citation_list citations={@citations}>  <%!-- or a :for over <.citation> --%>
  <:link :let={c} :if={link_for(c, @patient_id)}>
    <.link navigate={link_for(c, @patient_id)}>Ver conducta objetivo</.link>
  </:link>
</.citation_list>
```

| Option | Tradeoff | Decision |
|---|---|---|
| Slot in `<summary>` | Always in the DOM and always visible, matching today's affordance; an `<a>` in `<summary>` also toggles the disclosure on click (cosmetic) | **Chosen** |
| Slot in the `<details>` body | Clean click semantics, but the body is `:if={@expanded}` — the link would be absent from collapsed DOM, failing R10's "is present" assertion | Rejected |
| `href` attr on `citation/1` | Forces `core_components.ex` to know `~p"/patients/.../target_behaviors/..."` routes | Rejected — the component must stay route-agnostic |

`ConsultationLive`'s `source_link/2` survives as the slot's route helper; `source_kind_label/1` and `format_datetime/1` are the migration's real casualties — see Open Questions.

**Adapter reuse.** `hypothesis_panel.ex`'s private `source_to_citation/1` is promoted to a public, shared converter so both panels feed `citation_list/1` from `%Source{}`. Its moduledoc already anticipates this ("si #235 termina necesitando la misma conversión … promoverlo a público ahí"). Home: `AletheaWeb.GroundedChat.SourceCitation` (new, ~30 lines) rather than `citation.ex`, keeping the `%Source{} → %Citation{}` presentation adapter in the web layer.

### AD5 — Extract the AST walker into shared test support (the reuse call)

**Recommendation: extract now, in a dedicated pure-refactor slice (#235a0), and migrate the existing gate in the same PR.**

`hypothesis_policy_test.exs:282-303` holds a private `hg_walk/2` that distinguishes pattern context from expression context. #235 needs a second scanner shape (call expressions) used by two different assertions. Writing it inline would produce a third copy of a subtle walker whose *first* version already shipped a false-positive bug (PR #273).

| Option | Tradeoff | Decision |
|---|---|---|
| Duplicate the walker in a new test file | Zero churn on a merged, green gate test; two implementations that can drift, and the #273 bug class re-enters through the copy | Rejected |
| Extract `calls?/3` only, leave `hg_walk/2` in place | Small diff; leaves two AST walkers in the suite — the worst of both | Rejected |
| **Extract both into `test/support/ast_scan.ex` and rewrite the Sole Constructor Gate to call it** | +~70 new lines, +3/−24 in the merged test; one audited implementation, and the existing green gate test *is* the behaviour-preserving regression proof for the extraction | **Chosen** |

```elixir
# test/support/ast_scan.ex — AletheaTest.ASTScan
@spec lib_files(exclude: [String.t()]) :: [Path.t()]
@spec parse!(Path.t()) :: Macro.t()

# Expression-context struct construction (moved verbatim from hg_walk/2).
@spec constructs_struct?(Macro.t(), atom()) :: boolean()

# Qualified call / capture / apply / import detection. NO pattern-context
# tracking: a call expression is illegal in a pattern, so the context
# bookkeeping constructs_struct?/2 needs is provably unnecessary here.
@spec calls?(Macro.t(), module_suffix :: atom(), [atom()]) :: boolean()
```

`calls?/3` must treat all five of these as a call site, and none of the three non-call forms:

| Source form | AST shape | Verdict |
|---|---|---|
| `HypothesisPolicy.evaluate(a, b)` | `{{:., _, [{:__aliases__, _, [:HypothesisPolicy]}, :evaluate]}, _, _}` | call |
| `Alethea.…​.HypothesisPolicy.evaluate(a, b)` | same, alias segments `[:Alethea, …, :HypothesisPolicy]` | call — match the **suffix** of the segment list, never equality |
| `&HypothesisPolicy.evaluate/2` | `{:&, _, [{:/, _, [{{:., …}, _, []}, 2]}]}` | call (inner dot node matches under prewalk) |
| `apply(HypothesisPolicy, :evaluate, args)` | `{:apply, _, [{:__aliases__, …}, :evaluate, _]}` | call — closes the obvious bypass |
| `import …HypothesisPolicy` | `{:import, _, [{:__aliases__, …} \| _]}` | call — the only route to an unqualified `evaluate/2` |
| `@moduledoc "… HypothesisPolicy.evaluate/2 …"` | binary literal | **not** a call — the #273 lesson, structurally guaranteed |
| `alias …HypothesisPolicy` | `{:alias, _, _}` | not a call |
| `%Hypothesis{} = h` in a head | struct node | not a call |

**Scan test location: a new dedicated file**, `test/alethea/clinical_record/rag/consultation/hypothesis_wiring_gate_test.exs` (`use ExUnit.Case, async: true` — no DB, no `DataCase`). It spans domain *and* web, so it belongs in neither `live_test.exs` (a `DataCase` about `answer/4` behaviour) nor `consultation_live_test.exs` (a `ConnCase`, `async: false`). It holds both spec scenarios plus a negative control asserting a prose mention is not a violation. `ast_scan.ex` gets its own unit test at `test/alethea/test_support/ast_scan_test.exs` with the full positive/negative table above.

## Data Flow

```
answer/4 → authz → freshness → retrieval → threshold → tombstone
  └─ synthesize(kept, query)
       sources  = Source.from_results(kept)          (unchanged)
       excerpts = Enum.map(kept, &Sanitizer.sanitize/1)   (reused, not recomputed)
       chain().run ─► trimmed synthesis
            └─ maybe_hypothesis(query, excerpts, kept)   [own rescue]
                 intent? false ──────────────────► nil   (0 LLM calls)
                 citable == []  ─────────────────► nil   (evaluate/2 never sees [])
                 hypothesis_chain().run ─► prose
                      └─ HypothesisPolicy.evaluate(prose, citable)
                           {:ok, %Hypothesis{}} ─► hypothesis
                           {:reject, _} | raise ─► nil
       %Answer{outcome: :synthesis, synthesis:, sources:, hypothesis:}

ConsultationLive.render/1   (siblings under div.consultation)
  <section id="consultation-synthesis">          Síntesis
  <section id="consultation-sources">            Fuentes
  <section class="review-hypothesis-panel">      Hipótesis  ← absent when nil
```

## File Changes

| File | Action | Slice |
|---|---|---|
| `lib/alethea/clinical_record/rag/consultation/live.ex` | Modify — `maybe_hypothesis/3`, `hypothesis_chain/0`, alias, wiring | #235a |
| `lib/alethea/clinical_record/rag/consultation/answer.ex` | Modify — moduledoc closes the "#235 will wire this" note | #235a |
| `lib/alethea/clinical_record/rag/consultation/fake.ex` | Modify — `selected_hypothesis/1`, `canned_results/0` extraction | #235b |
| `lib/alethea_web/live/consultation_live.ex` | Modify — import + panel mount (#235b); source list migration (#235c) | #235b, #235c |
| `lib/alethea_web/components/core_components.ex` | Modify — `slot :link` on `citation/1` | #235c |
| `lib/alethea_web/live/grounded_chat/hypothesis_panel.ex` | Modify — delegate to the promoted converter; moduledoc hand-off closed | #235c |
| `lib/alethea_web/live/grounded_chat/source_citation.ex` | **Create** — public `%Source{} → %Citation{}` adapter | #235c |
| `test/support/ast_scan.ex` | **Create** — `AletheaTest.ASTScan` | #235a0 |
| `test/alethea/test_support/ast_scan_test.exs` | **Create** | #235a0 |
| `test/alethea/…/hypothesis_policy_test.exs` | Modify — Sole Constructor Gate calls `ASTScan`; `hg_walk/2` deleted | #235a0 |
| `test/alethea/…/hypothesis_wiring_gate_test.exs` | **Create** | #235a |
| `test/alethea/…/consultation/live_test.exs` | Modify — extend existing describes + one new | #235a |
| `test/support/fixtures/rag_fixtures.ex` | Modify — `canned_hypothesis!/0`, set/reset helpers | #235b |
| `test/alethea_web/live/consultation_live_test.exs` | Modify — new E2E describes (#235b); migrated source assertions (#235c) | #235b, #235c |
| `test/alethea_web/components/citation_test.exs` | Modify — `:link` slot coverage | #235c |
| `test/alethea_web/live/grounded_chat/hypothesis_panel_test.exs` | Modify — converter delegation | #235c |

## Slicing Plan (refines the proposal's 3-slice forecast to 4)

Feature Branch Chain off `feat/grounded-chat-235-integration`; each child PR targets the previous slice's branch.

| Slice | Content | Est. `+`/`−` | Budget |
|---|---|---|---|
| **#235a0** — AST scan extraction | `ast_scan.ex` (~70), `ast_scan_test.exs` (~90), `hypothesis_policy_test.exs` migration (+3/−24) | **~187** | Low — pure test-infra refactor, green before and after, zero production diff |
| **#235a** — domain wiring + gate | `live.ex` (~+32), `answer.ex` (~+4), `live_test.exs` (~+160), `hypothesis_wiring_gate_test.exs` (~+70) | **~266** | Medium |
| **#235b** — panel mount + E2E | `consultation_live.ex` (~+12), `fake.ex` (~+15/−6), `rag_fixtures.ex` (~+25), `consultation_live_test.exs` (~+170) | **~228** | Medium |
| **#235c** — citation unification | `core_components.ex` (+15/−3), `consultation_live.ex` (+18/−26), `source_citation.ex` (+32), `hypothesis_panel.ex` (+4/−30), `citation_test.exs` (+55), `consultation_live_test.exs` (+35/−18), `hypothesis_panel_test.exs` (+15/−8) | **~259** | Medium |

Total ≈ **940** across 4 PRs, none exceeding the 400-line budget. The proposal folded #235a0 into #235a (~453, over budget); splitting the pure refactor out is what brings both under. `400-line budget risk: Low` per slice — `sdd-tasks` owns the binding forecast.

## Test Plan — 12 requirements → file + describe

| # | Requirement | File | Describe | Status | Slice |
|---|---|---|---|---|---|
| R1 | Interpretive query produces a gated hypothesis | `live_test.exs` | `answer/4 — synthesis on sufficient evidence` | **extend** | #235a |
| R2 | Factual query never invokes the chain (PD4) | `live_test.exs` | `answer/4 — synthesis on sufficient evidence` | **extend** — `expect(ClinicalHypothesisChainMock, :run, 0, …)` | #235a |
| R3 | Hypothesis failure isolated from synthesis (PD2) | `live_test.exs` | `answer/4 — the hypothesis path is additive and fail-silent (#235)` | **new describe** — raise / `{:error, _}` / `{:reject, _}` / blank prose, all asserting `outcome: :synthesis` | #235a |
| R4 | Structural presence/absence in rendered output | `consultation_live_test.exs` | `hypothesis panel over the real pipeline (#235)` | **new describe** | #235b |
| R5 | E2E proof of panel invariants through the real flow | `consultation_live_test.exs` | same describe | **new** — disclaimer byte offset < statement offset; `<details>` collapsed then expanded | #235b |
| R6 | Cross-patient / cross-tenant isolation | `live_test.exs` | `answer/4 — cross-patient isolation` + `— cross-tenant isolation` | **extend both** with an interpretive query | #235a |
| R7 | No clinical-state mutation | `live_test.exs` | `answer/4 — clinical state is never mutated` | **extend** — byte-identical chunks, `Oban` job count 0, no `Repo` write on a hypothesis turn | #235a |
| R8 | No hypothesis without server-derived evidence, E2E | `live_test.exs` (domain) + `consultation_live_test.exs` (render) | R3's new describe / R4's new describe | **extend both** — diagnostic + prescriptive prose ⇒ `nil` and no panel. Zero-evidence half is covered by construction (spec §R8) plus AD1's `citable == []` short-circuit; no new E2E test | #235a, #235b |
| R9 | Interpretive intent stays domain-owned (PD3) | `hypothesis_wiring_gate_test.exs` | `Hypothesis Wiring Gate — AST scan` | **new file** — `consultation_live.ex` has no call expression | #235a |
| R10 | Citation unification preserves navigation (Q2/b) | `citation_test.exs` + `consultation_live_test.exs` | `citation/1 — optional link slot` (new) / existing `grounded answer over the real pipeline (#234a)` | **new + extend** — link present for non-nil `target_behavior_id`, absent and error-free for `nil` | #235c |
| R11 | Bounded wiring into the real flow (#229 MODIFIED) | `hypothesis_wiring_gate_test.exs` + `live_test.exs` | same gate describe; `Answer.outcome` vocabulary + `ClinicalConsultationChain` byte-identity | **new file + extend** — exactly one `lib/**` call site, and it is `consultation/live.ex` | #235a |
| R12 | Structural separation from Síntesis (#231 PD2) | `consultation_live_test.exs` | R4's new describe | **new** — both `<section>`s exist, share a parent, neither nested | #235b |

**Apply-phase hazard to carry into tasks:** once `synthesize/2` calls `hypothesis_chain()`, every *existing* `live_test.exs` and `consultation_live_test.exs` query is re-classified by `interpretive_intent?/1`. Any legacy fixture query containing an interpretive marker (`patron`, `por que`, `tendencia`, `relacion entre`, …) will newly hit `ClinicalHypothesisChainMock` with no expectation and fail under Mox strict mode. #235a's first RED-to-GREEN step must run the full existing suite and, where a legacy query classifies interpretive, either reword it or add an explicit expectation — never add a blanket `stub/3`, which would silently void R2.

## Threat Matrix

N/A — no routing, shell, subprocess, VCS/PR automation, executable-file classification, or process-integration boundary. The one adjacent surface is the `<.link navigate>` to `/patients/:id/target_behaviors/:id/review` in #235c, which reuses an existing route whose own authorization is unchanged and out of scope.

## Migration / Rollout

No migration. No schema, no config default change, no persisted data (ADR-010 §6). Per-slice revert; reverting #235a restores `hypothesis: nil` in every `Answer`, which is today's production behaviour exactly.

## Open Questions

- [ ] **#235c label regression.** `citation/1` renders the raw `kind` (`"clinical_note"`); `ConsultationLive` renders `source_kind_label/1` (`"Nota clínica"`). Migrating as-is regresses human-readable labels and breaks `consultation_live_test.exs:202,211`. Recommendation: move `source_kind_label/1` into `core_components.ex` as `citation/1`'s private `kind_label/1`, making the single renderer also the single humanizer — which also upgrades the hypothesis panel's cites for free. Cost: touches #230's shipped DOM assertions, which Q2(b) already accepted.
- [ ] **#235c datetime precision.** `citation/1` renders an ISO date; `ConsultationLive` renders `%d/%m/%Y %H:%M`. Unification drops the time-of-day. Recommendation: accept the loss (a cite's clinical relevance is day-level), or add an optional `attr :datetime, :boolean, default: false`. Confirm before #235c; not covered by the spec.
- [ ] **Slot name `:link`.** `<.link>` is an imported function component in the same module; `@link` as a slot assign does not collide, but if HEEx compilation objects, fall back to `:navigation`.
