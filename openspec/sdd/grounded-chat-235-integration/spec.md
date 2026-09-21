# Spec — grounded-chat-235-integration

**Change:** grounded-chat-235-integration (issue #235) | **Store:** hybrid (mirrored to Engram `sdd/grounded-chat-235-integration/spec`)
**Baseline:** no `openspec/specs/` source-of-truth tree exists in this repo. This file is the spec of record for one NEW capability and two MODIFIED capabilities, combined per the proposal's Capabilities section.
**Confirmed decisions folded in:** Q1 (sequential in-flow, PD1 stands, no latency ceiling) — no separate requirement needed, it constrains delivery not observable behavior. Q2 (b) — citation unification with optional link slot, own slice #235c — see Requirement 10.

## Domain: grounded-chat-interpretive-integration (NEW)

### Purpose

End-to-end production behavior of the interpretive-hypothesis wiring: when a hypothesis reaches the professional, when it structurally cannot, its isolation from the synthesis outcome, the visible separation ADR-010 §2 demands, and citation navigation continuity.

### Requirements

#### Requirement: Interpretive Query Produces a Gated Hypothesis
`Consultation.Live.synthesize/2` MUST, after a successful synthesis, gate on `HypothesisPolicy.interpretive_intent?(query)` and, on `{:ok, %Hypothesis{}}` from `HypothesisPolicy.evaluate/2`, set `Answer.hypothesis` to that struct while `Answer.outcome` remains `:synthesis`.

##### Scenario: Interpretive query returns a hypothesis
- GIVEN an authorized professional issues an interpretive query with sufficient kept evidence
- WHEN `Consultation.Live.answer/4` resolves
- THEN the returned `%Answer{}` has `outcome: :synthesis` and `hypothesis: %Hypothesis{}`
- AND `synthesis` and `sources` are populated exactly as they would be without the hypothesis path

#### Requirement: Factual Query Never Invokes the Hypothesis Chain (PD4)
When `interpretive_intent?/1` returns `false`, `synthesize/2` MUST NOT call `hypothesis_chain().run/1` nor `HypothesisPolicy.evaluate/2`, and `Answer.hypothesis` MUST be `nil`.

##### Scenario: Factual query costs nothing
- GIVEN a factual query
- WHEN `answer/4` resolves
- THEN `hypothesis` is `nil`
- AND no call reaches `hypothesis_chain().run/1` (asserted via a Mox expectation of zero invocations)

#### Requirement: Hypothesis Path Failure Is Isolated From Synthesis (PD2)
Any hypothesis-path failure — chain raise, chain error tuple, `HypothesisPolicy` `{:reject, _}`, or blank/malformed prose — MUST be caught by a rescue boundary scoped to the hypothesis path alone, distinct from `synthesize/2`'s own, and MUST yield `hypothesis: nil` with `outcome: :synthesis` and unaffected `synthesis`/`sources`.

##### Scenario: Raising hypothesis chain doesn't break the answer
- GIVEN the hypothesis chain raises an exception
- WHEN `answer/4` resolves
- THEN it returns `{:ok, %Answer{outcome: :synthesis, hypothesis: nil}}` with `synthesis` and `sources` populated

##### Scenario: Rejected hypothesis doesn't break the answer
- GIVEN `HypothesisPolicy.evaluate/2` returns `{:reject, _}`
- WHEN `answer/4` resolves
- THEN `hypothesis` is `nil` and `outcome` is `:synthesis`

#### Requirement: Structural Presence/Absence in Rendered Output
Rendered HTML for an interpretive turn MUST contain a `<section class="review-hypothesis-panel">`; for a factual turn, or any turn with `hypothesis: nil`, it MUST NOT contain that tag at all — absence MUST be structural, not CSS-based.

##### Scenario: Interpretive turn renders the panel
- GIVEN an interpretive turn resolves with a non-nil hypothesis
- WHEN the page renders
- THEN the HTML contains `<section class="review-hypothesis-panel">`

##### Scenario: Factual turn's HTML contains no hypothesis panel tag
- GIVEN a factual turn resolves with `hypothesis: nil`
- WHEN the page renders
- THEN the HTML contains no `review-hypothesis-panel` tag anywhere, not even hidden

#### Requirement: End-to-End Proof of Panel Invariants Through the Real Flow
The invariants established in `grounded-chat-hypothesis-panel` (disclaimer precedes statement; citations render via `citation_list/1` as collapsed-by-default `<details>` expanding to verbatim server-derived excerpts) MUST hold when the panel is fed a real `Hypothesis` produced by `Consultation.Live.answer/4` through `ConsultationLive`'s live rendering, not only against hand-built fixtures.

##### Scenario: E2E interpretive turn preserves disclaimer order and expandable citations
- GIVEN a live-rendered interpretive turn with a policy-produced hypothesis carrying ≥1 source
- WHEN the DOM is inspected
- THEN the disclaimer's byte offset precedes the statement's
- AND each citation renders as a collapsed `<details>` that, when expanded, shows the exact server-derived excerpt text

#### Requirement: Cross-Patient / Cross-Tenant Isolation
The hypothesis path MUST respect the same authorization and patient-scoping already enforced before `synthesize/2` runs. An interpretive query MUST NOT surface a hypothesis or citation referencing another patient's or tenant's evidence.

##### Scenario: Cross-patient adversarial query yields no hypothesis leak
- GIVEN an interpretive query is issued against a patient with no matching retained evidence, while another patient holds relevant evidence
- WHEN `answer/4` resolves
- THEN no hypothesis is produced, and no citation references the other patient's evidence

##### Scenario: Unauthorized access yields no hypothesis or foreign evidence
- GIVEN a professional lacking authorization for the target patient issues an interpretive query
- WHEN `answer/4` resolves
- THEN authorization fails before `synthesize/2` runs, and no hypothesis is ever computed

#### Requirement: No Clinical-State Mutation
Producing a hypothesis — success, rejection, or failure — MUST NOT write to `Repo`, MUST NOT enqueue any Oban job, and chunks/evidence involved MUST remain byte-identical before and after.

##### Scenario: Hypothesis turn leaves clinical state untouched
- GIVEN an interpretive turn that successfully produces a hypothesis
- WHEN `answer/4` resolves
- THEN no `Repo` insert/update/delete occurred, zero new Oban jobs were enqueued, and every involved chunk's stored bytes are unchanged

#### Requirement: No Hypothesis Without Server-Derived Evidence, Proven End-to-End
An interpretive turn with a diagnostic/prescriptive candidate statement MUST NOT surface a hypothesis to the professional, proven through the real flow, not only C1's unit tests.

The zero-evidence half of this guarantee (`HypothesisPolicy.evaluate/2`'s `{:reject, :no_evidence}` branch) is enforced by construction, not by a new E2E test: `synthesize/2` only ever runs with a non-empty `kept` list, because an empty `kept` already yields `outcome: :no_evidence` earlier in the pipeline (pre-existing, out of scope here) before `synthesize/2` — and therefore before any hypothesis attempt — is ever reached. `results == []` is structurally unreachable through `answer/4` and remains covered exclusively by C1's existing unit suite (`hypothesis_policy_test.exs`).

##### Scenario: Diagnostic/prescriptive candidate is rejected end-to-end
- GIVEN the hypothesis chain's raw prose contains a diagnostic or prescriptive marker
- WHEN `answer/4` resolves and the page renders
- THEN `hypothesis` is `nil` and no hypothesis panel renders

#### Requirement: Interpretive Intent Classification Stays Domain-Owned (PD3)
`AletheaWeb.ConsultationLive` MUST NOT call `HypothesisPolicy.interpretive_intent?/1` or `HypothesisPolicy.evaluate/2` directly; it MUST only read `@last_answer.hypothesis` to decide what to render. Verified via an AST-aware scan — not a textual/`grep`-style match — so that a moduledoc or comment merely mentioning `HypothesisPolicy` in prose is never mistaken for a call, per the same false-positive class the Sole Constructor Gate fix (PR #273) already corrected.

##### Scenario: Web layer contains no direct classification/evaluation call
- GIVEN an AST-parsed scan of `lib/alethea_web/live/consultation_live.ex` for actual `HypothesisPolicy.interpretive_intent?/1` or `HypothesisPolicy.evaluate/2` call expressions (not string/doc matches)
- WHEN the scan runs
- THEN none exist

#### Requirement: Citation Rendering Unification Preserves Navigation (Q2/b)
`AletheaWeb.CoreComponents.citation/1` MUST gain an optional link slot. `ConsultationLive`'s source list MUST render through `citation/1`/`citation_list/1` instead of hand-rolled markup, and the "Ver conducta objetivo" navigation to the target-behavior review page MUST still render whenever a source carries a non-nil `target_behavior_id`.

##### Scenario: Migrated source list still links to "Ver conducta objetivo"
- GIVEN a source with a non-nil `target_behavior_id`, rendered via the unified citation component
- WHEN the DOM is inspected
- THEN a "Ver conducta objetivo" link to the target-behavior review page is present

##### Scenario: Source without a target behavior renders no dangling link
- GIVEN a source with `target_behavior_id: nil`
- WHEN rendered via the unified citation component
- THEN no navigation link is present, and no error occurs

(Delivery constraint, non-normative: this requirement ships as its own slice, #235c, never in the same PR as the clinical wiring in Requirements 1–9.)

## Domain: clinical-consultation-hypothesis (MODIFIED — #229)

### MODIFIED Requirements

#### Requirement: Bounded Wiring Into the Real Consultation Flow
The real consultation flow (`Consultation.Live.synthesize/2`) MUST call `HypothesisPolicy.interpretive_intent?/1` and, when true, `HypothesisPolicy.evaluate/2` through exactly one call site (`maybe_hypothesis/3`) that is additive and fail-silent (PD1/PD2 — see `grounded-chat-interpretive-integration`, Requirements 1–3). This wiring MUST NOT add a 5th `Answer.outcome` value and MUST NOT modify `ClinicalConsultationChain`'s prompt/behavior. The web layer (`AletheaWeb.ConsultationLive`) MUST NOT call `interpretive_intent?/1` or `evaluate/2` directly.
(Previously: this slice forbade ANY call into `Consultation.Live.answer/4` or `ConsultationLive`. #235 lifts that prohibition for exactly one domain-owned call site while keeping the web layer excluded.)

##### Scenario: Answer.outcome vocabulary is unchanged
- GIVEN `Answer.outcome/0` after this change
- WHEN compared to before
- THEN it remains exactly `:synthesis | :no_evidence | :stale | :provider_failure`

##### Scenario: ClinicalConsultationChain is byte-unchanged
- GIVEN `clinical_consultation_chain.ex` and its prompt regression test
- WHEN diffed against the pre-change version
- THEN there is no difference

##### Scenario: Exactly one domain call site invokes the hypothesis policy
- GIVEN an AST-parsed scan of the codebase (not textual/`grep`-style — a moduledoc or comment mentioning `HypothesisPolicy` in prose MUST NOT count) for actual call expressions of `HypothesisPolicy.interpretive_intent?/1` and `HypothesisPolicy.evaluate/2`
- WHEN the scan runs
- THEN the only call site is `Consultation.Live.synthesize/2`'s `maybe_hypothesis/3`
- AND `AletheaWeb.ConsultationLive` contains no such call

## Domain: grounded-chat-hypothesis-panel (MODIFIED — #231)

### ADDED Requirements

#### Requirement: Structural Separation From Síntesis in Composition (closes #231 PD2)
When mounted inside the real consultation flow, `hypothesis_panel/1`'s `<section class="review-hypothesis-panel">` MUST render as a sibling DOM element to `<section id="consultation-synthesis">` — never nested inside it, never replacing it.
(Previously: out of scope, explicitly deferred — #231's spec listed "Visual/DOM separation from a Síntesis panel in composition — proof deferred to #235.")

##### Scenario: Hypothesis panel is a sibling of the synthesis panel
- GIVEN an interpretive turn with a non-nil hypothesis
- WHEN `ConsultationLive` renders
- THEN `#consultation-synthesis` and the hypothesis panel's `<section>` exist as sibling elements under the same parent
- AND neither section is nested inside the other
