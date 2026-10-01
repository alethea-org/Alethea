# Proposal: Continue working from a previous E-O-R-C version (#365)

**Status:** decided — no open product questions (all forks locked from AC wording + codebase precedent)

## Intent

Clinicians can view old versions (#364) but cannot reuse one. They need to restart from an older formulation without rewriting history or silently losing current work.

## Scope

### In Scope
- "Continuar desde esta versión" action in `#functional-analysis-version-view`.
- Server-side two-step confirmation, only when the working form has any non-blank value.
- Copy of the 11 E-O-R-C fields + `previous_notes` into the working draft, return to working-draft mode, normal autosave.
- Server guards against forged events (tombstone, conflict, generation pending, no selection).
- Workbench tests: copy, decline, reload, unchanged snapshot, deletion race, forged events.

### Out of Scope
- Domain/schema changes; automatic version registration; diff/merge; undo of a copy; cross-session refresh.

## Capabilities

### New Capabilities
- `eorc-version-continuation`: copy a historical version into the active working draft with explicit replacement acknowledgement.

### Modified Capabilities
- `eorc-version-browsing`: the read-only panel gains one write-capable action (still no write on view).

## Locked Decisions

| # | Decision | Basis |
|---|----------|-------|
| L1 | Server-side request/confirm/cancel flow (not `data-confirm`, not `<.modal>`) | AC5 decline test impossible with `data-confirm`; mirrors citation/trim flows |
| L2 | Copy goes through a shared autosave-scheduling helper extracted from `change_functional_analysis` | "Normal autosave"; `seq` bump cancels stale queued saves |
| L3 | Re-fetch via `get_functional_analysis_version/4` at confirm | Authorization + legal deletion can change after viewing (AC4) |
| L4 | Blank working form → copy immediately, no confirmation | Nothing to discard (AC3) |
| L5 | Copy **blocked** in `:conflict` with flash "Resolvé el conflicto de guardado antes de continuar desde una versión." | Mirrors `version_registration_blocker` (review.ex:1419); stale `lock_version` would re-conflict |
| L6 | Allowed in `:saving`/`:save_failed` | `seq` bump supersedes; `lock_version` unchanged on failure |
| L7 | Clear `selected_version`/content after copy; clear pending confirmation on every selection change | Otherwise #364 guards hide the form and no-op autosave |

## UI Copy (locked, Spanish voseo as existing UI)

| Element | Text |
|---|---|
| Action button | Continuar desde esta versión |
| Warning | El borrador de trabajo actual será reemplazado por el contenido de la Versión N. La versión histórica no se modifica y no se registra una versión nueva. |
| Confirm | Reemplazar borrador |
| Cancel | Cancelar |
| Success flash | Contenido de la Versión N copiado al borrador de trabajo. |

## Affected Areas

| Area | Impact | Description |
|------|--------|-------------|
| `lib/alethea_web/live/target_behavior_live/review.ex` | Modified | events, assign, helper, panel UI |
| `test/alethea_web/live/target_behavior_live/review_test.exs` | Modified | new #365 describe block |

## Risks

| Risk | Likelihood | Mitigation |
|------|------------|------------|
| Stale queued autosave overwrites copy | Low | Shared helper, mandatory `seq` bump |
| Forged event on tombstoned draft | Low | Server guard before scheduling |
| Version deleted between view and copy | Low | L3 re-fetch → flash + relist |

## Rollback Plan

Revert the PR. No migrations; UI/LiveView only.

## Dependencies

- #362, #364 (merged).

## Success Criteria

- [ ] All five #365 AC pass in LiveView tests with stable IDs.
- [ ] Historical version body and `version_count()` unchanged after copy.
- [ ] Declining leaves draft and DB identical.
