# Exploration — continue-from-version-365 (#365)

**Status:** exploration complete
**Issue:** #365 — [Feature]: Continue working from a previous E-O-R-C version
**Parent:** #361 — Spec: Versioned E-O-R-C formulation with autosaved working draft and AI revision preview
**Blocked by:** #362 (autosave), #364 (browse versions read-only) — both CLOSED and merged.

## Executive summary

#365 can be built entirely in `review.ex` with no new domain function. A "Continue from this version" button goes in the read-only version panel and asks for confirmation on the server side, only when the working form has content. Confirming re-fetches the version, copies it with `content_params/1`, returns to the working draft and sends the result through the existing autosave pipeline. Nothing in this path calls `register_functional_analysis_version`.

## Current state (file:line)

All references are in `/Users/damianfrick/Alethea/lib/alethea_web/live/target_behavior_live/review.ex`, verified on the current state after #364 was merged.

### Mount (95-173)

Gets the draft through `get_functional_analysis_draft` and maps it:
- no draft → `{%FunctionalAnalysisContent{}, nil, 0}`
- tombstone → `{empty, deleted_at, nil}`
- draft → parsed content plus `lock_version`

Then assigns:
- `draft_status` via `compute_draft_status/2` (1383): all fields blank → `:empty`, otherwise `:saved`, tombstone → `:tombstoned`
- `functional_analysis_lock_version`
- `last_saved_functional_analysis_params` = `content_params(content)` (1502)
- `autosave_seq: 0`
- `functional_analysis_form` = `to_form(params, as: "functional_analysis")`
- `selected_version: nil` and `selected_version_content: nil`

### `change_functional_analysis` (737-764)

Merges the incoming params into `functional_analysis_form_values/1` (1344; `previous_notes` plus the 11 E-O-R-C string keys) and reassigns the form. Does nothing if the draft is tombstoned or `params_equal?(merged, last_saved)`. Otherwise: `seq+1`, `send(self(), {:perform_autosave, merged, seq})`, `draft_status: :saving`.

**The debounce is client-side only** (`phx-debounce="1000"` on the textareas, around 2675). The server starts the autosave immediately, so a server event can reuse the same logic.

### `handle_info({:perform_autosave, params, seq})` (1034-1071)

Runs only when `seq == autosave_seq` and the draft is not tombstoned. Calls `upsert_functional_analysis_content(..., expected_lock_version:)`. Outcomes: ok → updates `lock_version`, `last_saved`, and status; `:conflict`; `:save_failed`.

### `save_functional_analysis` (823-864)

Saves synchronously with a flash message. It never registers a version.

### #364 guards (726-874)

`change`, `save`, `generate`, and `register` each have a first clause that matches `selected_version: %FunctionalAnalysisVersion{}` and does nothing.

### `select_functional_analysis_version`

- generation pending → no-op (890)
- `"working-draft"` → clears selection (898)
- id → `get_functional_analysis_version/4` plus `FunctionalAnalysisContent.parse/1` (905-922)
- `:unauthorized` → redirect
- other errors → flash "La versión no está disponible." plus `relist_version_summaries` (924-933)

### `#functional-analysis-version-view` (2577-2626)

Contains, in order: an `h2` "Versión N", a meta row with author and date, previous notes, 4 fieldsets from `version_view_sections()`, the change note. **It has no actions area**, so the new button is new UI. The natural spot is an actions row under the `h2`/meta row (around 2592), or at the end after the change note (2625).

`#functional-analysis-form` (2641) and `#functional-analysis-version-form` (2779) are hidden while a version is selected or the draft is tombstoned.

### Domain (`/Users/damianfrick/Alethea/lib/alethea/clinical_record.ex`)

- `get_functional_analysis_version/4` (1758) authorizes through `with_target_behavior`, records an audit on denial, and returns `:not_found`.
- Versions can be legally deleted: `Retention.legally_delete_record({"functional_analysis_version", id})`, at `retention.ex:478`.

### Content shape (`functional_analysis_content.ex:19-35`)

A struct with the 11 E-O-R-C atoms plus `previous_notes`, all defaulting to `""`. `content_params/1` produces exactly the string-keyed map the form and `upsert` expect, so copying is a direct `content_params(content)` with no transformation.

### Existing confirmation patterns

- Native `data-confirm` is used once, at `review.ex:2429` (`discard_proposal`).
- `core_components.ex:489` has a `<.modal>`, but `review.ex` never uses it.
- Server-side two-step flows already exist: `prepare`/`confirm`/`cancel_evidence_citation` (335-410, `@citation_step`) and `open`/`cancel`/`confirm_trim_candidate` (448-472).

## Affected areas

- `lib/alethea_web/live/target_behavior_live/review.ex`:
  - new events: request, confirm, and cancel the continue action
  - new assign `:continue_confirmation_pending` (initialize in mount, clear when the selection changes)
  - extract the autosave scheduling helper from `change_functional_analysis`
  - button plus inline confirmation block in the version panel
- `test/alethea_web/live/target_behavior_live/review_test.exs`: new describe block after the #364 block (1890-2216).
- No domain or schema changes.

## Approaches compared

### 1. Confirmation UX

**A. Native `data-confirm`.**
- Pros: one attribute, already used once in the codebase.
- Cons: client-side only. LiveViewTest's `render_click` skips it, so the AC5 "cancel/decline" test cannot be written. It also cannot be conditional on whether the draft has content without extra markup.
- Effort: Low.

**B. Server-side two-step with an inline confirmation block** (same shape as the citation and trim flows). — RECOMMENDED
- Pros: testable for confirm, decline, and forged events; can skip confirmation when the draft is blank; shows the consequence explicitly.
- Cons: about 3 more event clauses and one more assign.
- Effort: Low-Medium.

**C. `<.modal>` from `core_components`.**
- Pros: polished look.
- Cons: not used anywhere in `review.ex`, and it is opened by client-side JS commands.
- Effort: Medium.

### 2. Autosave trigger

**A. Send the copy through the same scheduling as `change_functional_analysis`** (`seq+1`, `send :perform_autosave`, `:saving`). — RECOMMENDED
- Pros: literally "normal autosave"; one code path; the `seq` bump cancels any autosave still in the mailbox.
- Effort: Low.

**B. Synchronous save like `save_functional_analysis`.**
- Cons: second write path, flash noise, not "normal autosave".

### 3. Authorization

**A. Trust `@selected_version_content`.**
- Cons: there can be a gap of minutes between viewing and copying, and versions really can be legally deleted, so this would copy deleted clinical text.

**B. Re-fetch with `get_functional_analysis_version/4` when the copy is confirmed.** — RECOMMENDED
- Pros: closes the race; reuses the same error branches as select.
- Cost: one query.

## Recommendation

Use 1B, 2A, and 3B.

- **Request event:**
  - Not allowed (generation pending, draft tombstoned, or no selection) → no-op.
  - Allowed and the working form values are all blank → apply immediately.
  - Allowed and the form has content → set `:continue_confirmation_pending` and show an inline warning that the current draft will be replaced, with confirm and cancel buttons.
  - "Current work" means any non-blank value in `functional_analysis_form_values` (saved or unsaved).
- **Confirm event:**
  1. Re-fetch the version (`:unauthorized` → redirect; other errors → flash plus relist).
  2. Set the form to `content_params(parsed)`.
  3. Set `selected_version` and `selected_version_content` to nil, and clear the pending confirmation.
  4. Call the shared autosave helper. If the copied content equals `last_saved`, nothing is saved.
- **Cancel event:** clears the pending confirmation and changes nothing else.
- Also clear the pending confirmation in every `select_functional_analysis_version` clause.

## Risks

1. If `draft_status` is `:conflict`, the copy's autosave reuses the stale `lock_version` and hits `:conflict` again. Decide whether to block the copy or let the conflict state show.
2. If the helper is not shared, an older `perform_autosave` still in the mailbox could overwrite the copied content. Bumping `seq` is mandatory.
3. With `data-confirm`, AC5's decline test would not be testable.
4. Hiding the button on a tombstoned draft is not enough. The server must also block forged events, because `perform_autosave` would otherwise attempt an `upsert` that the domain rejects (`denied_tombstone`).
5. After the copy, `selected_version` must be cleared, otherwise the #364 guards make the form invisible and all autosaves no-ops.

## Test conventions (review_test.exs 1890-2216)

- Setup: `persist_draft!` + `ClinicalRecord.register_functional_analysis_version` + `live(conn, review_path(...))`.
- Interaction: `element("#functional-analysis-version-option-#{id}") |> render_click()`; forged events via `render_hook` / `render_change`; `_ = :sys.get_state(view.pid)` to flush `perform_autosave`; `:sys.replace_state` to force a `draft_status`.
- Assertions: `ClinicalRecord.get_functional_analysis_content` before and after; `version_count()`; `Retention.legally_delete_record` for the deletion race; helpers `eorc_params(marker)` and `field_view_id/1`.
- Reload (AC5): open a second `live/2` and check that `get_functional_analysis_version` still returns the original body.

## Key learnings

1. The review LiveView autosave debounce is client-side only (`phx-debounce="1000"`), so a server event can schedule `perform_autosave` directly.
2. `content_params/1` turns a `FunctionalAnalysisContent` struct into the exact string-keyed map that the functional analysis form and upsert expect.
3. Functional analysis versions can be legally deleted through `Retention.legally_delete_record`, so a version shown on screen may already be gone at copy time.
4. LiveViewTest `render_click` ignores `data-confirm`, so declining a native confirmation cannot be tested server-side.
5. `review.ex` already has server-side two-step confirmation flows: `prepare`/`confirm`/`cancel_evidence_citation` and `open`/`cancel`/`confirm_trim_candidate`.
