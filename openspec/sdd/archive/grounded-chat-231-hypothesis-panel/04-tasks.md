# Tasks — grounded-chat-231-hypothesis-panel

**Change:** grounded-chat-231-hypothesis-panel (issue #231) | **Store:** hybrid
**Mode:** Strict TDD — every task is RED (failing test first) → GREEN (minimum code) → REFACTOR.
**Test runner:** `mix test test/alethea_web/live/grounded_chat/hypothesis_panel_test.exs`
**Baseline:** draft already on `feat/grounded-chat-231-hypothesis-panel` — 4 passing tests, working component. This is incremental refinement, not a rebuild.

**Inputs:** `spec.md`, `design.md`.

## Review Workload Forecast

| Field | Value |
|-------|-------|
| Estimated changed lines | ~140–150 (component ~50, test ~90–95) |
| 400-line budget risk | Low |
| Chained PRs recommended | No |
| Suggested split | Single PR |
| Delivery strategy | ask-on-risk |
| Chain strategy | pending |

Decision needed before apply: No
Chained PRs recommended: No
Chain strategy: pending
400-line budget risk: Low

**Arithmetic:** `hypothesis_panel.ex` is 81 lines today. Additions: `## Estado provisional` + `## Hand-off` moduledoc sections (~18 lines), `Claim` moduledoc PD1 note (~4 lines), one HEEx comment above the disclaimer div (1 line), `Claim.build/3` with guards + doc (~20 lines) ≈ 43 additions, ~5 lines reflowed → ~50 changed. `hypothesis_panel_test.exs` is 102 lines today. Additions: `Claim.build/3` guard-clause tests (~30 lines), multi-claim `LazyHTML` test + second citation/claim fixtures (~40 lines), moduledoc-disclosure test (~10 lines), refactor of `@claim` to `Claim.build/3` (~5 lines net) ≈ 85 changed. Total ≈ 135–150 — well under the 400-line budget, no chaining or exception needed.

### Suggested Work Units

| Unit | Goal | Likely PR | Focused test command | Runtime harness | Rollback boundary |
|------|------|-----------|----------------------|-----------------|-------------------|
| 1 | Full incremental refinement (moduledoc disclosure, `Claim.build/3`, multi-claim test) | PR 1 (single) | `mix test test/alethea_web/live/grounded_chat/hypothesis_panel_test.exs` | N/A — pure render component, no LiveView mount on this branch yet (#227 not landed); `render_component/2` in ExUnit is the full runtime harness available | `git revert` the single commit; no consumer references this module on `main` |

## Phase 1: RED — failing tests first

- [x] 1.1 In `test/alethea_web/live/grounded_chat/hypothesis_panel_test.exs`, add a test asserting the compiled `@moduledoc` (via `Code.fetch_docs/1`) contains the PD1 provisional-pending-#229 disclosure and the PD4 draft-copy-pending-sign-off disclosure. Satisfies spec: "Provisional-interface and draft-copy disclosure in moduledoc".
- [x] 1.2 Add tests for `Claim.build/3` (not yet defined — RED by non-existence): valid `id`/`statement`/`citations` returns a `%Claim{}`; raises `ArgumentError` for non-binary `id`, empty `id`, empty `statement`, and a `citations` list containing a non-`%Citation{}` element.
- [x] 1.3 Add a second `Citation` fixture differing in `source_resource_id` or `chunk_index` from `@citation` (per design D4 — avoids duplicate `Citation.ref/1` output), and a second `Claim` fixture (`hyp-claim-2`).
- [x] 1.4 Add the multi-claim test to `describe "hypothesis_panel/1"` using `LazyHTML.from_fragment/1` with the design's 5 assertions: (a) `claim_a.statement` byte offset < `claim_b.statement` offset, (b) both `<li>` ids (`hyp-claim-1`, `hyp-claim-2`) present, (c) disclaimer offset < both statement offsets, (d) `li#hyp-claim-1 details` id equals `"citation-#{cite_a.source_ref}"` and same scoped-by-`<li>` check for claim b (string-compare, not CSS id selector, because `source_ref` contains `#`), (e) exactly 2 `details` and exactly 2 `section.citation-list` globally. Satisfies spec: "Multi-claim rendering is independent per claim".
- [x] 1.5 Run `mix test test/alethea_web/live/grounded_chat/hypothesis_panel_test.exs` — confirm 1.1 and 1.2 fail to compile/run (function/assertions don't exist yet) and 1.4 either fails or passes-by-accident against the current generic `:for` template (record which, to decide if Phase 2 needs a component edit).

## Phase 2: GREEN — minimum implementation

- [x] 2.1 In `lib/alethea_web/live/grounded_chat/hypothesis_panel.ex`, add a `## Estado provisional` section to the module `@moduledoc` stating `Claim.t()`/`interpretive?` are provisional pending #229 (PD1) and the disclaimer copy is an engineering draft pending clinical/legal sign-off (PD4).
- [x] 2.2 Add a `## Hand-off` section to the same `@moduledoc` naming #229 (supplies `interpretive?` + `claims`), #227 (mounts the component), and #235 (composes with Síntesis, owns the visible-separation proof, must surface a #229 shape mismatch as an explicit decision point).
- [x] 2.3 Add a PD1 note to the nested `Claim` module's `@moduledoc`: shape authored here, not negotiated with #229, renegotiable when #229 lands.
- [x] 2.4 Add the HEEx comment `<%!-- PD4: borrador de ingeniería, pendiente de revisión clínica/legal --%>` immediately above the disclaimer `<div>` in the `~H` template.
- [x] 2.5 Implement `Claim.build/3` in the `Claim` submodule: `is_binary(id)` + non-empty, `is_binary(statement)` + non-empty, every `citations` element is `%Citation{}` — raise `ArgumentError` otherwise. Must stay pure (no `DateTime.utc_now()` or other non-determinism) so it works in compile-time module-attribute fixtures.
- [x] 2.6 If 1.5 showed the multi-claim test failing for a structural reason (not just missing fixtures), adjust `hypothesis_panel/1`'s `:for={claim <- @claims}` block minimally to satisfy independence-per-claim; otherwise skip — the design expects no component change is needed here.
- [x] 2.7 Run `mix test test/alethea_web/live/grounded_chat/hypothesis_panel_test.exs` — all tests green (4 pre-existing + new from Phase 1).

## Phase 3: REFACTOR

- [x] 3.1 Replace the bare `%Claim{}` literal used for `@claim` in the test module with `Claim.build/3`, keeping the module-attribute (compile-time) fixture pattern intact.
- [x] 3.2 Re-run `mix test test/alethea_web/live/grounded_chat/hypothesis_panel_test.exs` — confirm still green after the fixture refactor.

## Phase 4: Verification

- [x] 4.1 Run `mix precommit` (compile with warnings-as-errors, format, full test suite) before committing. **Corregido y verificado (`2026-09-15`)**: el warning heredado de #230 en `lib/alethea/clinical_record/rag/citation.ex:57` (`source_resource_id` sin usar) se resolvió con `_ = source_resource_id`, mismo idioma ya usado en la línea anterior para `chunk_id` en ese archivo. `mix precommit` corrió limpio una vez (6 doctests, 1040 tests, 0 failures, exit 0) tras el fix de citation.ex:57. **Nota de reproducibilidad**: corridas posteriores del suite completo (vía `sdd-verify`) mostraron 9 y 14 fallas por agotamiento del pool de conexiones Postgres bajo concurrencia async — ninguna relacionada con hypothesis_panel.ex ni citation.ex. Es flakiness ambiental preexistente de esta máquina/config de test, no una regresión de este cambio. El fix del warning en sí está confirmado correcto (aislado y reproducible); la variabilidad de "0 failures" del suite completo es un problema de infraestructura de test separado.
- [x] 4.2 Manual review: confirm no `openspec/specs/` source-of-truth tree exists to update (per spec baseline note — this delta stays the spec of record at `openspec/sdd/grounded-chat-231-hypothesis-panel/spec.md`).

## Out of scope (explicit, per spec/design)

- #229 C1 policy (deciding `interpretive?`, building `claims`).
- #227 LiveView mounting (`mount`/`handle_event` wiring).
- #235 visible-separation composition proof with Síntesis.
- Changes to `citation_list/1` (stays collapsed-by-default per #230).
- Final disclaimer copy/styling — PD4 sign-off is a release gate, not a code gate.
