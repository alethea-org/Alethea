# Proposal — grounded-chat-235-integration

**Source issue:** alethea-org/Alethea#235 — "Integrar hipótesis interpretativas en la consulta real"
**Artifact store:** hybrid (mirrored to Engram `sdd/grounded-chat-235-integration/proposal`)
**Strict TDD:** active — test runner `mix test` / `mix precommit`.
**Depends on exploration:** Engram `sdd/grounded-chat-235-integration/explore`.
**Canonical reference:** ADR-010 §2 (`openspec/adr/010-chat-consulta-clinica-fundamentada.md`).
**Blockers:** all closed — #226, #229, #230, #231 (PR #265), #234.

## Intent

**Problem.** Every piece of the interpretive-hypothesis feature exists and is unit-tested, and **none of it runs**. `HypothesisPolicy.evaluate/2` (C1, #229) is never called from `Consultation.Live`; `ClinicalHypothesisChain` is never invoked; `Answer.hypothesis` is structurally always `nil` in production; `ConsultationLive` does not reference `HypothesisPanel` (C3, #231) at all. Four merged issues deliver zero user-visible behavior. `Answer`'s own moduledoc says it plainly: *"no production code path populates it until #235 wires `HypothesisPolicy.evaluate/2` into this flow."*

**Why now.** #231 merged today; every blocker is closed. This is the last wire, and it is also the only place where ADR-010's *"separación visible entre Síntesis e Hipótesis"* can be proven — #231 explicitly deferred that proof here (its PD2).

**Success.** A psychologist asking an interpretive question about a patient's record sees a *Síntesis basada en evidencia* panel and, structurally separate from it, a *Hipótesis para revisar* panel with its clinical disclaimer and expandable server-derived citations. Asking a factual question, they see no hypothesis panel in the DOM at all. Nothing is persisted; no clinical row is mutated.

## Acceptance criteria (verbatim from #235)

- Hipótesis visible solo en consultas interpretativas; ausente en fácticas.
- Citas server-derived expandibles; separación visible con disclaimer.
- Tests cubren activaciones correctas, prohibiciones (diagnóstico/prescripción/citas inventadas/sin evidencia) y aislamiento por paciente.
- Sin mutación de fuentes; sin persistencia.

## Product decisions

| # | Decision |
|---|---|
| **PD1** | **Sequential in-flow wiring** inside `Consultation.Live.synthesize/2` — the hypothesis is produced in the same `answer/4` call, returned in the same `{:ok, %Answer{}}` tuple, rendered in the same `start_async(:answer, …)` resolution. The A1 behaviour (`answer/4`, `open/2`) gains no callback. See Approach. |
| **PD2** | **The hypothesis path is strictly additive and fail-silent.** Its own `try/rescue` boundary, distinct from `synthesize/2`'s. Any failure — chain error, exception, `{:reject, _}`, blank prose — yields `hypothesis: nil` and a normal `outcome: :synthesis`. A hypothesis defect must never downgrade an answer the professional would otherwise have received. |
| **PD3** | **D1 stays owned by C1 only.** `interpretive_intent?/1` is called from exactly one place (the domain flow). The web layer never classifies intent; it renders `@last_answer.hypothesis` or nothing. |
| **PD4** | **Zero cost on the factual path.** The intent gate runs before the chain, so factual queries make no second LLM call. |
| **PD5** | **Citation unification is in scope but ships as its own slice, and must not regress navigation.** See Q2 — this is the one decision needing user confirmation before `sdd-tasks`. |

## Scope

### In scope

- `Consultation.Live.synthesize/2` — after a successful synthesis: gate on `HypothesisPolicy.interpretive_intent?(query)`, run the hypothesis chain over the **already-sanitized** `excerpts` (no second retrieval, no second sanitize), pass its prose plus the same `kept` results to `HypothesisPolicy.evaluate/2`, set `Answer.hypothesis`.
- A configurable `hypothesis_chain()` accessor mirroring the existing `chain()` pattern (`Application.get_env(:alethea, :clinical_hypothesis_chain, ClinicalHypothesisChain)`) for Mox injection in tests.
- `ConsultationLive.render/1` — mount `HypothesisPanel.hypothesis_panel/1` as a **sibling section** of `consultation-synthesis`, passing `@last_answer.hypothesis` and a per-turn `id`.
- `Consultation.Fake` — a hypothesis-bearing variant so LiveView tests can drive a real interpretive turn (canned `Hypothesis` built through `HypothesisPolicy.evaluate/2`, never a hand-rolled struct).
- **Domain tests** extending `live_test.exs`'s existing describe blocks: interpretive query populates `hypothesis`; factual query leaves it `nil`; adversarial cross-patient / cross-tenant query yields no hypothesis leak; hypothesis generation mutates zero clinical state (byte-identical chunks, no new Oban jobs); hypothesis-chain failure still returns `outcome: :synthesis`.
- **End-to-end LiveView tests** in `consultation_live_test.exs`: panel present for interpretive, `<section class="review-hypothesis-panel">` absent from the HTML for factual, disclaimer precedes statement, citations render as collapsed `<details>` and expand, the two panels are structurally separate elements.
- Moduledoc updates closing the `Answer` / `HypothesisPanel` / `Citation` hand-off notes.

### Out of scope

- **Any change to C1's policy** (#229): the marker lists, gate precedence, disclaimer text, and forbidden-language regexes ship untouched. #235 calls them; it does not tune them.
- **Any change to `citation/1` / `citation_list/1` semantics** beyond what Q2 resolves.
- **Follow-up interpretive intent** (#233): a bare continuation (*"¿y eso por qué?"*) may not classify as interpretive because `resolve_query/2` is intentionally minimal. Documented known limitation, not fixed here.
- **Persistence of hypotheses**, audit logging of interpretive turns, hypothesis feedback/accept-reject UI.
- **LLM-based intent classification**, a second retrieval pass, or any hypothesis-specific prompt tuning.
- Styling/CSS beyond the class hooks #231 already defined.

## Capabilities

> No `openspec/specs/` tree in this repo; the delta lands at `openspec/sdd/grounded-chat-235-integration/spec.md` per repo convention.

### New capabilities

- `grounded-chat-interpretive-integration`: the end-to-end production behavior — when a hypothesis reaches the professional, when it structurally cannot, its isolation from the synthesis outcome, and the visible separation ADR-010 §2 demands.

### Modified capabilities

- `clinical-consultation-hypothesis` (#229): the requirement changes from *"the policy can produce a hypothesis"* to *"the real consultation flow produces one, gated, additively, and fail-silently."*
- `grounded-chat-hypothesis-panel` (#231): its deferred criterion — visible separation from *Síntesis* — becomes provable and required here (closes PD2 of #231).

## Approach — sequential in-flow (chosen)

```
Consultation.Live.answer/4
  authz → freshness → retrieval → threshold → tombstone
    └─ synthesize(kept, query)
         sources  = Source.from_results(kept)
         excerpts = Enum.map(kept, &Sanitizer.sanitize/1)
         chain().run(...)  ──► synthesis prose        (unchanged path)
              │
              └─ maybe_hypothesis(query, excerpts, kept)   ← NEW, own rescue
                   interpretive_intent?(query) == false ──► nil   (no LLM call)
                   true ─► hypothesis_chain().run(%{question:, excerpts:})
                             └─ HypothesisPolicy.evaluate(prose, kept)
                                  {:ok, %Hypothesis{}} ─► hypothesis
                                  {:reject, _} | error  ─► nil
         %Answer{outcome: :synthesis, synthesis:, sources:, hypothesis:}

ConsultationLive.render/1
  <section id="consultation-synthesis">   … Síntesis
  <section id="consultation-sources">     … Fuentes
  <.hypothesis_panel id={"consultation-hypothesis-#{turn}"}
                     hypothesis={@last_answer.hypothesis} />   ← absent when nil
```

**Why this approach.** It is literally the wiring three merged moduledocs already specify (`Answer`, `HypothesisPanel`, `Citation` all name #235 as *the* integration point, singular flow). It keeps the A1 behaviour byte-stable, adds zero LiveView async states, reuses the already-sanitized excerpts so PII never crosses a boundary twice, and leaves D1 classification in C1's sole ownership. Effort: Low-Medium.

**Rejected: deferred/parallel async.** `ConsultationLive` would classify intent itself and fire a second `start_async(:hypothesis, …)` against a new public `Consultation.hypothesis/4`, patching the panel in later. Better perceived latency for the primary answer — and that is its only advantage. Against it: it widens the A1 contract with a new callback just shipped and tested by #226/#234; it duplicates the D1 gate across web and domain, breaking C1's "sole owner of interpretive intent" invariant; it must either re-run retrieval (wasteful, and races the freshness re-check) or stash `kept`/`excerpts` in transient assigns; and it doubles the timing-edge test surface (e.g. "Nueva conversación" clicked mid-flight). Effort: Medium-High for a latency win on a non-realtime clinical reading surface.

## Affected areas

| Area | Path | Impact |
|---|---|---|
| Domain flow | `lib/alethea/clinical_record/rag/consultation/live.ex` | **Modified** — `synthesize/2` + new `maybe_hypothesis/3` + `hypothesis_chain/0` |
| Test fixture | `lib/alethea/clinical_record/rag/consultation/fake.ex` | **Modified** — hypothesis-bearing variant |
| Web render | `lib/alethea_web/live/consultation_live.ex` | **Modified** — mount `hypothesis_panel/1`; sources markup per Q2 |
| Panel | `lib/alethea_web/live/grounded_chat/hypothesis_panel.ex` | Unchanged (or `source_to_citation/1` promoted — Q2) |
| Policy / chain | `hypothesis_policy.ex`, `clinical_hypothesis_chain.ex` | **Unchanged** — consumed verbatim |
| Citations | `core_components.ex`, `citation.ex` | Unchanged unless Q2 resolves to migrate |
| Tests | `test/alethea/clinical_record/rag/consultation/live_test.exs` | **Modified** — extend existing isolation/no-mutation describes |
| Tests | `test/alethea_web/live/consultation_live_test.exs` | **Modified** — new e2e hypothesis describes |

## Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| **A hypothesis failure degrades the synthesis answer** to `:provider_failure`, making a merged, working feature look broken. | High if unguarded | PD2: separate `try/rescue` around `maybe_hypothesis/3` only, plus an explicit test asserting `outcome: :synthesis` survives a raising hypothesis chain. |
| **`source_to_citation/1` raises on empty excerpt** (`hypothesis_panel.ex:121`). In isolation tests that never happens; in production it would crash the LiveView render *after* a valid synthesis. | Medium | Validate/reject empty-excerpt sources in the domain layer (`maybe_hypothesis/3`) so the panel never receives one; keep the raise as defense in depth. Add a regression test. |
| **Naive citation migration silently drops "Ver conducta objetivo"** — `citation/1` renders no link, the current hand-rolled markup does. That is a navigability regression against ADR-003. | Medium | **Q2 blocks this decision.** Default recommendation: separate slice, link preserved, never a straight swap. |
| **Second LLM call doubles interpretive-turn latency.** | Medium | Accepted (PD1). Factual path unaffected (PD4). Local-only chain (D2/AD5) keeps the cost in-box. Revisit with real timings, not speculation. |
| **Follow-up interpretive queries misclassify** (#233 overlap). | Medium | Out of scope, documented as a known limitation on the issue. Failure mode is benign: no hypothesis offered. |
| **Total diff exceeds the 400-line review budget.** | Medium-High | Chained slices: **#235a** domain wiring + Fake + domain tests · **#235b** panel mount + e2e tests · **#235c** citation unification (Q2). `sdd-tasks` owns the final forecast. |

## Rollback plan

Per slice, revert the commit. No migration, no schema, no config default change, no persisted data — hypotheses are computed per turn and die with the process (ADR-010 §6). Reverting #235b restores the current render (synthesis + sources, no panel); reverting #235a restores `hypothesis: nil` in every `Answer`, which is exactly today's production behavior. #229/#230/#231 artifacts are consumed verbatim and survive any revert intact.

## Dependencies

- **Blocking:** none. #226, #229, #230, #231 (PR #265), #234 all closed.
- **Consumes:** `HypothesisPolicy`, `ClinicalHypothesisChain`, `Hypothesis`, `Source`, `HypothesisPanel`, `citation_list/1`.
- **Overlaps (not a prerequisite):** #233 (follow-up resolution).
- **Release gate (non-code):** clinical/legal sign-off on the disclaimer copy, inherited open from #231 PD4 — this change is what puts that copy in front of real users.

## Success criteria

- [ ] An interpretive query on the real flow returns `%Answer{outcome: :synthesis, hypothesis: %Hypothesis{}}`.
- [ ] A factual query returns `hypothesis: nil` and makes **no** hypothesis-chain call.
- [ ] A raising/erroring/rejecting hypothesis path still returns `outcome: :synthesis` with the full synthesis and sources.
- [ ] The rendered page contains `review-hypothesis-panel` for interpretive turns and **does not contain the tag at all** for factual turns.
- [ ] Both panels exist as separate sibling elements; the disclaimer precedes the statement; citations render as collapsed-by-default `<details>` that expand to verbatim server-derived excerpts.
- [ ] Adversarial cross-patient and cross-tenant queries produce no hypothesis and no foreign evidence.
- [ ] A hypothesis turn leaves chunks byte-identical and enqueues zero Oban jobs; nothing is written to `Repo`.
- [ ] No hypothesis is emitted without ≥1 server-derived source, and diagnostic/prescriptive prose is rejected end-to-end (not just in C1's unit tests).
- [ ] `mix precommit` passes.

## Proposal question round

Interactive asking was unavailable in this phase. Two product questions should be confirmed before `sdd-tasks`; neither blocks `sdd-spec` or `sdd-design`.

**Q1 — Latency vs. immediacy on interpretive turns.** PD1 makes the professional wait for both LLM calls before seeing anything. Assumption taken: acceptable, because a clinical reading surface is not realtime and a partially-rendered answer that later sprouts an interpretive panel is itself a clinical-attention risk. Confirm, or state a latency ceiling that would force the parallel design.

**Q2 — Citation unification vs. navigability (the real open decision).** `citation.ex`'s moduledoc assigns #235 the job of making `citation_list/1` the single source renderer. But `citation/1` renders no link, while `ConsultationLive`'s current markup renders **"Ver conducta objetivo"** (`target_behavior_id` → review page). A straight migration silently removes that navigation path. Three options:

| Option | Consequence |
|---|---|
| **(a) Migrate as-is** | Single renderer achieved; loses the target-behavior link. |
| **(b) Migrate + extend `citation/1` with an optional link slot** *(recommended)* | Single renderer, navigation preserved; touches #230's shipped component and its DOM assertions. |
| **(c) Defer unification to a follow-up issue** | #235 stays tightly scoped to the acceptance criteria; the documented divergence persists one more cycle. |

Assumption taken: **(b), delivered as slice #235c**, so a renderer change never rides in the same PR as the clinical wiring. Confirm or redirect.

## Next

Ready for `sdd-spec` and `sdd-design` (may run in parallel).
