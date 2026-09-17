# Proposal — grounded-chat-231-hypothesis-panel

**Source issue:** alethea-org/Alethea#231 — "Construir el panel de hipótesis para revisar" (area:dashboard, priority:p1)
**Artifact store:** hybrid (mirrored to Engram `sdd/grounded-chat-231-hypothesis-panel/proposal`)
**Strict TDD:** active — test runner `mix test`.
**Depends on exploration:** `openspec/sdd/grounded-chat-231-hypothesis-panel/exploration.md` / Engram `sdd/grounded-chat-231-hypothesis-panel/explore`.
**Canonical reference:** ADR-010 §2 (`openspec/adr/010-chat-consulta-clinica-fundamentada.md`).
**Fixed inputs (settled by the product owner, not re-decided here):** PD1–PD4 below.

## Intent

**Problem.** ADR-010 §2 allows an interpretive answer to carry a *Hipótesis para revisar* alongside the evidence-based *Síntesis*, but only under hard constraints: it must be visibly differentiated, mandatorily cited, reviewable by the psychologist, and it must never read as a diagnosis or a therapeutic recommendation. No UI surface enforces any of that today. Without a dedicated component, whoever wires the C-chain first will improvise the disclaimer, the DOM separation, and the citation markup — exactly the divergence `Alethea.ClinicalRecord.Rag.Citation` was documented to prevent.

**Why now.** #230 (C2, the server-derived citation renderer) is on this branch and gives the panel its citation primitive. C1 (#229, the policy that decides `interpretive?` and builds claims) and the integration point (#235) are still open. Building the render surface now unblocks both without either becoming a prerequisite.

**Success.** A psychologist, when and only when C1 authorizes interpretive reading, sees a distinct hypothesis panel whose first content is a clinical disclaimer, whose every claim carries the same expandable citation widget the Síntesis uses, and which is structurally absent from the DOM otherwise.

## Product decisions (settled — not open questions)

| # | Decision |
|---|---|
| **PD1** | `Claim.t()` (`id`, `statement`, `citations: [Citation.t()]`) and the `interpretive?: boolean()` attr are an explicit **PROVISIONAL interface**, authored by this change, not a contract negotiated with #229. Open to renegotiation once #229 actually lands. Do not present it as closed. |
| **PD2** | #231 delivers **only the standalone component**, proven in isolation via `render_component/2`. No integration stub, demo page, or two-panel composition. The "visible separation from Síntesis" criterion is proven at composition time by **#235**, per the hand-off already documented in `Citation`'s moduledoc. |
| **PD3** | `interpretive?: true, claims: []` is **supported defensively**: the panel renders normally (eyebrow + title + disclaimer, empty claim list). This guards against a future C1 defect without breaking the UI. It is explicitly **not** documented as unreachable. |
| **PD4** | The disclaimer wording ("Esta hipótesis es revisable por el profesional. No es un diagnóstico ni una recomendación terapéutica.") is an **engineering draft**. It satisfies ADR-010's substantive requirement (not a diagnosis, not a therapeutic recommendation, reviewable) but ADR-010 quotes no copy. It is **pending clinical/legal review before this ships to real users** — a later wording change is not an ADR violation. |

## Scope

### In scope

- `AletheaWeb.GroundedChat.HypothesisPanel` — stateless function component `hypothesis_panel/1` plus the nested `Claim` struct (`@enforce_keys` on all three fields).
- Structural absence for non-interpretive queries: `:if={@interpretive?}` on the outer `<section>`, so the tag is omitted from the HTML tree entirely — not CSS-hidden.
- Disclaimer rendered **before** any claim in source order (HEEx source order = DOM order).
- Citation rendering delegated verbatim to `AletheaWeb.CoreComponents.citation_list/1` (#230). No panel-local citation markup, per the "no divergent rendering" hand-off.
- Non-interference with future composition: distinct `class="review-hypothesis-panel"`, caller-supplied `id`, `aria-labelledby`, no shared DOM-ancestor assumptions.
- **Test gap closure:** add a multi-claim case (2+ claims) covering claim ordering and independent per-claim citation rendering — the current 4 tests only ever pass a single-claim list.
- Moduledoc statement that `Claim.t()`/`interpretive?` are provisional pending #229 (PD1) and that the disclaimer copy is a draft pending clinical/legal sign-off (PD4).

### Out of scope (explicit non-goals)

- **Any composition of Hipótesis + Síntesis**, and the visual-separation proof that requires it — belongs to #235 (PD2).
- **The C1 policy itself** (#229): deciding `interpretive?`, building claims, and any `:hypothesis` outcome variant on `Consultation.Answer`.
- **Mounting into a LiveView** (#227's `ConsultationLive` does not exist on this branch or on `main`). No `handle_event`/`mount` wiring, no LiveView-level test.
- **Changing `citation_list/1`** — including adding an `expanded` passthrough. Every citation stays collapsed-by-default, which is #230's contract, not a panel defect.
- **Final disclaimer copy** and any styling/CSS beyond the class hooks (PD4).
- Empty-state copy ("no hypotheses to review") — deferred until #229's real policy shape is known (PD3 only requires it not to break).

## Capabilities

> This repository has no `openspec/specs/` source-of-truth tree; the delta lands at `openspec/sdd/grounded-chat-231-hypothesis-panel/spec.md` per repo convention.

### New capabilities

- `grounded-chat-hypothesis-panel`: conditional rendering of the interpretive hypothesis surface, disclaimer precedence, per-claim citation delegation, and defensive empty-claims behavior.

### Modified capabilities

- None. `citation_list/1` is consumed verbatim; no existing requirement changes.

## Approach

```
caller (#227/#235, later) ──► hypothesis_panel/1
                                   │
              interpretive? == false ──► NOTHING rendered (tag omitted, not hidden)
                                   │ true
                                   ▼
        <section id={@id} class="review-hypothesis-panel">
          eyebrow · "C1 autorizado · lectura interpretativa"
          <h2 id={@id}-title>  "Hipótesis para revisar"
          <div>  CLINICAL DISCLAIMER  (always first content — PD4 draft copy)
          <ul>
            <li :for={claim <- @claims} id={claim.id}>
              statement
              <.citation_list citations={claim.citations} />   ← #230, verbatim
            </li>
          </ul>      claims == [] ⇒ header + disclaimer still render (PD3)
        </section>
```

**Why a standalone stateless component.** It is independently shippable with zero dependency on #227 or #229, it keeps ADR-010's invariants in one testable place instead of scattered across a LiveView, and `render_component/2` proves all four isolation-testable acceptance criteria without a live socket.

**Rejected: wait for #229 and build the panel inside `ConsultationLive`.** It would block a p1 UI surface on an unstarted issue, and it would put the disclaimer/absence invariants inside a stateful LiveView where they are harder to prove and easier to regress.

## Affected areas

| Area | Path | Impact |
|---|---|---|
| Component | `lib/alethea_web/live/grounded_chat/hypothesis_panel.ex` | New (draft exists on branch) — finalize moduledoc provisional/draft notes |
| Tests | `test/alethea_web/live/grounded_chat/hypothesis_panel_test.exs` | Modified — add the multi-claim case |
| Citations | `lib/alethea_web/components/core_components.ex` | **Unchanged** — consumed verbatim |
| Citations | `lib/alethea/clinical_record/rag/citation.ex` | **Unchanged** — only `from_retrieval_result/1` is used, in tests |

## Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| **#229 returns a different shape** (e.g. `{:interpretive, claims} \| :not_interpretive`, or its own claim type) than PD1's provisional `Claim.t()`/`interpretive?` boolean. | **High** | Accepted by design (PD1). The adapter cost is confined to one function component with three attrs. **#235 must surface any mismatch as an explicit decision point, not silently adapt around it.** |
| **Disclaimer copy ships unreviewed** to real users. | Medium | PD4 flags it as an engineering draft in the proposal, the moduledoc, and the issue. Clinical/legal sign-off is a release gate, not a code gate. |
| **"Visible separation" (criterion 1) is not provable here** — it is a two-panel layout property. | Medium | PD2 moves the proof to #235. #231 proves only non-interference (distinct class/id, no shared ancestor logic). Record this explicitly on #231 so it is not read as an unmet criterion. |
| **Component ships with no consumer**, drifts, or is duplicated by whoever wires the C-chain. | Low | The `Citation` moduledoc hand-off already names #231 as the C3 renderer and #235 as the integration point. |
| **Divergent citation rendering** creeps in later. | Low | The multi-claim test asserts `citation_list/1`'s exact DOM (`<details>`, `citation-#{source_ref}`, `citation__summary`, `kind`), so local markup breaks the suite. |

## Rollback plan

Fully self-contained: revert the commit. Two files, no migration, no schema, no config, no runtime behavior change on any existing surface. The component has **no consumer on this branch or on `main`**, so removing it cannot break a caller. `citation_list/1` and `Citation` are untouched and survive the revert.

## Dependencies

- **Blocking:** none.
- **Consumes:** #230 / PR #248 (`citation/1`, `citation_list/1`, `Citation`) — already cherry-picked onto this branch.
- **Consumed by (later, not prerequisites):** #229 (C1 policy), #227 (`ConsultationLive`), #235 (integration + visible-separation proof).
- **Release gate (non-code):** clinical/legal approval of the disclaimer copy (PD4).

## Success criteria

- [ ] `interpretive?: false` renders an empty string — the `<section>` tag is absent from the HTML tree, not CSS-hidden.
- [ ] With claims present, the disclaimer's byte offset precedes the first claim statement's offset.
- [ ] The disclaimer conveys both ADR-010 substantive constraints: not a diagnosis, not a therapeutic recommendation.
- [ ] Every claim's citations render through `citation_list/1` with its exact DOM — no panel-local citation markup.
- [ ] **A 2+ claim case passes**, asserting claim order and that each claim renders its own independent citation list.
- [ ] `interpretive?: true, claims: []` renders header + disclaimer and no `<details>` (PD3).
- [ ] The moduledoc states that `Claim.t()`/`interpretive?` are provisional pending #229 and the disclaimer copy is a draft pending clinical/legal review.
- [ ] `mix precommit` passes.

## Open questions

Only one, and it does not block `sdd-spec`/`sdd-design`: **PD1's provisional interface**, to be reconciled against #229's real return shape when that policy lands. PD2, PD3, and PD4 are settled.

## Next

Ready for `sdd-spec` and `sdd-design` (may run in parallel).
