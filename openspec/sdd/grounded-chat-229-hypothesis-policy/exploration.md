# Exploration — grounded-chat-229-hypothesis-policy (#229)

**Status:** exploration complete
**Date:** 2026-09-16
**Issue:** #229 — Implementar la política de hipótesis revisable
**Parent:** #225 — Hipótesis revisables para consultas interpretativas
**Siblings:** #230 (citation renderer, merged via PR #248), #231 (hypothesis panel, draft prototype PR #250), #235 (real wiring — blocked by #226, #229, #230, #231, #234)
**Authority:** ADR-010 §2 ("Hipótesis para revisar"), `openspec/UBIQUITOUS_LANGUAGE.md`, spec issue #221

## Executive summary

#229's revisable-hypothesis policy should ship as a standalone, pure `HypothesisPolicy` decision module plus a sibling `ClinicalHypothesisChain` (not a variant of the frozen `ClinicalConsultationChain`), additive to `Answer` via a new `hypothesis` field rather than a 5th outcome, emitting the contract-canonical `Source` struct (not the parallel `Citation` type from #230), and deliberately unwired from the real consultation flow — that integration is #235's explicitly blocked-on scope.

## Current state (file:line)

Base branch: `feat/grounded-clinical-chat-hypotheses` (the #225 tracker), rebased against `origin/main` on 2026-09-16 — `main` already carries #223's fully-shipped chain (PR #257), so `Consultation`/`Answer`/`Source`/`ClinicalConsultationChain`/`LLMConfig` are all present. (The initial exploration ran on `feat/223-grounded-clinical-chat` before this rebase; the tracker now has equivalent content.)

### The consultation contract (#226a)

`lib/alethea/clinical_record/rag/consultation/answer.ex`:
```elixir
@type outcome :: :synthesis | :no_evidence | :stale | :provider_failure
@enforce_keys [:outcome]
defstruct [:outcome, :synthesis, sources: [], pending: 0]
```

`lib/alethea/clinical_record/rag/consultation/source.ex`: `Source` is built only via `Source.from_results/1` from `Rag.Retrieval.search/4` rows — `%Source{excerpt, kind, occurred_at, reference: %{chunk_id, resource_type, resource_id, target_behavior_id}}`.

### The synthesis chain (#226b)

`lib/alethea/ai/chains/clinical_consultation_chain.ex`: `:local`-only, pure `build_prompt/1`/`parse/1`, no chunk/resource ids sent to the model (structurally can't fabricate a citation), `parse/1` fails loud on empty/malformed output (AD8). It carries a **verbatim-asserted system-prompt regression test** — extending it risks a regression to already-merged, closed work.

`lib/alethea/ai/llm_config.ex`: `chain_name` is a **closed type**; `:consultation_synthesis` is already registered. Adding a new chain requires one visible, compile-checked clause.

### A pre-existing duplicate citation type (#230, PR #248)

`lib/alethea/clinical_record/rag/citation.ex` — `%Citation{source_ref, kind, occurred_at, excerpt, score, chunk_index}`, rendered by `AletheaWeb.CoreComponents.citation/1`/`citation_list/1`. Its own moduledoc says #235 will "unify this renderer... and replace it with `Consultation.Source` from #226a as the upstream value type" — this duplication is known, pre-existing tech debt, not something #229 should deepen.

**Tracker-health note:** #230's merge (PR #248) landed with three defects, unrelated to #229, fixed by the orchestrator while rebasing this branch onto main (commit `c68a857`): a `citation/1` naming collision in an unrelated old prototype LiveView, an unused-variable warning-as-error, and an invalid `_` used as a call argument in a test. Two genuine test-assertion bugs remain UNFIXED and are #230's own author's to resolve: a message-text mismatch in `citation_test.exs:90` and a `reject_unknown_refs/2` logic bug at `citation_test.exs:134`.

### #231's current state — a disconnected prototype, not a locked interface

#231 (hypothesis panel) so far is only a draft prototype PR #250 (`AletheaWeb.ClinicalReviewPrototypeLive`, already in-tree), using a throwaway URL-param `interpretive` gate and a third, unrelated ad-hoc citation shape (`source_id, source_label, origin, quote`). It must not be treated as a real consumer interface for #229.

### #235 confirms the scope boundary

#235 ("Integrar hipótesis interpretativas en la consulta real") is Open, unassigned, **Blocked By: #226, #234, #229, #230, #231** — confirms real wiring into `Consultation.Live`/`ConsultationLive` is explicitly out of #229's scope.

### ADR-010 §2 — additive, not terminal

> "...puede incluir además una **Hipótesis para revisar**, diferenciada de la síntesis, obligatoriamente citada y revisable por el psicólogo. Una hipótesis no es un diagnóstico ni una recomendación terapéutica."

"Puede incluir además" (may additionally include) establishes the hypothesis as **additive** to the synthesis outcome, not a fifth terminal outcome value.

### Precedent for "hypothesis, never diagnose" prompting

`lib/alethea/ai/chains/pattern_proposal_chain.ex` (older #195 feature) — prompt-only enforcement, no citation attachment, `[:local, :cloud]` providers (does not apply here — ADR-010 §2 forces local-only, like `ClinicalConsultationChain`).

### OpenSpec state

No existing `openspec/sdd/hypothes*` change dir before this exploration; only `openspec/sdd/grounded-clinical-chat-initial/` (the #223 tracker) existed.

## Approaches compared

### 1. Fold into `ClinicalConsultationChain`

Extend its schema to `{synthesis, hypothesis}`, let the model self-judge interpretive intent via prompt.

- **Pros:** one LLM round-trip.
- **Cons:** intent decision hidden in LLM judgment, not independently testable (the issue explicitly wants a "testable policy"); reopens #226b's already-merged, verbatim-asserted system-prompt regression test — real regression risk to closed work; blurs AD4 (chain returns synthesis only, never gates).
- **Effort:** Medium, hidden regression risk.

### 2. Separate pure `HypothesisPolicy` module gating a sibling `ClinicalHypothesisChain` (RECOMMENDED)

- `HypothesisPolicy.interpretive_intent?/1`: pure deterministic heuristic (Spanish interrogative/relational markers), zero LLM cost on the factual path.
- `HypothesisPolicy.evaluate/2`: structurally rejects empty sources (no evidence → no hypothesis) and diagnostic/prescriptive lexical patterns, and **injects** the mandatory disclaimer itself rather than trusting the LLM.
- New sibling chain `Alethea.AI.Chains.ClinicalHypothesisChain` (own `:consultation_hypothesis` chain_name, `:local`-only, own prompt), invoked only when policy says interpretive + evidence exists, over the same retrieved excerpts (no second retrieval).
- **Pros:** matches "single testable module" literally, zero touch to #226b's frozen artifacts, independently sliceable, follows the codebase's existing behaviour+facade+pure-function convention.
- **Cons:** two LLM calls on the interpretive path (acceptable — opt-in only).
- **Effort:** Medium, no regression risk.

## Recommendation

**Approach 2.** Ship #229 as a standalone, Fake-testable module — `Hypothesis` struct + `HypothesisPolicy` + `ClinicalHypothesisChain` — with **no** wiring into `Consultation.Live`/`ConsultationLive`/real chain call sites; that belongs to #235 per its own "Blocked By" list. `Answer` gets an additive `hypothesis: Hypothesis.t() | nil` field (never a 5th outcome), populated only alongside `:synthesis`.

## Slice boundaries

- **#229a** — `Hypothesis` struct + `HypothesisPolicy.interpretive_intent?/1` + `evaluate/2`, pure unit tests (~200-260 lines).
- **#229b** — `ClinicalHypothesisChain` mirroring `ClinicalConsultationChain`'s shape, `LLMConfig` clause, Mox mock, chain tests (~180-250 lines).
- **Out of scope (→ #235):** wiring into `Consultation.Live.answer/4`, real `Answer.hypothesis` population, `ConsultationLive` panel rendering, `Source`/`Citation` reconciliation.

## Risks

1. `Source` (#226a) vs `Citation` (#230) duplication is unresolved; #229 should emit `Source` (contract-canonical) but must flag that #235 needs a `Source`→`Citation` adapter (or a `Source` field extension) before `CoreComponents.citation_list/1` can render it unchanged.
2. #231's only artifact (draft PR #250) is a disconnected prototype with an ad-hoc citation shape and URL-param intent toggle — must not be treated as a locked interface.
3. Pure-heuristic `interpretive_intent?/1` will have false negatives/positives on ambiguous Spanish phrasing — acceptable for a first testable slice, but a known limitation, not full NLU.
4. `LLMConfig.chain_name` is a closed type; adding `:consultation_hypothesis` is a small, visible, compile-checked diff (fails loud if forgotten).
5. ~~Base branch missing #226a/#226b~~ — RESOLVED: rebased the #225 tracker onto `main` (commit `c68a857`), which now carries #223's shipped work.

## Key learnings

1. ADR-010's phrase "puede incluir además" establishes the hypothesis as additive to the synthesis outcome, not a fifth terminal outcome value.
2. Two parallel citation value objects already exist in the codebase, `Consultation.Source` and `Rag.Citation`, and their unification is explicitly deferred to issue #235.
3. Issue #235 lists #229, #230, #231, #226, and #234 as blockers, proving the hypothesis policy module must stay unwired from the real consultation flow.
4. The `ClinicalConsultationChain` module carries a verbatim-asserted system prompt regression test, so extending it risks a regression to already-merged work.
5. A parent-issue tracker branch can drift out of sync with `main` even mid-sprint (here, missing an entire sibling parent's shipped chain), so verifying the base branch actually contains a dependency's code — not just trusting its merged-PR history — is a required step before starting implementation.
