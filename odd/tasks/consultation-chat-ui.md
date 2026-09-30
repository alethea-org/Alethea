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

- [ ] **TASK-1 — Conversational turn structure in `ConsultationLive`**
  - Status: pending.
  - Immediate pending echo, in-thread typing indicator (`#consultation-retrieving`),
    outcome replacement per turn, in-thread error bubbles, per-turn hypothesis,
    `#consultation-thread` wrapper, header/action row, idle hero with
    suggestion chips, bottom composer.
- [ ] **TASK-2 — Chat styles in `editorial.css`**
  - Status: pending.
  - Full-height flush layout, scrollable thread, bubble system, typing
    animation, compact citation chips, composer, mobile. All pre-existing
    consultation classes keep rules.
- [ ] **TASK-3 — JS hooks: autoscroll + composer behavior**
  - Status: pending.
  - `ConsultationScroll` + `ConsultationComposer` external hooks registered in
    `app.js`.
- [ ] **TASK-4 — Test suite updates + new conversational assertions**
  - Status: pending.
  - Update `#consultation-synthesis` → `#consultation-thread` in followup
    tests; rewrite R12 sibling assertions per-turn; new tests: immediate echo,
    in-thread errors, per-turn hypothesis persistence, suggestion chips,
    composer, scroll hook.
- [ ] **TASK-5 — Verification**
  - Status: pending.
  - Focused tests green, then `mix precommit` green.

## Evidence

- (filled per task: commits, test results)
