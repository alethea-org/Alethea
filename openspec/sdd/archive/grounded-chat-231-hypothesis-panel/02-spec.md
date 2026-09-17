# Delta Spec — grounded-chat-231-hypothesis-panel

**Change:** grounded-chat-231-hypothesis-panel (issue #231) | **Store:** hybrid
**Baseline:** no prior `openspec/specs/grounded-chat-hypothesis-panel/spec.md` exists — requirements below are ADDED. This repo has no `openspec/specs/` source-of-truth tree; this delta is the spec of record at `openspec/sdd/grounded-chat-231-hypothesis-panel/spec.md`.

## Domain: grounded-chat-hypothesis-panel

### ADDED Requirements

#### Requirement: Structural absence when non-interpretive

`AletheaWeb.GroundedChat.HypothesisPanel.hypothesis_panel/1` MUST NOT emit a `<section>` element into the rendered HTML tree when `interpretive?: false`. Absence MUST be structural (tag omitted from the tree), not CSS-based (e.g. `display:none`, `hidden` attribute).

##### Scenario: Non-interpretive query renders nothing
- GIVEN `interpretive?: false` and any `claims` value
- WHEN `hypothesis_panel/1` is rendered via `render_component/2`
- THEN the output contains no `<section>` element
- AND the output is empty or whitespace-only

#### Requirement: Disclaimer precedes every claim

When `interpretive?: true`, the component MUST render a clinical disclaimer whose source position, in HEEx source order (= DOM order), precedes the statement of every claim in `claims`.

##### Scenario: Disclaimer appears before claim statements
- GIVEN `interpretive?: true` and `claims` containing one or more `Claim` structs
- WHEN `hypothesis_panel/1` is rendered
- THEN the disclaimer element's byte offset in the output is lower than the byte offset of every claim statement
- AND this holds regardless of `claims` order

#### Requirement: Disclaimer conveys ADR-010's substantive constraints

The disclaimer text MUST communicate both: (a) the hypothesis is reviewable by the professional, and (b) it is not a diagnosis and not a therapeutic recommendation. Exact wording is not fixed by this spec (PD4 — draft copy, pending clinical/legal sign-off).

##### Scenario: Disclaimer is present under interpretive rendering
- GIVEN `interpretive?: true`
- WHEN `hypothesis_panel/1` is rendered
- THEN a disclaimer element is present in the output
- AND its content references reviewability and excludes diagnosis/therapeutic-recommendation framing

#### Requirement: Citations delegate verbatim to `citation_list/1`

Each claim's citations MUST be rendered exclusively through `AletheaWeb.CoreComponents.citation_list/1`. The component MUST NOT define or emit panel-local citation markup (no local `<details>`, no local citation DOM structure).

##### Scenario: Claim citations render through the shared component
- GIVEN a claim with one or more `Citation.t()` entries
- WHEN `hypothesis_panel/1` is rendered
- THEN the claim's citations render with `citation_list/1`'s exact DOM (`<details>`, `citation-#{source_ref}` id, `citation__summary` class, `kind`)
- AND no citation markup outside that DOM shape is present for the claim

#### Requirement: Defensive empty-claims rendering

When `interpretive?: true` and `claims: []`, the component MUST still render the eyebrow, title, and disclaimer. It MUST NOT render any `<details>` element (no claim, no citation).

##### Scenario: Authorized interpretive read with no claims yet
- GIVEN `interpretive?: true` and `claims: []`
- WHEN `hypothesis_panel/1` is rendered
- THEN the output contains the eyebrow, the title, and the disclaimer
- AND the output contains no `<details>` element

#### Requirement: Multi-claim rendering is independent per claim

With two or more claims, the component MUST preserve `claims` list order in the rendered output and MUST render each claim's citation list independently of the others (one claim's citations MUST NOT leak into or merge with another's).

##### Scenario: Two claims render in order with independent citations
- GIVEN `claims` is `[claim_a, claim_b]`, each with its own distinct citations
- WHEN `hypothesis_panel/1` is rendered
- THEN `claim_a`'s statement appears before `claim_b`'s statement in the output
- AND `claim_a`'s `citation_list/1` output contains only `claim_a`'s citations
- AND `claim_b`'s `citation_list/1` output contains only `claim_b`'s citations

#### Requirement: Provisional-interface and draft-copy disclosure in moduledoc

The module's `@moduledoc` MUST state that `Claim.t()` and the `interpretive?` attribute are a provisional interface pending #229 (PD1), and that the disclaimer copy is an engineering draft pending clinical/legal review (PD4).

##### Scenario: Moduledoc discloses provisional status
- GIVEN the compiled `AletheaWeb.GroundedChat.HypothesisPanel` module
- WHEN its `@moduledoc` is inspected
- THEN it states `Claim.t()`/`interpretive?` are provisional pending #229
- AND it states the disclaimer copy is a draft pending clinical/legal sign-off

### Out of scope (non-requirements — explicit)

- Visual/DOM separation from a Síntesis panel in composition — proof deferred to #235.
- The C1 policy (#229): deciding `interpretive?`, building `claims`, any `:hypothesis` outcome variant.
- LiveView mounting, `handle_event`/`mount` wiring (#227).
- Changes to `citation_list/1` (e.g. an `expanded` passthrough) — stays collapsed-by-default per #230.
- Final disclaimer copy and styling/CSS beyond class hooks.
- Empty-state explanatory copy for `claims: []`.
