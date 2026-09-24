# Exploration — eorc-draft-chain-316 (#316)

**Status:** exploration complete
**Date:** 2026-09-24
**Issue:** #316 — Cadena LLM para descomposición funcional E-O-R-C
**Parent:** #314 — Spec: Semantic evidence discovery, E-O-R-C auto-drafting, and session audio transcriptions
**Scope boundary (confirmed):** the LLM chain only — prompt builder, JSON parser, `LLMConfig` registration. NOT the LiveView button (#319, blocked-by #316, unassigned) or any wiring into `TargetBehaviorLive.Review`.

## Executive summary

The 11 E-O-R-C fields are authoritatively defined in `lib/alethea/clinical_record/functional_analysis_content.ex:19-32` (antecedents_distal/immediate, organism_sleep/pain_or_discomfort/hunger_or_nutrition/learning_history, response_physiological/cognitive/motor, consequences_short_term/long_term — `previous_notes` is explicitly a 12th, non-E-O-R-C field). The SLM-schema-echo parsing bug already has one narrow precedent in `PatternProposalChain.parse_proposals/1`. Recommend generalizing it into a shared recursive unwrapper in `Alethea.AI.StructuredOutput` rather than repeating an 11-key narrow match.

## Current state (file:line)

### The 11 E-O-R-C fields — `lib/alethea/clinical_record/functional_analysis_content.ex:19-32` (`@fields`)

1. `antecedents_distal`
2. `antecedents_immediate`
3. `organism_sleep`
4. `organism_pain_or_discomfort`
5. `organism_hunger_or_nutrition`
6. `organism_learning_history`
7. `response_physiological`
8. `response_cognitive`
9. `response_motor`
10. `consequences_short_term`
11. `consequences_long_term`

Plus a 12th, `previous_notes` — explicitly NOT an E-O-R-C field ("legacy text ... never interpreted to populate E-O-R-C fields", lines 11-13). All values are plain strings. `new/1` (lines 53-62) builds the struct from a *string-keyed* map, defaulting missing/non-binary values to `""`. This is the exact target shape #316's `parse/1` must produce.

### Persistence target (confirms output shape, even though wiring is #319's job)

`lib/alethea/clinical_record.ex:1135-1162` `upsert_functional_analysis_content/4` feeds a plain map straight into `FunctionalAnalysisContent.new/1`. So the chain's parser output should be a map of the 11 keys → plain strings, no `previous_notes`, no nesting.

### Structural-safety precedent — `Hypothesis`/`HypothesisPolicy`

Actual path is `lib/alethea/clinical_record/rag/consultation/hypothesis.ex` + `hypothesis_policy.ex`. `HypothesisPolicy.evaluate/2` is a pure, LLM-free regex-based diagnostic/prescriptive-language veto that is the *sole constructor* of `Hypothesis`; the chain itself never builds the typed struct. #316's stated acceptance criteria do NOT require an equivalent policy module — "without diagnosing" is satisfied via system-prompt wording only, matching `PatternProposalChain`'s approach (`pattern_proposal_chain.ex:51-57`, "NUNCA diagnostiques" as prose rules), not `HypothesisPolicy`'s runtime gate.

### Chain precedents

`lib/alethea/ai/chains/clinical_hypothesis_chain.ex` and `lib/alethea/ai/chains/pattern_proposal_chain.ex`: both implement `ChainBehaviour`, both expose public `build_prompt/1` + a pure parser, both wrap `LLMChain` + telemetry identically in `do_run/2`. #316 should clone `clinical_hypothesis_chain.ex`'s skeleton (it's `:local`-only like #316 needs, vs. `PatternProposalChain`'s `[:local, :cloud]`).

### The SLM-schema-echo bug already exists in the codebase, solved narrowly once

`pattern_proposal_chain.ex:111-120`:
```elixir
case StructuredOutput.parse_json_response(cleaned) do
  {:ok, %{"proposals" => proposals}} when is_list(proposals) -> Enum.filter(proposals, &is_binary/1)
  {:ok, %{"properties" => %{"proposals" => proposals}}} when is_list(proposals) -> Enum.filter(proposals, &is_binary/1)
  _ -> []
end
```
Confirmed real (not hypothetical) by its test, `test/alethea/ai/chains/pattern_proposal_chain_test.exs:41-45` ("SLM schema echo"). This is the **only** existing precedent — a single-key narrow heuristic, not generic.

### `Alethea.AI.StructuredOutput` (`lib/alethea/ai/structured_output.ex`)

Has NO generic properties-unwrap helper. `parse_json_response/1` (lines 31-47) only strips a *leading* markdown fence, not trailing — `PatternProposalChain.parse_proposals/1` itself strips both fences at the call site as a workaround (lines 104-109). This is a real, unsolved shared gap.

### `LLMConfig` registration

`lib/alethea/ai/llm_config.ex:26-33, 234-240`: closed `chain_name` union + 1:1 `chain_module/1` clauses. Add `:functional_analysis_draft` mirroring `:consultation_hypothesis → ClinicalHypothesisChain`. `supported_providers/0` must be `[:local]` only (PHI in prompt) — `ClinicalHypothesisChainTest` even statically scans the module source to assert absence of the `:cloud` literal (lines 130-143); #316 should mirror that test.

### Module name

Confirmed verbatim from #314's "Implementation Decisions": `Alethea.AI.Chains.FunctionalAnalysisDraftChain`, tested via pure `build_prompt/1` and `parse/1`.

### Sibling issues

#315 (dismissal persistence) and #318 (RAG affinity scoring) do NOT touch or define the E-O-R-C field shape — confirmed by fetching both bodies. The shape is stable, pre-existing, no conflict risk. #319 (blocked by #316, unassigned) explicitly says "populating eleven form fields while preserving existing clinician notes" — the non-destructive merge is #319's job, not #316's.

### Test conventions

`test/alethea/ai/chains/clinical_hypothesis_chain_test.exs` and `pattern_proposal_chain_test.exs`: `describe "build_prompt/1"`/`"parse/1"` table-style clean/malformed cases, `describe "LLMConfig integration"` asserting `provider == :local`, `describe "supported_providers/0"` with a static-source `:cloud`-absence scan, and (in the hypothesis test only) a structural-safety scan (`refute source =~ "upsert_functional_analysis_draft"`, `"Alethea.ClinicalRecord"`, `"Repo."`). #316 should include the equivalent structural scan against `upsert_functional_analysis_content`.

## Approaches compared — SLM schema-echo parser (11 fields)

### 1. Generic recursive schema-shape unwrapper (RECOMMENDED)

In `Alethea.AI.StructuredOutput` (e.g. `unwrap_schema_echo/1`) — detect a `"properties"` wrapper map and recurse before field extraction.

- **Pros:** one reusable path for all 11 fields + future chains; matches the issue's general wording; independently testable; keeps `parse/1` short.
- **Cons:** slightly more abstract; needs care around false-positive unwrap (no real risk here — none of the 11 field names is `"properties"`).
- **Effort:** Low-Medium.

### 2. Narrow heuristic tied to the exact 11 field names

Repeat `PatternProposalChain`'s single-key clause pattern, scaled to 11 keys.

- **Pros:** zero new abstraction, literally consistent with the one existing precedent.
- **Cons:** unwieldy at 11 fields (one large match or a reinvented loop = option 1's logic anyway); doesn't fix `PatternProposalChain`'s duplication; brittle to schema variants.
- **Effort:** Low, but scales worse.

## Recommendation

Option 1 — generic recursive unwrapper added to `Alethea.AI.StructuredOutput`, plus extending `parse_json_response/1` to strip trailing fences (fixes a real existing gap `PatternProposalChain` works around locally). Do NOT migrate `PatternProposalChain` onto the new helper in this PR — flag as optional follow-up only.

## Affected areas

- `lib/alethea/ai/chains/functional_analysis_draft_chain.ex` (new) — clone of `clinical_hypothesis_chain.ex` skeleton.
- `lib/alethea/ai/structured_output.ex` — add generic unwrapper + trailing-fence fix (additive).
- `lib/alethea/ai/llm_config.ex` — add `:functional_analysis_draft` type + `chain_module/1` clause.
- `test/alethea/ai/chains/functional_analysis_draft_chain_test.exs` (new).
- Possibly `test/alethea/ai/structured_output_test.exs` (existence to confirm in design/tasks).
- No changes to `lib/alethea/clinical_record.ex`, `functional_analysis_content.ex`, or any LiveView — confirmed out of #316's scope.

## Risks

1. `StructuredOutput` is shared by 5+ existing chains (`SessionSummaryChain`, `WeeklySummaryChain`, `GuidedConversationChain`, `ClinicalHypothesisChain`, `PatternProposalChain`) — even additive changes need regression coverage across all callers.
2. Real SLM output shape against phi4-mini for an 11-field schema is unproven by unit tests alone (synthetic fixtures only) — matches an existing gap in every other chain's test suite (no live-endpoint tests anywhere in this codebase).
3. Scope creep risk if design bundles a `PatternProposalChain` migration onto the new shared helper into the same PR — defer as a separate ticket.
4. 400-line budget: estimated ~250-350 authored changed lines (chain ~120-160, StructuredOutput +30-50, LLMConfig +10, tests ~150-200) — likely fits in one PR.

## Key learnings

1. The 11 E-O-R-C fields are defined in `FunctionalAnalysisContent.@fields`, excluding the 12th field `previous_notes`.
2. `PatternProposalChain.parse_proposals/1` already handles one real instance of SLM schema echoing under a `properties` key.
3. `Alethea.AI.StructuredOutput.parse_json_response/1` only strips leading markdown fences, not trailing ones.
4. `ClinicalHypothesisChain` is the closest structural precedent: local-only, pure `build_prompt/1` and `parse/1`, telemetry-wrapped `do_run/2`.
5. Issue #319 depends on #316 and owns the non-destructive clinician-notes preservation logic, not the chain itself.
