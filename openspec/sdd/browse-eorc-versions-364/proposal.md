# Proposal: Browse registered E-O-R-C versions read-only (#364)

**Status:** decided — Q1 locked by the user (recommended default)

## Intent

Clinicians register immutable versions (#363) but cannot see them. They need to review how the formulation changed without any risk of editing history or losing the working draft.

## Scope

### In Scope
- Selector `#functional-analysis-version-selector` in the Workbench editor: `#functional-analysis-working-draft-option` + `#functional-analysis-version-option-#{id}` ("Versión N · date · author · truncated note").
- Read-only panel `#functional-analysis-version-view` (11 E-O-R-C fields + previous notes, full change note), shown via `:if` instead of the working form, register form and generate button.
- Server guards: save, autosave, generate, register are no-ops while a version is selected.
- Re-list after own registration and after a failed selection.
- New body-free listing function for the selector; body fetched fresh via `get_functional_analysis_version/4` on every selection.

### Out of Scope
- "Continue from this version" (#365), diffs, URL/deep-link state, cross-session PubSub refresh.
- Changes to `list_functional_analysis_versions/3`, retention, RAG, authorization (already correct).
- Distinguishing legally-deleted from not-found in `get_functional_analysis_version/4`.

## Capabilities

### New Capabilities
- `eorc-version-browsing`: list, open read-only, and return to the working draft.

### Modified Capabilities
- `clinical-review-workbench`: editor panel gains a version-selection mode that disables every write path.

## Locked Decisions

| # | Decision | Basis |
|---|----------|-------|
| L1 | Separate panel (exploration approach 1) | Working-draft assigns never touched; no stash/restore |
| L2 | Add `list_functional_analysis_version_summaries/3` (decrypts change note only) | #364 is the first production caller of `list/3`; the selector needs the note, not the body |
| L3 | No legal-deletion distinction | AC4 requires denial without text; deleted rows already return `:not_found`, and the panel then shows a generic message |
| L4 | No forced debounce flush | LiveView flushes `phx-debounce` on blur before the selector click; AC3 met by never touching draft assigns |
| L5 | Selector disabled while AI generation runs | Avoids `handle_async` collision; AC2 |
| L6 | Selection allowed in `:save_failed`/`:conflict` states | AC3 explicitly covers failed-autosave edits |
| L7 | No access audit on successful historical reads | Matches existing Workbench read policy |

## Affected Areas

| Area | Impact | Description |
|------|--------|-------------|
| `lib/alethea_web/live/target_behavior_live/review.ex` | Modified | assigns, select/return events, guards, template |
| `lib/alethea/clinical_record.ex` | Modified | summaries listing |
| `test/alethea_web/live/target_behavior_live/review_test.exs` | Modified | #364 describe block |
| `test/alethea/clinical_record/functional_analysis_version_test.exs` | Modified | summaries auth/no-body tests |

## Risks

| Risk | Likelihood | Mitigation |
|------|------------|------------|
| Stale list in other sessions | Med | Fresh fetch on select; generic denial; re-list |
| Blur-flush assumption wrong | Low | Design verifies against LiveView docs |
| Version gaps read as data loss | Low | Label uses `version_number` only, no "N of M" |

## Rollback Plan

Revert the PR. No migrations; read-only additive function.

## Dependencies

- #363 (merged).

## Success Criteria

- [ ] All five #364 AC pass in LiveView tests using stable IDs.
- [ ] Forged write events during selection leave draft and versions unchanged.
- [ ] Summaries listing never returns decrypted bodies.

## Decision Q1 (locked by user)

| # | Decision | Chosen |
|---|---|---|
| Q1 | Selector order | **Oldest-first** — matches the issue's "chronological" wording and the order `list/3` already returns. The working-draft option stays pinned at the top regardless. |
