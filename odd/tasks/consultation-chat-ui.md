# Consultation Chat UI — ChatGPT/Claude-style conversational surface

## Objective

Reshape `AletheaWeb.ConsultationLive` (`/patients/:patient_id/consultation`) into a
true modern chat experience (ChatGPT/Gemini/Claude style) built natively on the
existing editorial design system — no new dependencies, no Tailwind, no Petal.
The conversation must keep the grounded-citation guarantees intact: per-turn
`Fuentes` rendered through `CoreComponents.citation/1`, hypothesis panel
contract, zero persistence (ADR-010 §6).

User decision (2026-10 session): **native over editorial.css**, **presentation
only** — no token streaming in this pass; the blocking `Consultation.answer/4`
contract stays untouched.

## Scope

- `lib/alethea_web/live/consultation_live.ex` — conversational turn structure:
  - Immediate user echo: `"ask"` inserts the turn item into the stream with
    `status: :pending` (user bubble + in-thread typing indicator) before
    `start_async`, so the question is visible while retrieving.
  - `handle_async/3` replaces the pending item (same DOM id `turn-N`) with the
    resolved outcome: `:synthesis`, `:no_evidence`, `:stale`, `:provider_failure`.
  - Error outcomes render as in-thread assistant notice bubbles (keeping ids
    `consultation-no-evidence`, `consultation-stale`, `consultation-provider-error`)
    instead of detached page-level blocks.
  - Per-turn hypothesis: each synthesis turn keeps its own
    `hypothesis_panel` (sibling of the turn's synthesis/sources sections).
    The global `last_answer`-driven panel is removed.
  - Thread wrapper renamed `#consultation-synthesis` → `#consultation-thread`
    (it must exist whenever the stream is non-empty, including error turns).
  - Header row: title + `#consultation-new-conversation` moved top-right.
  - Idle hero (`#consultation-idle`): centered greeting + static suggestion
    chips (`"suggest"` event reusing the ask path).
  - Composer pinned to the bottom: `#consultation-ask-form` with a 1-row
    textarea, circular send button (hero-arrow-up), disabled while retrieving.
- `priv/static/assets/css/editorial.css` — chat styles on existing tokens:
  full-height column layout (negative-margin flush against `.app-content`
  padding), scrollable thread, right-aligned user bubbles, left-aligned
  assistant rows with avatar, animated typing dots, compact citation chips
  (existing `citation*` classes restyled, all preserved), composer styling,
  mobile adjustments. Every class in
  `test/alethea_web/editorial_css_consultation_test.exs` must keep a rule.
- `priv/static/assets/js/app.js` — two external hooks registered on the
  `LiveSocket` constructor:
  - `ConsultationScroll` (on `#consultation-thread`): scroll to bottom on
    mount/update when the user is near the bottom (~120px tolerance).
  - `ConsultationComposer` (on the form/textarea): Enter sends (form
    `requestSubmit()`), Shift+Enter inserts a newline; textarea auto-grows
    up to a max height.
- Test updates and new conversational assertions in
  `test/alethea_web/live/consultation_live_test.exs` and
  `test/alethea_web/live/consultation_live_followup_test.exs` (details in
  TASK-4).

## Constraints and non-goals

- Domain untouched: `Alethea.ClinicalRecord.Rag.Consultation`,
  `FollowupState` semantics, turn-counter rules (only synthesis advances),
  authorization, zero persistence.
- `CoreComponents.citation/1` / `citation_list/1` DOM contract unchanged
  (`<details>` per source, `#turn-N-sources` container).
- `HypothesisPanel` component unchanged; only its mount point moves per-turn.
- No streaming (explicitly deferred), no markdown rendering of synthesis.
- No new deps, no Petal, no Tailwind.

## Testing configuration

- TDD mode: strict (new assertions first, then implementation, per task).
- Focused command: `mix test test/alethea_web/live/consultation_live_test.exs test/alethea_web/live/consultation_live_followup_test.exs test/alethea_web/editorial_css_consultation_test.exs`.
- Final command: `mix precommit`.

## Tasks

- [x] **TASK-1 — Conversational turn structure in `ConsultationLive`**
  - Status: completed (commit 7c82dc8).
  - `start_consultation_turn/2` shared by `"ask"` and `"suggest"`; pending stream
    echo under the same DOM id the async resolution replaces; per-turn synthesis/
    sources/hypothesis; in-thread error notices; header + hero + composer.
- [x] **TASK-2 — Chat styles in `editorial.css`**
  - Status: completed (commit 7c82dc8).
  - Full-height flush column (100dvh-64px, negative margins), scrollable thread,
    right-aligned user bubbles on `--colors-primary`, typing-dots keyframes,
    citation pills, composer with safe-area mobile. All pre-existing classes
    keep rules; 10 new classes locked by the CSS test.
- [x] **TASK-3 — JS hooks: autoscroll + composer behavior**
  - Status: completed (commit 7c82dc8).
  - `ConsultationScroll` (near-bottom stick, 120px) + `ConsultationComposer`
    (Enter submits, Shift+Enter newline, auto-grow ≤160px) registered in
    `app.js` LiveSocket hooks.
- [x] **TASK-4 — Test suite updates + new conversational assertions**
  - Status: completed (commit 7c82dc8).
  - RED 20 failures → GREEN 68/68 on the focused suite. Followup
    `#consultation-synthesis` → `#consultation-thread` (5 sites); blocked-turn
    refutes migrated to the in-thread contract (refute `#turn-N-synthesis` +
    notice assert) with orchestrator approval; R12 rewritten per-turn; new
    describe covering immediate echo, in-thread errors, per-turn hypothesis,
    suggestion chips, hooks, send-disabled.
- [x] **TASK-5 — Verification**
  - Status: completed (doc close commit).
  - First `mix precommit`: 1690/1691, single failure AletheaWeb.IconsTest
    (hero-arrow-up/hero-sparkles missing from the icon whitelist) → fixed in
    commit 9d2cbcd (official Heroicons v2 outline paths added to
    `lib/alethea_web/components/icons.ex`); focused icons test 3/3.
  - Full `mix precommit` re-run (gentle-ai-verify, background): **exit 0** —
    compile --warnings-as-errors, deps.unlock --unused, format, test:
    1691 passed (6 doctests + 1685 tests), 5 skipped, 0 failures (185.2s).

## Evidence

- Commit 7c82dc8 `feat(web): conversational chat UI for clinical consultation`
  (implementation + tests + this doc; 7 files, +798/−143).
- Commit 9d2cbcd `fix(web): add hero-arrow-up and hero-sparkles to icon set`.
- Focused suite: 68/68 green (`editorial_css_consultation`, `consultation_live`,
  `consultation_live_followup`).
- Worker TDD evidence: RED 20 → GREEN 65/68 → 68/68 after approved
  blocked-turn assertion migration.
- Full gate: first run 1690/1691 (icons coverage, fixed in 9d2cbcd); re-run
  **exit 0, 1691 passed / 0 failed / 5 skipped** (gentle-ai-verify).
- Native review (RDD): the doc-only workspace candidate
  (sha256:e13daab…) started ordinary, closed approved (low risk,
  non_executable_only, no lenses), acknowledged and burned
  (gentle-ai.review-acknowledged/v1) — lineage review-14cb8536a4de0e76.
- Native review of the code candidate (base-diff from ef6f8c4, 14 files,
  1464 lines, lineage review-4106a498593a4eeb, lens review-reliability):
  CRITICAL finding R3-pending-turn-match-error — `handle_async/3`'s
  :exit clause matched `pending_turn` unconditionally, so "nueva
  conversación" mid-flight (reset to nil, task uncancellable) crashed
  the LiveView on the late exit; the :ok path could also pollute the
  fresh conversation. Correction plan declared (48 lines) and applied
  in commit ccfa3e1 (44 lines: stale-result guards on both paths;
  late :unauthorized still redirects; regression test). Targeted
  provider validation approved the correction; review closed approved
  and burned (gentle-ai.review-acknowledged/v1). One advisory
  non-blocking finding remains, pre-existing on the #360 branch:
  R3-weekly-summary-schema-echo-clause (weekly_summary_chain.ex:169-172,
  informational).
- Second native review cycle (lineage review-6a25585938f417cc, lens review-reliability):
  CRITICAL finding R3-stale-async-guard-order — the general handle_async/3
  clause preceded the stale-result and unauthorized guards, shadowing them.
  Correction plan declared (30 lines) and applied in commit bb09b6a (reordered
  clauses: unauthorized redirect first, nil pending_turn discard second, general
  result third; unreachable apply_answer clause removed). Targeted provider
  validation approved the correction; review closed approved and burned
  (gentle-ai.review-acknowledged/v1). One advisory warning remains on #360 branch
  (R3-schema-echo-clause-missing-fallback in weekly_summary_chain.ex).
- Post-review ASSESS (rddLine on, nativeReviewOutcome closed, explicit):
  plan = writer self-verification is the record, no separate verifier.
  Writer record: focused suite 69/69 after both corrections, lens
  diagnostics clean, mix format applied; full gate green at e2ae0e3,
  both correction deltas covered by focused suite + native targeted validation.
