# Design — grounded-chat-231-hypothesis-panel

**Source issue:** alethea-org/Alethea#231 (C3) | **Store:** hybrid | **Strict TDD:** active (`mix test`)
**Inputs:** `proposal.md` (PD1–PD4 settled), `spec.md`, `exploration.md`, ADR-010 §2
**Baseline:** a draft implementation already exists on `feat/grounded-chat-231-hypothesis-panel`. This design refines that draft; it does not re-plan it from zero.

## 1. Architecture approach

No new layer. One stateless `Phoenix.Component` in the web adapter (`lib/alethea_web/live/grounded_chat/`), sibling to `FollowupState` (#228). The domain core is untouched: the panel never builds, validates or filters a `Citation` — `Alethea.ClinicalRecord.Rag.Citation` and `AletheaWeb.CoreComponents.citation_list/1` are consumed verbatim.

ADR-010's invariants are enforced by **structure, not by convention**: `:if` on the outer tag (absence), HEEx source order (disclaimer precedence), and delegation to an imported component (no divergent citation markup). Each is asserted by a test that fails if the structure is edited away.

## 2. Component map & data flow

```
#229 C1 policy (later) ──► interpretive? :: boolean
                           claims :: [Claim.t()]
#230 Citation ─────────────► claim.citations
                                  │
   #227 ConsultationLive / #235 composition (later) — the only callers
                                  │
                                  ▼
                       hypothesis_panel/1   ← this change, standalone
                                  │
        interpretive? false ──► "" (tag never emitted; NOT css-hidden)
        interpretive? true  ──► <section id={@id} class="review-hypothesis-panel"
                                         aria-labelledby={@id}-title>
                                  eyebrow · <h2 id={@id}-title>
                                  <div id={@id}-disclaimer>   ← PD4 draft copy, first content
                                  <ul><li :for id={claim.id}>
                                        statement
                                        <.citation_list/>     ← #230, verbatim
                                claims == [] ⇒ header + disclaimer only (PD3)
```

## 3. Disclosure anchors for PD1 / PD4 (design question 1)

A single moduledoc paragraph is insufficient: the three future readers open three different places. Disclosure is therefore **triplicated at the point of use**.

| Anchor | Discloses | Reader it catches |
|---|---|---|
| `HypothesisPanel` `@moduledoc` → new `## Estado provisional` section | PD1 + PD4, with issue numbers | Anyone reading the component |
| `Claim` `@moduledoc` (nested) | PD1 only — "shape authored here, not negotiated with #229; renegotiable when #229 lands" | The #229 implementer, who opens `Claim` and never scrolls up |
| `<%!-- PD4: borrador de ingeniería … --%>` immediately above the disclaimer `<div>` in the `~H` template | PD4 only | Whoever edits the copy after clinical/legal review |

The `@moduledoc` also gains an explicit `## Hand-off` section mirroring `FollowupState`'s, naming **#229** (supplies `interpretive?` + claims), **#227** (mounts it), and **#235** (composes it with Síntesis, owns the visible-separation proof per PD2, and **must surface a #229 shape mismatch as an explicit decision point rather than silently adapting** — the proposal's top risk lands here, where #235's implementer will read it). Answers design question 4: yes, cross-reference #227/#235 even though neither exists on this branch.

Moduledocs stay in Spanish, matching `FollowupState` and `Citation`. This artifact is English per the SDD language contract.

## 4. Interfaces / contracts (design question 3)

Attrs are confirmed unchanged from the draft:

| Attr | Type | Required | Note |
|---|---|---|---|
| `id` | `:string` | yes | Per conversation turn; seeds `-title` and `-disclaimer` ids |
| `interpretive?` | `:boolean` | yes | PD1 provisional; `required` so no caller defaults into rendering |
| `claims` | `:list` | no, `[]` | PD3 defensive default |

**Add `Claim.build/3`** as the preferred constructor (naming matches the sibling nested struct `FollowupState.Turn.build/3`, not `new/`, which that module reserves for the top-level state). `attr :claims, :list` cannot express element types, and `@enforce_keys` only checks key *presence* — so a malformed claim currently surfaces as an opaque render-time error. `build/3` adds guards (`is_binary(id)`, non-empty `id`/`statement`, every element `%Citation{}`) and raises `ArgumentError` at construction.

Bare `%Claim{}` literals stay legal: hardening the struct into an opaque type would freeze an interface PD1 explicitly declares renegotiable.

**Constraint:** `build/3` must stay pure — unlike `Turn.build/3`, it must not call `DateTime.utc_now()` — so it is usable in compile-time module-attribute test fixtures (`@claim_a Claim.build(...)`).

## 5. Test design — multi-claim case (design question 2)

One new test in the existing `describe "hypothesis_panel/1"`, using two claims each with its **own** citation. Existing four tests keep their string-matching style; only this one goes structural, because containment is the property under test.

Fixture requirement: the two citations must differ in `source_resource_id` **or** `chunk_index`. `Citation.ref/1` is `"#{kind}/#{short_id}#chunk-#{index}"` — identical inputs yield an identical `source_ref`, hence duplicate DOM ids, which makes "no bleed" unprovable.

Assertions, in order:

1. `claim_a.statement` byte offset < `claim_b.statement` byte offset — list order preserved.
2. Both `<li>` ids present: `hyp-claim-1`, `hyp-claim-2`.
3. Disclaimer offset < **both** statement offsets (spec: holds regardless of claim order).
4. **Containment (the core assertion):** parse with `LazyHTML.from_fragment/1` (already in test deps — no `mix.exs` change; this project has no Floki). Query `li#hyp-claim-1 details`, read the `id` attribute, assert it equals exactly `["citation-#{cite_a.source_ref}"]`; same for `li#hyp-claim-2` / `cite_b`. **Gotcha:** `source_ref` contains `#`, so a CSS id selector on the citation itself is unusable — scope by `<li>` and compare the attribute as a string.
5. Global counts: exactly 2 `details`, exactly 2 `section.citation-list` — proves no shared/merged citation surface.

Size: ~1 test, ~2 fixtures. Trivially inside the 400-line review budget.

## 6. ADR-style decisions

- **D1 — Triplicated disclosure over one moduledoc note.** Rationale: §3. Rejected single-paragraph placement, which the `Claim` reader and the copy editor both miss.
- **D2 — `Claim.build/3` additive, struct literals still legal.** Rejected: bare struct only (no element-type check anywhere in the path); opaque type with enforced constructor (contradicts PD1's renegotiability).
- **D3 — `build/3` is pure.** Rejected mirroring `Turn.build/3`'s `DateTime.utc_now()`: it would break compile-time fixtures and add a non-deterministic field the panel never renders.
- **D4 — `LazyHTML` structural assertion only for the multi-claim test.** Rejected byte-slicing between `<li>` boundaries: brittle and cannot prove nesting.
- **D5 — No `expanded` passthrough.** Collapsed-by-default is #230's contract, not a panel defect (proposal, out of scope).

## 7. File changes

| File | Action | Description |
|---|---|---|
| `lib/alethea_web/live/grounded_chat/hypothesis_panel.ex` | Modify (draft on branch) | Moduledoc `## Estado provisional` + `## Hand-off`; `Claim` moduledoc PD1 note; `Claim.build/3`; PD4 HEEx comment above the disclaimer |
| `test/alethea_web/live/grounded_chat/hypothesis_panel_test.exs` | Modify | Add multi-claim test + second citation fixture; adopt `Claim.build/3` in fixtures |
| `lib/alethea_web/components/core_components.ex` | Unchanged | Consumed verbatim |
| `lib/alethea/clinical_record/rag/citation.ex` | Unchanged | `from_retrieval_result/1` used in tests only |

## 8. Threat matrix

N/A — no routing, shell, subprocess, VCS/PR automation, executable-file classification, or process-integration boundary. Pure render-layer component with no I/O, no user-supplied input path, and no persistence.

## 9. Migration / rollout

No migration. No schema, config, or feature flag. Rollback = revert the commit; the component has no consumer on this branch or on `main`.

## 10. Open questions

- [ ] PD1 reconciliation against #229's real return shape — carried forward from the proposal, non-blocking for `sdd-tasks`.
- [ ] Clinical/legal sign-off on the PD4 copy — a release gate, not a code gate.
