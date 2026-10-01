# Spec: Continue working from a previous E-O-R-C version (#365)

New capability `eorc-version-continuation`; delta to `eorc-version-browsing` (#364). Locked decisions L1-L7 and UI copy come from `proposal.md`.

## Requirements

| # | Requirement | Strength |
|---|---|---|
| C1 | Opening/viewing a version never writes draft, lock version, or versions (AC1) | MUST |
| C2 | Blank working form → copy applies immediately, no confirmation (L4) | MUST |
| C3 | Non-blank working form (saved or unsaved) → server-side inline confirmation before any write (L1) | MUST |
| C4 | Confirm re-fetches the version via `get_functional_analysis_version/4`, never `@selected_version_content` (L3) | MUST |
| C5 | Success copies 11 E-O-R-C fields + `previous_notes`, clears `@selected_version`/`@selected_version_content`, schedules normal autosave (seq bump, `:saving`) (L2, L7) | MUST |
| C6 | Cancel clears only the pending confirmation | MUST |
| C7 | Historical version unchanged; `version_count()` unchanged | MUST |
| C8 | Blocked in `:conflict` (L5); allowed in `:saving`/`:save_failed` (L6) | MUST |
| C9 | Any selection change discards a pending confirmation (L7) | MUST |
| C10 | Forged request/confirm while generation pending, draft tombstoned, or no selection → no-op | MUST |

## eorc-version-continuation

### Requirement: Request continuation (C2, C3)

#### Scenario: Blank draft
- GIVEN all working-form values are blank and version 2 is open
- WHEN "Continuar desde esta versión" is clicked
- THEN version 2 content becomes the working form and flash "Contenido de la Versión 2 copiado al borrador de trabajo." shows

#### Scenario: Draft has content
- GIVEN the working form has any non-blank value and version 2 is open
- WHEN "Continuar desde esta versión" is clicked
- THEN the warning text, "Reemplazar borrador", and "Cancelar" render inside `#functional-analysis-version-view`
- AND the draft row, form assigns, and version count are unchanged

### Requirement: Confirm continuation (C4, C5, C7)

#### Scenario: Successful copy
- GIVEN a pending confirmation for version 2
- WHEN "Reemplazar borrador" is clicked
- THEN `#functional-analysis-form` shows version 2's content and the version view is absent
- AND `#editor-draft-status` shows saving, then the draft persists version 2's content via autosave
- AND version 2's body and `version_count()` are unchanged

#### Scenario: Stale queued autosave superseded
- GIVEN `draft_status` is `:saving` or `:save_failed` with an older autosave queued
- WHEN continuation is confirmed
- THEN the persisted draft equals version 2's content, not the older edit

#### Scenario: Version gone since opening
- GIVEN version 2 was legally deleted after being opened
- WHEN continuation is confirmed
- THEN "La versión no está disponible." shows, no protected text renders, the draft is unchanged, and the list refreshes

#### Scenario: Unauthorized
- GIVEN access to the patient/behavior was lost
- WHEN continuation is confirmed
- THEN the clinician is redirected as `select_functional_analysis_version` does, with no copy

#### Scenario: Reload invariant
- GIVEN continuation from version 2 succeeded and autosave completed
- WHEN the review page is mounted fresh
- THEN the working form shows version 2's copied content
- AND re-opening version 2 shows its original body

### Requirement: Cancel and selection change (C6, C9)

#### Scenario: Cancel
- GIVEN a pending confirmation
- WHEN "Cancelar" is clicked
- THEN the confirmation disappears, version 2 stays displayed, and draft/DB are identical

#### Scenario: Switch selection
- GIVEN a pending confirmation for version 2
- WHEN version 1 or the working-draft option is selected
- THEN no confirmation renders and a later forged confirm writes nothing

### Requirement: Blocked states (C8, C10)

#### Scenario: Conflict
- GIVEN `draft_status` is `:conflict`
- WHEN continuation is requested or confirmed
- THEN flash "Resolvé el conflicto de guardado antes de continuar desde una versión." shows and nothing is written

#### Scenario: Forged events
- GIVEN generation is pending, the draft is tombstoned, or no version is selected
- WHEN request/confirm arrives via `render_hook`
- THEN no autosave is scheduled; draft, lock version, and version count are unchanged

## eorc-version-browsing (delta)

## MODIFIED Requirements

### Requirement: Read-only version view (R4, R7)

The version view MUST stay read-only; its only write-capable action is "Continuar desde esta versión", which writes solely the working draft.
(Previously: view had no actions.)

#### Scenario: Open version
- GIVEN version 2 is listed
- WHEN the clinician selects it
- THEN `#functional-analysis-version-view` renders all 11 fields, previous notes, the full change note, none editable, plus the continue button
- AND `#functional-analysis-form`, `#functional-analysis-version-form`, and `#generate-functional-analysis-draft` are absent
- AND draft row, lock version, and version count are unchanged (AC1)

#### Scenario: Version removed since listing
- GIVEN a listed version was legally deleted or never belonged to this patient
- WHEN it is selected
- THEN a generic not-available message shows, no protected text renders, the working draft stays active, and the list refreshes

## Out of Scope

Automatic registration, diff/merge, undo, cross-session refresh, domain/schema changes.
