# Proposal: Revisable Hypothesis Policy (#229)

**Issue:** #229 (sub-issue of #225) · **ADR:** 010 §2 · **Exploration:** `openspec/sdd/grounded-chat-229-hypothesis-policy/exploration.md`

## Intent

ADR-010 §2 allows a grounded-chat answer to *additionally* include a **Hipótesis para revisar** for interpretive requests — mandatorily cited, never a diagnosis or a therapeutic recommendation. Today nothing decides when a hypothesis applies, nothing enforces citations on it, and nothing structurally prevents diagnostic or prescriptive phrasing: the only precedent (`PatternProposalChain`) relies on prompt discipline alone, which is not testable and not enforceable. #229 delivers the missing **testable policy** as a standalone unit so the clinical guarantee is provable before any UI consumes it.

## Scope

### In Scope
- `Consultation.Hypothesis` struct — `statement`, `sources: [Source.t()]`, `disclaimer` (all enforced).
- `Consultation.HypothesisPolicy` — pure `interpretive_intent?/1` and `evaluate/2` (evidence gate, forbidden-language gate, server-injected disclaimer).
- `AI.Chains.ClinicalHypothesisChain` — sibling of `ClinicalConsultationChain`, `:local`-only, pure `build_prompt/1`/`parse/1`, fails loud; plus its `LLMConfig.chain_name` clause and Mox registration.
- Additive `hypothesis: Hypothesis.t() | nil` field on `Consultation.Answer`, valid only alongside `outcome: :synthesis`.
- Unit/chain tests covering all four acceptance criteria, including diagnosis and prescription rejection.

### Out of Scope (→ #235)
- Wiring policy/chain into `Consultation.Live.answer/4` or `ConsultationLive`; populating `Answer.hypothesis` on a real request.
- Hypothesis panel rendering (#231) and `Source` ↔ `Citation` reconciliation.
- Any change to `ClinicalConsultationChain` or its verbatim-asserted system-prompt regression test.
- LLM-based intent classification, second retrieval pass, persistence of hypotheses.

## Capabilities

### New Capabilities
- `clinical-consultation-hypothesis`: when a revisable hypothesis is produced, its mandatory citations, its forbidden-content rejection, and its disclaimer.

### Modified Capabilities
- None. `Answer` gains an optional field; the `outcome` vocabulary is unchanged (no fifth outcome — ADR-010 says "puede incluir **además**").

## Approach (exploration's Approach 2)

Three separable units, none of which touch frozen #226b artifacts:

1. **Classify** — `interpretive_intent?/1`, deterministic Spanish marker heuristic, zero LLM cost on the factual path.
2. **Generate** — `ClinicalHypothesisChain`, invoked only when intent is interpretive *and* evidence exists, over the same excerpts already retrieved for the synthesis. It receives no chunk/resource ids, so it cannot fabricate a citation (mirrors AD4).
3. **Gate** — `evaluate/2` is the sole constructor of a `Hypothesis`: empty sources → reject; forbidden diagnostic/prescriptive pattern in `statement` → reject; otherwise attach server-derived `Source`s and inject the disclaimer. Rejection is **fail-closed** (no hypothesis at all), never scrub-and-return.

**Slices:** #229a policy + struct (~200–260 lines) · #229b chain + `LLMConfig` clause (~180–250 lines). Both fit the 400-line review budget.

## Affected Areas

| Area | Impact | Description |
|------|--------|-------------|
| `lib/alethea/clinical_record/rag/consultation/hypothesis.ex` | New | Value object, `@enforce_keys` incl. `disclaimer` |
| `lib/alethea/clinical_record/rag/consultation/hypothesis_policy.ex` | New | Pure decision module |
| `lib/alethea/ai/chains/clinical_hypothesis_chain.ex` | New | `:local`-only sibling chain |
| `lib/alethea/clinical_record/rag/consultation/answer.ex` | Modified | Additive `hypothesis` field |
| `lib/alethea/ai/llm_config.ex` | Modified | `:consultation_hypothesis` in closed `chain_name` type + `chain_module/1` |
| `test/alethea/...` | New | Policy, chain, and static source-scan tests |

## Risks

| Risk | Likelihood | Mitigation |
|------|------------|------------|
| **Base branch lacks #226a/#226b.** The current working tree has no `Consultation`, `Answer`, `Source`, `ClinicalConsultationChain`, and `LLMConfig.chain_name` has no `:consultation_synthesis` — the exploration read them on `feat/223-grounded-clinical-chat` | High | **Blocking**: #229 must branch from the integration branch carrying #226a/#226b, not `main`. Confirm before spec/design. |
| Heuristic intent classifier has false positives/negatives on ambiguous Spanish | High | Accepted, documented limitation; table-driven tests pin known phrasings; fail-open to "no hypothesis" |
| Forbidden-pattern scan is lexical, so it can be phrased around | Medium | Defense in depth: prompt + lexical gate + mandatory citations + disclaimer + clinician review; hypothesis is never an autonomous clinical act |
| `Source` vs `Citation` duplication unresolved | Medium | #229 emits `Source` only; adapter is #235's job, explicitly not a blocker for #229 |
| #231's draft prototype (PR #250) mistaken for a locked interface | Low | Proposal states it is throwaway UI exploration |

## Rollback Plan

All units are new files plus two additive edits. Revert = delete the three new modules and their tests, drop the `hypothesis` field from `Answer`, and remove the `:consultation_hypothesis` clauses from `LLMConfig`. No migrations, no persisted data, no call sites in the real consultation flow (by design), so rollback cannot break a shipped user path.

## Dependencies

- #226a (`Answer`/`Source` contract) and #226b (`ClinicalConsultationChain`) must be present in the base branch.
- Blocks #235 (real wiring); sibling of #230/#231.

## Success Criteria

- [ ] `interpretive_intent?/1` is pure and table-testable; factual queries never produce a hypothesis.
- [ ] Every returned hypothesis carries ≥1 server-derived `Source`; zero sources → no hypothesis returned.
- [ ] Diagnostic and prescriptive statements are rejected structurally (not by prompt alone), with tests for both.
- [ ] Every returned hypothesis carries the mandatory disclaimer, injected server-side, never LLM-authored.
- [ ] `mix precommit` passes; `ClinicalConsultationChain` and its prompt regression test are byte-unchanged.

## Locked decisions (D1-D4)

- **D1 — Intent classification: deterministic heuristic.** `interpretive_intent?/1` is a pure, testable Spanish-marker heuristic, never an LLM call. Accepted tradeoff: a false negative (missed interpretive request) just falls through to the normal evidence-based synthesis — never wrong, never harmful.
- **D2 — Disclaimer: fixed verbatim text, structural field.** `"Hipótesis para revisar: no es un diagnóstico ni una recomendación terapéutica."` lives in `@enforce_keys [:disclaimer]` on `Hypothesis`, written by `HypothesisPolicy.evaluate/2` from a module constant — never LLM-authored, never concatenated into `statement`.
- **D3 — Diagnostic/prescriptive rejection: fail-closed, whole-hypothesis reject.** Three layers (prompt + lexical forbidden-pattern scan on generated text + static source-scan test on the chain module). A match rejects the ENTIRE hypothesis — no partial redaction, no retry-with-stricter-prompt.
- **D4 — Output type: `Consultation.Source` (#226a), not `Rag.Citation` (#230).** Contract-canonical, server-derived. Reconciling with `Citation`'s existing renderer is #235's job; #229 does not deepen the duplication and is not blocked waiting for that reconciliation.

## Proposal question round — RESOLVED, see Locked decisions above

### Q1 — Intent classification: deterministic heuristic vs LLM classifier

| Option | Cost | Determinism | Accuracy |
|---|---|---|---|
| **Heuristic** (Spanish interrogative/relational markers) | Free | Fully testable, same input → same output | Misses paraphrases; false-positives on rhetorical questions |
| **LLM classifier** | +1 local call on *every* query | Non-deterministic; hard to assert in tests | Better on ambiguous phrasing |

**Recommendation: heuristic.** The issue's first acceptance criterion is literally "política *testeable*" — an LLM judgment call cannot satisfy it deterministically, and the classifier would run on the factual path too (the majority of queries). Misclassification is also cheap in both directions: a false negative yields the normal evidence-based synthesis (ADR-010's default, never wrong), and a false positive still passes the evidence gate, the forbidden-language gate, and the clinician's own review. **Product question for the user: is a missed interpretive request (no hypothesis offered when one would have helped) acceptable for the first slice?**

### Q2 — Disclaimer text and placement

**Proposed text (Spanish, verbatim constant):**
> `Hipótesis para revisar: no es un diagnóstico ni una recomendación terapéutica.`

**Recommended placement:** a required `disclaimer` field on `Hypothesis`, in `@enforce_keys`, written by `HypothesisPolicy.evaluate/2` from a module constant — never by the LLM, never concatenated into `statement`. Rationale: a `Hypothesis` cannot be constructed without it (the guarantee is structural, not editorial); ADR-010 demands the hypothesis be "diferenciada de la síntesis", which needs the disclaimer as a separately styleable element; and keeping `statement` clean avoids double-rendering when #231/#235 add their own visual label. **Question: approve this exact wording, or does the clinical team have preferred phrasing?**

### Q3 — Diagnostic/prescriptive rejection "by construction"

**Recommended mechanism — three layers:**
1. **Prompt** — explicit prohibitions in the chain's system prompt (necessary, insufficient alone; `PatternProposalChain` stops here and that is the gap).
2. **Structural post-generation scan** — `HypothesisPolicy` holds an exported, test-visible forbidden-pattern list (e.g. `diagnóstic*`, `trastorno de`, `recomend*`, `tratamiento`, `prescrib*`, `deberías/debería iniciar`) matched against `statement`; a hit returns `{:reject, :diagnostic_language}` / `{:reject, :prescriptive_language}` and **no hypothesis is emitted**. This is the layer that makes the criterion testable and makes `evaluate/2` the only constructor.
3. **Static source scan test** — precedent `AletheaJobs.AIProposalWorkerTest`: assert the chain module contains no call into any diagnosis-writing or proposal-advancing path.

Justification: rejecting the whole hypothesis (rather than redacting the offending phrase) is the only fail-closed option — a partially scrubbed clinical statement could read as an endorsed conclusion. **Question: confirm fail-closed rejection is preferred over retry-with-stricter-prompt.**

### Q4 — Output citation type: `Source`, not `Citation`

**Recommendation: emit `Consultation.Source` (#226a).** It is the contract-canonical, server-derived type; `Rag.Citation` (#230) is acknowledged duplication whose own moduledoc defers unification to #235. #229 must not deepen it. **Explicit flag: reconciling the two types is #235's job. #229 is NOT blocked on that reconciliation and must not wait for it** — the shape gap only becomes real when `CoreComponents.citation_list/1` has to render a `Source`, which happens in #235, not here. **Question: confirm #229 ships with `Source` even though no renderer consumes it yet.**

### Q5 — Base branch — RESOLVED

`main` now carries #223's fully-shipped chain (merged via PR #257 while this proposal was in flight). The `feat/grounded-clinical-chat-hypotheses` tracker (#225's integration branch) was rebased onto `main` (orchestrator commit `c68a857`), which also fixed three unrelated pre-existing compile breaks from #230's merge. #229 targets this tracker; #226a/#226b/`LLMConfig` are all present and confirmed via a clean `mix compile --warnings-as-errors` + a 1086/1088-passing full suite (the 2 failures are #230's own pre-existing bugs, untouched).
