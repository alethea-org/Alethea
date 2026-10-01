# Exploration — browse-eorc-versions-364 (#364)

**Status:** exploration complete
**Issue:** #364 — [Feature]: Browse registered E-O-R-C versions read-only
**Parent:** #361 — Spec: Versioned E-O-R-C formulation with autosaved working draft and AI revision preview
**Blocked by:** #363 (register immutable version) — CLOSED, merged.

## Executive summary

The backend for #364 is already done. #363 shipped the `FunctionalAnalysisVersion` schema, numbering, the immutability trigger, `list_functional_analysis_versions/3` and `get_functional_analysis_version/4`, both behind the same authorization check (`with_target_behavior/4`). Legal deletion and RAG exclusion already cover versions. So #364 is mostly LiveView work, plus at most one small backend tweak. Recommendation: a separate read-only panel for the selected version, swapped in for the working form rather than editing it, with server-side guards on every write event while a version is shown.

## Current state (file:line)

### 1. What #363 shipped

**Schema:** `lib/alethea/clinical_record/functional_analysis_version.ex:14-28`. Fields:
- `version_number` (per behavior, >0)
- `inserted_at` (utc_datetime, no `updated_at`)
- `professional_id`, used as the author (`Professional.full_name`)
- `encrypted_body` and `encrypted_change_note`, decrypted into virtual `body` / `change_note`
- `encryption_version`, plus `draft_id`, `patient_id`, `target_behavior_id`

**Migration:** `priv/repo/migrations/20260930164207_create_functional_analysis_versions.exs`
- Unique index on `(target_behavior_id, version_number)`.
- Two composite foreign keys checking the version's patient matches its draft and target behavior (both cascade on delete).
- A BEFORE UPDATE trigger, `functional_analysis_versions_no_update`, rejects every update. DELETE is allowed.

**Numbering:** `priv/repo/migrations/20260930175713_add_functional_analysis_version_sequence_to_target_behaviors.exs` adds `target_behaviors.functional_analysis_version_sequence`, incremented at `clinical_record.ex:1666-1678`.
- Numbers are never reused. Gaps can appear after a legal deletion (tested in `functional_analysis_version_test.exs:224`).
- The "ordered identifier" the issue asks for therefore already exists as `version_number` — nothing needs deriving.

**Context functions** in `lib/alethea/clinical_record.ex`:
- `register_functional_analysis_version/5` (1512-1573). Args: professional, patient_id, target_behavior_id, expected_lock_version, note. Uses `with_target_behavior/4`, then a row lock, then a check that the draft is not legally deleted.
- `list_functional_analysis_versions/3` (1680-1699). Uses `with_target_behavior/4`, orders by `version_number` ascending, preloads `:professional`, and **decrypts body and note for every row**.
- `get_functional_analysis_version/4` (1701-1735). Uses `with_target_behavior/4` and fetches scoped to patient and behavior. A miss returns `{:error, :not_found}` and writes a "denied" audit row. It does **not** check whether the version was legally deleted.
- Decryption failure shows the placeholder text `"[Error al descifrar]"` (1948).

**Access-denial tests:** `functional_analysis_version_test.exs:150`, `:413`.

### 2. Autosave from #362 (`lib/alethea_web/live/target_behavior_live/review.ex`)

- Edits go through `change_functional_analysis` (689-716), which merges into `@functional_analysis_form`, bumps `@autosave_seq`, and calls `send(self(), {:perform_autosave, ...})`.
- `handle_info` (908-945) saves with the expected lock version.
- `@draft_status` is one of `:empty | :saving | :saved | :save_failed | :conflict | :tombstoned`. It is shown in `#editor-draft-status` (2348) and a stat tile (1555).
- Textareas use `phx-debounce="1000"`.
- Working-draft state lives entirely in server-side assigns: `@functional_analysis_form`, `@last_saved_functional_analysis_params`, `@functional_analysis_lock_version`, `@draft_status`.

### 3. Workbench UI today

The editor is in `<aside id="workbench-editor-panel">` (2327-2537):
- generate button `#generate-functional-analysis-draft`
- status chip
- `#draft-tombstone`
- `#functional-analysis-form` with hidden previous_notes, the `#previous-notes` section, and 11 textareas with ids `functional-analysis-<section>-<field>`
- `#save-functional-analysis`
- #363's `#functional-analysis-version-form`, `#functional-analysis-version-note`, `#register-functional-analysis-version`

**There is no version list, selector, or link at all — #364 is the first browsing UI.** After a successful registration the page only flashes "Versión N registrada." (1273-1277). Nothing refreshes a list. There is no `handle_params`.

### 4. Read-only mechanics

Nothing in the editor is read-only or disabled today. The only `disabled=` uses are on the generate/suggest buttons (1481, 1679, 2341). `core_components.ex:159-161` `input/1` accepts `readonly` and `disabled` through its global attrs, so readonly textareas are possible.

**Risk:** `handle_async(:functional_analysis_draft, ...)` (811-849) writes generated AI text into `@functional_analysis_form`. A historical view must not share that assign.

### 5. Authorization and legal deletion

The read path uses the same `with_patient/3` → `with_target_behavior/4` checks (255-314).

Retention already covers the version table:
- `identifiers_for` includes `FunctionalAnalysisVersion` (`retention.ex:382-399`).
- Sweep deletion is deferred while versions exist (412-426, 462).
- Manual deletion of a draft or target behavior legally deletes each version first (465-486).
- `Tombstone` lists `functional_analysis_version` as a resource type (`tombstone.ex:20-22`).
- Tests: `retention_test.exs:400-622`.

**So there is no Retention gap (unlike #317's F1).**

Small gap: `get_functional_analysis_version/4` cannot tell "legally deleted" from "never existed / other patient". It returns `:not_found` and writes a "denied" audit row for a version that was legally deleted. `Tombstone.for_resource/2` is available to distinguish the two if wanted.

### 6. RAG exclusion

Already true by construction. `Indexer.eligibility("functional_analysis_version_registered")` falls through to `{:unknown, _}`, which is acknowledged without creating a chunk (`indexer.ex:101, 382`). This is pinned by `test/alethea/clinical_record/rag/indexer_test.exs:65-66`. `mix alethea.rag.reindex` has no version kind (`lib/mix/tasks/alethea.rag.reindex.ex:134`).

### 7. Test ID conventions

`review_test.exs:1578-1888` (the #363 describe block) uses a module attribute for the form selector, `has_element?(view, "#id", "text")`, `render_change` + `:sys.get_state`, `render_hook` for forged events, and `:sys.replace_state` to force a status. Element ids are kebab-case with a `functional-analysis-*` prefix. Per-item ids follow the `prefix-#{id}` pattern.

### 8. Ordered identifier

`version_number` already exists (see §1). Nothing needs deriving.

## Approaches compared

### 1. Separate read-only panel, swapped in for the working form (`:if`) — RECOMMENDED

New `@selected_version` assign. When it is set, render `#functional-analysis-version-view` with readonly fields from the fetched version, and hide `#functional-analysis-form`, the register form, and the generate button. The working form assigns are never touched.

- **Pros:** the working draft cannot be corrupted; AI completion cannot paint over the version; tests are simple.
- **Cons:** the form's DOM is unmounted, so keystrokes still inside the 1000ms debounce window depend on LiveView flushing them on blur (needs verifying); a second markup block for the fields.
- **Effort:** Medium.

### 2. Same form with `readonly`/`disabled`, values swapped to the version's

- **Pros:** no duplicated markup.
- **Cons:** mixes historical values into the editable form assign; risk of autosaving historical content into the draft; `handle_async` collision; restoring the draft needs a stash.
- **Effort:** Medium. Riskier.

### 3. Keep the working form in the DOM but hidden (`hidden` attribute), plus a separate read-only panel

- **Pros:** unsent DOM text survives.
- **Cons:** `has_element?` still finds hidden elements, so tests must assert `[hidden]`; forged events are still possible (server guards needed anyway).
- **Effort:** Medium.

## Recommendation

Approach 1, with these parts:
- Selector `#functional-analysis-version-selector`, containing:
  - `#functional-analysis-working-draft-option`
  - `#functional-analysis-version-option-#{version.id}` items, labelled "Versión N · dd/mm/yyyy HH:MM · full_name · note"
- Panel `#functional-analysis-version-view`, with readonly field ids such as `functional-analysis-version-view-antecedents-distal`, plus a `previous_notes` block.
- Fetch the selected version fresh through `get_functional_analysis_version/4` on every selection, so legal deletion is honoured. Parse it with `FunctionalAnalysisContent.parse/1`.
- Server-side guards make every write event a no-op (or flash) while `@selected_version` is set.
- Re-list after a successful registration.
- Load the selector from metadata only, or drop bodies after listing.
- Optionally return `:legally_deleted` from `get_functional_analysis_version/4` through `Tombstone.for_resource/2`.
- No "continue from this version" button — that is #365.

## Affected areas

- `lib/alethea_web/live/target_behavior_live/review.ex`. New assigns: version list and selected version. New events: select version and return to working draft. Guards on `change_functional_analysis`, `save_functional_analysis`, `generate_functional_analysis_draft`, `register_functional_analysis_version`, and `handle_async` while a version is selected. Refresh the list after registration. Template: selector plus read-only panel.
- `lib/alethea/clinical_record.ex`. Optional: a metadata-only listing so the page doesn't decrypt every body at mount, and/or a legal-deletion check in `get_functional_analysis_version/4`.
- `test/alethea_web/live/target_behavior_live/review_test.exs`. A new describe block for #364.
- Possibly `test/alethea/clinical_record/functional_analysis_version_test.exs`, if the context changes.
- Possibly CSS for the selector and panel.

## Risks

1. Debounced keystrokes not yet sent (up to 1s) when the user clicks the selector. Need to confirm LiveView flushes `phx-debounce` on blur, or keep the form mounted.
2. `list_functional_analysis_versions/3` decrypts every body and holds all of them as plaintext in socket memory. Prefer metadata-only listing and fetching the body on selection.
3. Version lists shown in other open sessions go stale; no PubSub event exists for registration. A deleted version shows up as a `:not_found` flash when selected.
4. A selected version that was legally deleted currently logs a "denied" audit row, which is misleading.
5. Version numbers can have gaps after a legal deletion. Labels must not imply a contiguous sequence.
6. `handle_async` for AI generation must not write while a version is shown, or it must write only into the working form assign, which stays hidden.

## Key learnings

1. #363 already shipped `list_functional_analysis_versions/3` and `get_functional_analysis_version/4`, both behind `with_target_behavior/4`, so #364 needs no new authorization layer.
2. `FunctionalAnalysisVersion.version_number` is a per-behavior number driven by `target_behaviors.functional_analysis_version_sequence`; it is never reused, but gaps can appear after legal deletion.
3. Retention already registers, defers, and tombstones `functional_analysis_version` rows, so there is no #317-style gap.
4. RAG excludes versions by construction: the `functional_analysis_version_registered` event is treated as `{:unknown, _}` and no chunk is created, pinned in `indexer_test.exs:65`.
5. The Workbench has no version-browsing UI at all today — #363 added only the register form with ids `functional-analysis-version-form`, `functional-analysis-version-note`, and `register-functional-analysis-version`.
