# Spec: Browse registered E-O-R-C versions read-only (#364)

New capability `eorc-version-browsing`; delta to `clinical-review-workbench` (no main spec exists, so the delta is ADDED-only).

## Requirements

| # | Requirement | Strength |
|---|---|---|
| R1 | `list_functional_analysis_version_summaries/3` returns metadata + decrypted `change_note` only, never `body` (L2) | MUST |
| R2 | Summaries use the same `with_target_behavior/4` authorization as `list_functional_analysis_versions/3` | MUST |
| R3 | Selector lists versions oldest-first; working-draft option pinned at top (Q1) | MUST |
| R4 | Selecting a version fetches it fresh via `get_functional_analysis_version/4` and shows it read-only in a separate panel (L1) | MUST |
| R5 | While a version is selected, every write path is a no-op on draft and versions | MUST |
| R6 | Returning to the working draft restores form content and `@draft_status` unchanged | MUST |
| R7 | Denied/missing/legally-deleted versions use the existing uniform `{:error, :not_found}`; no new distinction (L3) | MUST |
| R8 | Selector disabled while AI generation runs (L5); allowed in `:save_failed`/`:conflict` (L6) | MUST |
| R9 | List refreshes after own registration and after a failed selection | MUST |

## eorc-version-browsing

### Requirement: Body-free summaries (R1, R2)

#### Scenario: Summary shape
- GIVEN a behavior with versions 1 and 2
- WHEN summaries are listed
- THEN each has `id`, `version_number`, `inserted_at`, author, `change_note`, ordered by `version_number` ascending
- AND no item carries a decrypted body

#### Scenario: Cross-patient denial
- GIVEN a professional without access to the patient or behavior
- WHEN summaries are listed
- THEN the same error as `list_functional_analysis_versions/3` is returned and no note is decrypted

### Requirement: Selector (R3)

#### Scenario: Ordered listing
- GIVEN versions 1, 2, 4 (gap after legal deletion)
- WHEN the Workbench mounts
- THEN `#functional-analysis-version-selector` shows `#functional-analysis-working-draft-option` first, then `#functional-analysis-version-option-#{id}` for 1, 2, 4
- AND each label shows "Versión N", date, author full name, truncated change note, with no "N of M"

#### Scenario: No versions
- GIVEN no registered versions
- THEN only the working-draft option renders and it is selected

### Requirement: Read-only version view (R4, R7)

#### Scenario: Open version
- GIVEN version 2 is listed
- WHEN the clinician selects it
- THEN `#functional-analysis-version-view` renders all 11 fields (ids `functional-analysis-version-view-<section>-<field>`), previous notes, and the full change note, none editable
- AND `#functional-analysis-form`, `#functional-analysis-version-form`, and `#generate-functional-analysis-draft` are absent

#### Scenario: Version removed since listing
- GIVEN a listed version was legally deleted or never belonged to this patient
- WHEN it is selected
- THEN a generic not-available message shows, no protected text renders, the working draft stays active, and the list refreshes

### Requirement: Return to working draft (R6)

#### Scenario: Restore unchanged
- GIVEN draft edits with `@draft_status` `:saved` (or `:save_failed`/`:conflict`)
- WHEN the clinician selects a version, then the working-draft option
- THEN the form shows the same content and `#editor-draft-status` shows the same status

## clinical-review-workbench (delta)

## ADDED Requirements

### Requirement: Write guards during version selection (R5)

#### Scenario: Forged write events
- GIVEN a version is selected
- WHEN `change_functional_analysis`, `save_functional_analysis`, `generate_functional_analysis_draft`, or `register_functional_analysis_version` arrives (including via `render_hook` with crafted params)
- THEN the draft row, lock version, form assigns, and version count are unchanged

#### Scenario: Late AI result
- GIVEN an AI generation result arrives while a version is selected
- THEN it never writes into the selected version view and never registers or saves

### Requirement: Selection state constraints (R8, R9)

#### Scenario: Generation running
- GIVEN AI generation is in progress
- THEN the selector is disabled and a forged select event is ignored

#### Scenario: Failed autosave
- GIVEN `@draft_status` is `:save_failed`
- WHEN a version is selected
- THEN selection succeeds

#### Scenario: After registration
- GIVEN the clinician registers a version
- THEN the new `#functional-analysis-version-option-#{id}` appears last

## Out of Scope

"Continue from this version" (#365), diffs, URL/deep-link state, cross-session PubSub refresh, access audit on successful reads (L7), forced debounce flush (L4), changes to `list_functional_analysis_versions/3`, retention, RAG, or base authorization.
