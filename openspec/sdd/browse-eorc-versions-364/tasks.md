# Tasks: Browse registered E-O-R-C versions read-only (#364)

## Review Workload Forecast

| Field | Value |
|---|---|
| Estimated changed lines | PR1 ~385 / PR2 ~60 / Total ~445 (design: 335/155/490, re-split below) |
| 400-line budget risk | PR1: High (~96% before the usual 15-90% apply overrun) · PR2: Low |
| Chained PRs recommended | Yes |
| Suggested split | PR1 (base: `main`) → PR2 (base: PR1 branch) |
| Delivery strategy | ask-on-risk (resolved: feature-branch-chain, #316/#317/#328 precedent) |
| Chain strategy | feature-branch-chain |
| Branches | `feat/364-browse-eorc-versions` → `feat/364-browse-eorc-versions-pr2` |

Decision needed before apply: No
Chained PRs recommended: Yes
Chain strategy: feature-branch-chain
400-line budget risk: High

**Sequencing resolution (AC2).** In design.md's split, PR1 ships the selector while the 4 write handlers stay unguarded until PR2. Design calls this an "AC2 gap" and keeps it off `main` with a tracker branch. The #316/#317/#328 precedent has PR1 target `main` and stand alone, and AC2 applies as soon as the selector reaches `main`. So this plan moves the 4 guard clauses (~8 prod lines), select clause 1 (pending no-op, L5) and their table-driven RED tests into PR1. Strict TDD does not allow guards to ship untested, so a tests-only PR2 was rejected. To pay for this, CSS and the re-list after registration (R9, a refresh gap rather than a safety gap) move to PR2. PR1 is safe to merge on its own. Until PR2 lands, a newly registered version shows up only after a remount.

### Suggested Work Units

| Unit | Goal | PR | Focused test command | Harness | Rollback boundary |
|---|---|---|---|---|---|
| 1 | Summaries fn, mount load, select/return event (3 clauses), 4 guards, panel, selector, `:if` gates, helpers | PR1 (base `main`) | `mix test test/alethea/clinical_record/functional_analysis_version_test.exs test/alethea_web/live/target_behavior_live/review_test.exs` | `mix phx.server` → Workbench with 2+ versions: select, read, return | Revert `clinical_record.ex` + `review.ex` + 2 test files; no migration |
| 2 | Re-list after own registration, CSS | PR2 (base PR1 branch) | `mix test test/alethea_web/live/target_behavior_live/review_test.exs` | `mix phx.server` → register → new option last; note `pre-wrap` | Revert `review.ex` success-branch line + `editorial.css` + test |

---

## Phase 0 — Branch setup

- [ ] 0.1 `git fetch origin && git switch -c feat/364-browse-eorc-versions origin/main`. Never branch from a stale local checkout.
- [ ] 0.2 Re-read the anchors in design.md's "Anchor verification" table on this branch (base 7b2e800). Re-grep any that drifted. Never hardcode line numbers.

## PR1 — base `main`, branch `feat/364-browse-eorc-versions`

### Phase 1 — Domain summaries (R1, R2, R7, AD1)

- [ ] 1.1 RED in `test/alethea/clinical_record/functional_analysis_version_test.exs`:
  - Shape: `body == nil`, `encrypted_body == nil`, `change_note` decrypted, `professional` preloaded.
  - Order is `version_number` ascending, including the gap after `Retention.legally_delete_record({"functional_analysis_version", id}, …)`: listing 1, 2 and 4.
- [ ] 1.2 RED, one table-driven test: another professional → `{:error, :unauthorized}`; a cross-patient target → `{:error, :not_found}`. Both must match what `list_functional_analysis_versions/3` returns (trim lever).
- [ ] 1.3 GREEN in `lib/alethea/clinical_record.ex` after `:1699`: add `@spec list_functional_analysis_version_summaries/3`.
  - Use `with_target_behavior/4` (`:306-314`) and the same where/`order_by(asc: :version_number)`/`preload(:professional)` as `list/3`.
  - `select struct(v, [:id, :version_number, :encryption_version, :encrypted_change_note, :professional_id, :target_behavior_id, :patient_id, :inserted_at])`.
  - Then `Enum.map(&decrypt_functional_analysis_version_note(&1, keyring))`.
- [ ] 1.4 GREEN: add `defp decrypt_functional_analysis_version_note/2`, which sets `change_note` via `decrypt_or_placeholder(encrypted_change_note, dek_for(version, keyring))` (`:1948-1951`, `:375-376`). Leave `list/3` untouched.

### Phase 2 — LiveView tests, RED (R3, R4, R5, R6, R8, R7)

Add these to a new describe block, "read-only E-O-R-C version browsing (GitHub #364)", in `review_test.exs`. Reuse `review_path/2`, `persist_draft!/4`, `register_version/2` and `version_count/0` (`:1866-1887`).

- [ ] 2.1 Selector (one test, two setups):
  - With 0 versions → `#functional-analysis-version-selector` shows only `#functional-analysis-working-draft-option`, with `aria-pressed="true"` (AD7).
  - With versions 1, 2, 4 → working-draft first, then the version options oldest-first. Labels read "Versión N · dd/mm/YYYY HH:MM · full_name · note", with no "N of M".
- [ ] 2.2 Open: click `#functional-analysis-version-option-#{id}`.
  - `#functional-analysis-version-view` shows the 11 `functional-analysis-version-view-<field>` ids, author, date, the full `#…-change-note` and the previous notes. All values match the stored content and none is an input.
  - `#functional-analysis-form`, `#functional-analysis-version-form` and `#generate-functional-analysis-draft` are absent.
- [ ] 2.3 Return (R6, L6): `render_change` an unsaved edit, then select a version, then select working-draft.
  - Form content and `#editor-draft-status` are unchanged.
  - Table-drive this over `:saved`/`:save_failed`/`:conflict`. Force the status with `:sys.replace_state` (pattern `:1715-1717`).
- [ ] 2.4 Failed selection (AD5): delete the version legally after mount, then select it.
  - Flash "La versión no está disponible.", no protected text, working form present, option gone.
- [ ] 2.5 Forged writes (AD3), table-driven over 4 events while a version is selected:
  - `render_change "change_functional_analysis"`.
  - `render_hook` save, register and generate (pattern `:1828-1831`).
  - Each leaves the `get_functional_analysis_content` draft, the lock version and `version_count()` unchanged, with `draft_generation_pending` false.
- [ ] 2.6 Pending (L5, late AI result): `:sys.replace_state` sets `draft_generation_pending: true`, then a forged select → no panel. The option renders `disabled`.

### Phase 3 — LiveView GREEN (`lib/alethea_web/live/target_behavior_live/review.ex`)

- [ ] 3.1 Add `alias Alethea.ClinicalRecord.FunctionalAnalysisVersion`. In the mount assign block (`:90-147`; there is no `handle_params`), assign:
  - `:version_summaries` (an error yields `[]`).
  - `:selected_version` and `:selected_version_content`, both `nil`.
- [ ] 3.2 Add the `select_functional_analysis_version` clauses in this order:
  - (1) `draft_generation_pending: true` → no-op.
  - (2) `"working-draft"` → both selected assigns become `nil`.
  - (3) `id` → `get_functional_analysis_version/4`, with three outcomes:
    - `{:ok, v}`: assign the version plus `FunctionalAnalysisContent.parse/1`.
    - `:unauthorized`: `redirect_to_patients`.
    - Any other error: `nil`, flash, then re-list. A re-list that fails with `:unauthorized|:not_found` → redirect.
- [ ] 3.3 Add one guard clause, `%{assigns: %{selected_version: %FunctionalAnalysisVersion{}}}` → `{:noreply, socket}`, immediately before each of these existing clauses:
  - `change_functional_analysis` (`:689`).
  - `generate_…` (`:719`).
  - `save_…` (`:755`).
  - `register_…` (`:799`).
  - Do NOT guard `handle_info(:perform_autosave)` or `handle_async` (AD4).
- [ ] 3.4 Add helpers:
  - `version_option_label/1`, using `format_datetime/1` (`:1448-1452`).
  - Author = `full_name || email` (precedent `clinical_note_live/index.ex:176`).
  - `truncate_note/1`: more than 60 graphemes → `String.slice(note, 0, 57) <> "…"`.
  - `@version_view_sections`, mirroring the labels at `:2398-2497`.
- [ ] 3.5 Template, after `#draft-tombstone`: add the selector. It is never `:if`-gated (AD7). It uses the `filter-pill` and `aria-pressed` pattern (`:1869-1882`), and each option sets `disabled={@draft_generation_pending}`.
- [ ] 3.6 Template: `<section :if={@selected_version} id="functional-analysis-version-view">` with plain-text `<div>`s only (AD2).
- [ ] 3.7 Append `and is_nil(@selected_version)` to the `:if` on these 4 elements (the status chip stays):
  - Generate button (`:2337`).
  - `#empty-draft` (`:2360`).
  - `#functional-analysis-form` (`:2373`).
  - `#functional-analysis-version-form` (`:2511`).

### Phase 4 — PR1 verification

- [ ] 4.1 Run the Unit 1 command, then `mix compile --warnings-as-errors --force`, `mix format --check-formatted` and `mix precommit`.
- [ ] 4.2 Budget check: run `git diff --stat origin/main -- lib test`. If over 400, apply the trim levers first:
  - Merge 2.1's two setups.
  - Fold 2.6 into 2.5's table.
  - Collapse the 1.1 shape and order checks into one test.
  - Only then flag `size:exception` to the orchestrator. Never self-authorize it.
- [ ] 4.3 Confirm the diff has no `editorial.css` and no `list/3` change.

## PR2 — base `feat/364-browse-eorc-versions`, branch `feat/364-browse-eorc-versions-pr2`

- [ ] 5.0 `git switch -c feat/364-browse-eorc-versions-pr2 feat/364-browse-eorc-versions`.
- [ ] 5.1 RED (R9): `register_version/2` → the new `#functional-analysis-version-option-#{id}` renders last.
- [ ] 5.2 GREEN: in the `register_functional_analysis_version/2` success branch (`:1273-1277`), add the `assign(:version_summaries, …)` re-list.
- [ ] 5.3 In `priv/static/assets/css/editorial.css`:
  - Add the selector layout (wrap/gap next to `.filter-pill` `:2936-2967`).
  - Add `.functional-analysis-version-view__value { white-space: pre-wrap }`.
- [ ] 5.4 Run the Unit 2 command plus compile/format. Run `git diff --stat feat/364-browse-eorc-versions`: the PR1 files must not appear, and the diff must stay at or under 400.
