# Tasks — grounded-chat-235-integration

**Change:** grounded-chat-235-integration (issue #235) | **Store:** hybrid
**Mode:** Strict TDD — RED (failing test) → GREEN (minimum code) → REFACTOR, per task where applicable.
**Branch:** `feat/grounded-chat-235-integration` (cut from `feat/grounded-clinical-chat-hypotheses`) → 4 chained child branches, each targeting the previous slice.
**Inputs:** `proposal.md` (1fbcc84), `spec.md` (47e43d9, 12 requirements), `design.md` (398a845) — design is authoritative for code shape; tasks slice it, not re-derive it.

## Review Workload Forecast

| Field | Value |
|---|---|
| Estimated changed lines | ~940 total across 4 PRs (design's Slicing Plan, verbatim) |
| 400-line budget risk | Low per slice (each under 400) |
| Chained PRs recommended | Yes |
| Suggested split | #235a0 → #235a → #235b → #235c |
| Delivery strategy | ask-on-risk (session default; not overridden) |
| Chain strategy | feature-branch-chain (pre-fixed by design's Slicing Plan) |

Decision needed before apply: No
Chained PRs recommended: Yes
Chain strategy: feature-branch-chain
400-line budget risk: Low

**Arithmetic (design's Slicing Plan, unchanged):** #235a0 ≈187 (ast_scan.ex ~70, ast_scan_test.exs ~90, hypothesis_policy_test.exs +3/−24) · #235a ≈266 (live.ex +32, answer.ex +4, live_test.exs +160, hypothesis_wiring_gate_test.exs +70) · #235b ≈228 (consultation_live.ex +12, fake.ex +15/−6, rag_fixtures.ex +25, consultation_live_test.exs +170) · #235c ≈259 (core_components.ex +15/−3, consultation_live.ex +18/−26, source_citation.ex +32, hypothesis_panel.ex +4/−30, citation_test.exs +55, consultation_live_test.exs +35/−18, hypothesis_panel_test.exs +15/−8). No drift found while slicing into tasks — every file design named appears in a task below and nothing new was added.

### Suggested Work Units

| Unit | Goal | Likely PR | Focused test command | Runtime harness | Rollback boundary |
|---|---|---|---|---|---|
| #235a0 | AST scanner extraction, gate migrated | PR 1 (base = tracker) | `mix test test/alethea/test_support/ast_scan_test.exs test/alethea/clinical_record/rag/consultation/hypothesis_policy_test.exs` | N/A — pure ExUnit, no process/runtime boundary (design's Threat Matrix: N/A) | Pure test-infra; revert restores `hg_walk/2` verbatim, zero production diff |
| #235a | Domain wiring + gate | PR 2 (base = #235a0) | `mix test test/alethea/clinical_record/rag/consultation/live_test.exs test/alethea/clinical_record/rag/consultation/hypothesis_wiring_gate_test.exs` | N/A — `answer/4` unit harness, no LiveView mount | Revert restores `hypothesis: nil` in every `Answer` — today's production behavior exactly |
| #235b | Panel mount + E2E | PR 3 (base = #235a) | `mix test test/alethea_web/live/consultation_live_test.exs test/alethea/clinical_record/rag/consultation/live_test.exs` | `Phoenix.LiveViewTest` render/mount (no external service) | Revert restores current render (Síntesis + Fuentes, no panel) |
| #235c | Citation unification | PR 4 (base = #235b) | `mix test test/alethea_web/components/citation_test.exs test/alethea_web/live/grounded_chat/hypothesis_panel_test.exs test/alethea_web/live/consultation_live_test.exs` | `Phoenix.LiveViewTest` + `LazyHTML` DOM assertions | Revert restores hand-rolled source markup; no persisted state anywhere in this change |

## Requirement Coverage (12 → slice, per design's Test Plan)

R1,R2,R3,R6,R7,R9,R11 → **#235a** · R4,R5,R12 → **#235b** · R8 → **#235a + #235b** (domain + render halves; zero-evidence half covered by construction, no new test) · R10 → **#235c**

## Phase 0 — Slice #235a0: AST scan extraction (pure refactor)

- [x] 0.1 RED: `test/alethea/test_support/ast_scan_test.exs` — full positive/negative table from design AD5 (`HypothesisPolicy.evaluate(a,b)`, aliased call, `&.../2` capture, `apply/3`, `import`, moduledoc string, `alias`, pattern-match struct). Module doesn't exist yet — compile failure is the RED. Actual RED: 13/13 failures (`UndefinedFunctionError`).
- [x] 0.2 GREEN: create `test/support/ast_scan.ex` (`AletheaTest.ASTScan`) — `lib_files/1`, `parse!/1`, `constructs_struct?/2` (moved verbatim from `hg_walk/2`, generalized to any `atom()` struct name), `calls?/3` (new).
- [x] 0.3 Run 0.1 — green. Actual: 13/13 passing.
- [x] 0.4 REFACTOR: migrate `hypothesis_policy_test.exs`'s Sole Constructor Gate to call `ASTScan.constructs_struct?/2`; delete `hg_walk/2`. Actual diff: +4/−34 (design estimated +3/−24).
- [x] 0.5 Run `mix test test/alethea/clinical_record/rag/consultation/hypothesis_policy_test.exs` — still green, proves the extraction is behavior-preserving. Actual: 91/91 passing (same count as pre-migration).
- [ ] 0.6 `mix precommit`; open PR #235a0 targeting `feat/grounded-chat-235-integration`.

## Phase 1 — Slice #235a: Domain wiring + gate

- [x] 1.1 RED: `test/alethea/clinical_record/rag/consultation/hypothesis_wiring_gate_test.exs` (new file, `async: true`, no `DataCase`) — AST-scan assertion: zero `HypothesisPolicy.interpretive_intent?/1`/`evaluate/2` call sites under `lib/**` outside `consultation/live.ex`; negative control for a moduledoc mention (R9, R11). Actual RED: sanity test "consultation/live.ex itself does call the policy" failed (2/3 passing) since the call site did not exist yet.
- [x] 1.2 RED: `live_test.exs` — extend `answer/4 — synthesis on sufficient evidence`: interpretive query → `hypothesis: %Hypothesis{}` (R1); factual query → `hypothesis: nil` + `expect(ClinicalHypothesisChainMock, :run, 0, ...)` (R2). Actual RED: the interpretive-query test failed (`hypothesis: nil` instead of `%Hypothesis{}`); the factual-query test passed trivially (default `nil`).
- [x] 1.3 GREEN: `lib/alethea/clinical_record/rag/consultation/live.ex` — add `maybe_hypothesis/3` + `hypothesis_chain/0`, wire into `synthesize/2`'s success branch, per design AD1 code shape verbatim.
- [x] 1.4 GREEN: `lib/alethea/clinical_record/rag/consultation/answer.ex` — close the moduledoc's "#235 will wire this" note.
- [x] 1.5 **Apply-phase hazard sweep** — ran full `mix test` suite after 1.3/1.4 landed. Result: **6 doctests, 1221 tests, 0 failures, 5 skipped** — zero legacy fixture queries in `live_test.exs`/`consultation_live_test.exs` newly hit `ClinicalHypothesisChainMock`. No fixes needed. Root cause of zero hazard: (a) `consultation_live_test.exs` renders through `Consultation.Fake` in `:test` (config/test.exs `:clinical_consultation` → `Fake`), which doesn't call `HypothesisPolicy` at all (#235b/AD2 territory, untouched here); (b) `live_test.exs`'s pre-existing queries (`"q"`, `"animo"`, `"consulta"`, `"¿cómo va el ánimo?"`, the two adversarial secret-texts, etc.) contain none of `HypothesisPolicy`'s interpretive markers.
- [x] 1.6 RED→GREEN: `live_test.exs` — new describe `answer/4 — the hypothesis path is additive and fail-silent (#235)`: raise / `{:error, _}` / blank-prose-`{:reject, :empty_statement}` / diagnostic-marker-`{:reject, :diagnostic_language}` / prescriptive-marker-`{:reject, :prescriptive_language}` → all assert `outcome: :synthesis, hypothesis: nil` with `synthesis`/`sources` unaffected (R3, R8 domain half). Passed immediately against 1.3's implementation, no further code change (characterization run).
- [x] 1.7 RED→GREEN: `live_test.exs` — extended `cross-patient isolation` and `cross-tenant isolation` describes with an interpretive-query variant: hypothesis IS produced (own-patient evidence present) but neither `Answer.sources` nor `hypothesis.sources` ever reference the foreign patient's/professional's leaked resource id (R6). Passed immediately, no further code change.
- [x] 1.8 RED→GREEN: `live_test.exs` — extended `clinical state is never mutated` describe with a hypothesis-turn case: byte-identical `state_snapshot()` (chunks + oban jobs), stable `Repo.aggregate(Oban.Job, :count)` across a hypothesis-producing turn (R7). Passed immediately, no further code change.
- [x] 1.9 Ran `mix test test/alethea/clinical_record/rag/consultation/live_test.exs test/alethea/clinical_record/rag/consultation/hypothesis_wiring_gate_test.exs` — **31 tests, 0 failures**. Confirmed: 1.6–1.8 passed against the 1.3 implementation with no further code changes — `maybe_hypothesis/3`'s own rescue boundary and empty-excerpt guard already satisfied them, exactly as design predicted.
- [ ] 1.10 `mix precommit`; open PR #235a targeting #235a0's branch.

## Phase 2 — Slice #235b: Panel mount + E2E

- [x] 2.1 REFACTOR (prep, no behavior change): `lib/alethea/clinical_record/rag/consultation/fake.ex` — `canned_sources/0` → `Source.from_results(canned_results())`, so the fake's sources and the fixture's hypothesis cite the same fragment (design AD2). Actual: `canned_results/0` made public (`@doc`/`@spec`), reused by `Alethea.RagFixtures.canned_hypothesis!/0`.
- [x] 2.2 GREEN: `test/support/fixtures/rag_fixtures.ex` — add `canned_hypothesis!/0` (built through the real `HypothesisPolicy.evaluate/2`, never hand-rolled), `set_fake_hypothesis/1`, `reset_fake_hypothesis/0`; wire the reset into the existing `on_exit` alongside `reset_fake_outcome/0`. Actual: `on_exit` lives in `consultation_live_test.exs`'s own setup block (not in `rag_fixtures.ex`); wired `reset_fake_hypothesis()` there alongside `reset_fake_outcome()`.
- [x] 2.3 GREEN: `fake.ex` — add `selected_hypothesis/1` and thread it into the `:synthesis` branch's `hypothesis:` field, per design AD2 verbatim. Never call `HypothesisPolicy` from `fake.ex` — that would create a second AST-scan call site and break #235a's gate. Confirmed: Hypothesis Wiring Gate re-run after this change — 4/4 tests still green.
- [x] 2.4 RED→GREEN: `consultation_live_test.exs` — new describe `hypothesis panel over the real pipeline (#235)`: interpretive turn HTML contains `section.review-hypothesis-panel` (via `has_element?/2`, attribute-order-safe — HEEx emits `id` before `class`, so a literal `<section class="...">` string match is a false negative); factual turn HTML contains that tag nowhere, not even hidden (R4).
- [x] 2.5 RED→GREEN: same describe — E2E: disclaimer's byte offset precedes the statement's; citation renders as a collapsed `<details>` (no excerpt leak in the initial DOM, matching `citation_list/1`'s always-collapsed contract — it never threads an `expanded` passthrough, confirmed against `core_components.ex`/`citation_test.exs`); the exact server-derived excerpt is proven via a ground-truth direct `Consultation.answer/4` call (deterministic Mox stubs, same seeded chunk) whose `Source.excerpt` is asserted `== @seeded_excerpt`, then re-rendered through `CoreComponents.citation/1` with `expanded: true` to prove the mechanism shows it verbatim (R5).
- [x] 2.6 RED→GREEN: same describe — diagnostic/prescriptive candidate prose via the real chain ⇒ `hypothesis: nil`, no panel in the DOM (R8 render half).
- [x] 2.7 RED→GREEN: same describe — `#consultation-synthesis` and the hypothesis panel `<section>` exist as sibling elements under the same parent, neither nested inside the other (R12), proven via `LazyHTML` child-combinator queries (`div.consultation > section#...`) plus negative descendant queries in both directions.
- [x] 2.8 GREEN: `lib/alethea_web/live/consultation_live.ex` — `import AletheaWeb.GroundedChat.HypothesisPanel, only: [hypothesis_panel: 1]`; mount `<.hypothesis_panel :if={@state == :synthesis} id={"consultation-hypothesis-turn-#{@turn}"} hypothesis={@last_answer.hypothesis} />` after `#consultation-sources`, per design AD3 verbatim — confirmed `@state`/`@turn`/`@last_answer` against the real file first; no deviation, assign names matched exactly.
- [x] 2.9 Run `mix test test/alethea_web/live/consultation_live_test.exs test/alethea/clinical_record/rag/consultation/live_test.exs` — all green. Actual: 46 tests, 0 failures.
- [ ] 2.10 `mix precommit`; open PR #235b targeting #235a's branch.

## Phase 3 — Slice #235c: Citation unification (Q2/b)

- [ ] 3.0 **Inherited fix from #230, own commit, own PR-description paragraph — never bundled with 3.3/3.4's link-slot commit.** `core_components.ex`'s `<p :if={@expanded} class="citation__excerpt">` structurally omits the excerpt from the DOM entirely when collapsed (not CSS-hidden — never sent to the client), which makes expand-to-reveal genuinely unreachable by any real user interaction: PR #248's own description claims "native `<details>`/`<summary>` for expand/collapse (zero JS, zero LiveView round-trip)," but without JS there is no mechanism that ever re-renders with `expanded: true` after the initial paint, so a real click on `<summary>` only toggles the browser-local `open` attribute of an already-empty `<details>`. `grep -r "expanded: true" lib/` confirms zero production call sites ever set it. No comment, PR discussion, or ADR documents this as a deliberate privacy/confidentiality control, and `ConsultationLive`'s "Fuentes" section renders the same `source.excerpt` content ungated, unconditionally, on the same page — undercutting a security rationale. Verdict: design oversight inherited from #230/#231, not something #235b introduced or should have caught (#235b correctly assumed #230's disclosure mechanism worked). Fix: remove the `:if={@expanded}` gate so the excerpt `<p>` is always present in the DOM (native `<details>` already hides it visually until opened — that's the whole point of the element, no extra gating needed). Update `citation_test.exs:48-59`'s `"renders kind, ref and fecha as the summary — excerpt is hidden"` test in the SAME commit as this fix: its `refute html =~ excerpt` assertion currently passes only because of the bug being fixed, and its "hidden" framing conflates "visually collapsed" with "absent from DOM" — rename/rewrite to assert presence in HTML plus the collapsed `<details>` state (no `open` attribute), matching how `expanded: true`'s sibling test already asserts presence.
- [ ] 3.1 **DECISION CHECKPOINT — `source_kind_label/1` humanization.** Confirm or reject design's Open Question recommendation: move `source_kind_label/1` into `core_components.ex` as `citation/1`'s private `kind_label/1`, making the single renderer also the single humanizer (touches #230's shipped DOM assertions, already accepted by Q2/b). Record the answer before 3.4.
- [ ] 3.2 **DECISION CHECKPOINT — datetime precision.** Confirm: accept the day-level loss (drop `%H:%M`, `citation/1`'s existing ISO-date rendering wins), or add `attr :datetime, :boolean, default: false` to `citation/1` to preserve time-of-day. Record the answer before 3.9.
- [ ] 3.3 RED: `citation_test.exs` — new describe `citation/1 — optional link slot`: `:link` slot content renders inside `<summary>` when the caller passes it; absent and no error when the caller passes nothing (R10).
- [ ] 3.4 GREEN: `lib/alethea_web/components/core_components.ex` — add `slot :link` to `citation/1`, render `<span :if={@link != []}>` inside `<summary>` per design AD4 verbatim; apply 3.1's decision.
- [ ] 3.5 GREEN: create `lib/alethea_web/live/grounded_chat/source_citation.ex` — promote `source_to_citation/1` to a public `AletheaWeb.GroundedChat.SourceCitation` adapter (`%Source{} → %Citation{}`, ~30 lines).
- [ ] 3.6 REFACTOR: `lib/alethea_web/live/grounded_chat/hypothesis_panel.ex` — delegate to the promoted converter; close its moduledoc hand-off note.
- [ ] 3.7 RED then GREEN: `hypothesis_panel_test.exs` — extend for converter delegation; confirm no behavior change (pure regression).
- [ ] 3.8 RED: `consultation_live_test.exs` — extend `grounded answer over the real pipeline (#234a)`: migrated source list via `citation_list/1` still renders "Ver conducta objetivo" for a source with non-nil `target_behavior_id`; no dangling link and no error for `target_behavior_id: nil` (R10).
- [ ] 3.9 GREEN: `consultation_live.ex` — replace hand-rolled source markup with `<.citation_list citations={@citations}>` + `<:link>` slot calling the existing `source_link/2` route helper, per design AD4 call-site verbatim; apply 3.2's decision.
- [ ] 3.10 Run `mix test test/alethea_web/components/citation_test.exs test/alethea_web/live/grounded_chat/hypothesis_panel_test.exs test/alethea_web/live/consultation_live_test.exs` — all green, including the preserved "Ver conducta objetivo" assertions.
- [ ] 3.11 `mix precommit`; open PR #235c targeting #235b's branch. PR description must state explicitly that it bundles two related but independent changes riding on the same file: (a) the `:link` slot for navigation preservation, Q2/b's original scope (commit from 3.4); (b) the inherited excerpt-gating fix from #230 (commit from 3.0), with the evidence trail (PR #248's "zero JS, zero round-trip" claim, no privacy rationale documented anywhere, ungated "Fuentes" precedent) summarized inline so a reviewer doesn't need to reconstruct it.

## Out of scope (explicit, per spec/design)

- Any change to C1's `HypothesisPolicy` markers, gate precedence, disclaimer text, forbidden-language regexes (#229 ships untouched).
- Follow-up interpretive intent resolution (#233).
- Hypothesis persistence, audit logging, accept/reject UI.
- Zero-evidence E2E test for R8 — covered by construction (`kept` is never `[]` through `answer/4`), per spec's explicit correction.
