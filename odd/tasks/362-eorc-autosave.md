# Task List: Issue #362 - Autosave the E-O-R-C working draft

## Context
- Issue: #362 ([Feature]: Autosave the E-O-R-C working draft)
- Parent Spec: #361
- Branch: `feat/362-eorc-autosave`

## Tasks
- [x] Task 1: Add `lock_version` to `functional_analysis_drafts` schema and migration
  - Generate migration to add `lock_version :integer, default: 1, null: false` to `functional_analysis_drafts`.
  - Update `Alethea.ClinicalRecord.FunctionalAnalysisDraft` schema with `:lock_version`.
- [x] Task 2: Domain concurrency support in `Alethea.ClinicalRecord`
  - Update `upsert_functional_analysis_content/4` and `persist_functional_analysis_draft` to accept expected `lock_version`.
  - Enforce optimistic lock check against stored draft: return `{:error, :conflict}` on version mismatch, increment `lock_version` on successful update.
  - Return updated draft with new `lock_version`.
  - Expose draft `lock_version` in draft lookups for LiveView consumption.
- [ ] Task 3: Autosave and feedback in `TargetBehaviorLive.Review`
  - Add `phx-debounce="1000"` to E-O-R-C textarea inputs.
  - Handle `change_functional_analysis` by persisting changes automatically under current authorized professional.
  - Track `@draft_save_status` (`:empty`, `:saving`, `:saved`, `:save_failed`, `:conflict`, `:tombstoned`).
  - Update `#editor-draft-status` and `#draft-status-label` with visible "Guardando…", "Guardado", "Error al guardar", and conflict state without altering existing layout.
  - Preserve visible editable text intact on save failures and conflict for clinician retry.
  - Maintain explicit manual Save button functionality.
- [ ] Task 4: Focused Workbench and domain integration tests
  - Test autosave persists edits without explicit save and survives reload.
  - Test UI shows saving, saved, and error states, retaining text on error.
  - Test multi-tab / out-of-order race: stale lock_version returns conflict signal and does not overwrite newer edits.
  - Test existing legacy content, previous notes, citations, and authorization remain intact.
- [ ] Task 5: Verification and precommit
  - Run `mix test test/alethea_web/live/target_behavior_live/review_test.exs` and `test/alethea/clinical_record_test.exs`.
  - Run `mix precommit` and fix any issues.
