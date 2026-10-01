# Design: Browse registered E-O-R-C versions read-only (#364)

**Inputs:** proposal.md (L1–L7, Q1 locked), exploration.md · **Base:** `main` @ 7b2e800 (all anchors below re-read on this commit)

## Anchor verification (exploration → real)

| Anchor | Exploration | Real |
|---|---|---|
| `list_functional_analysis_versions/3` | 1680-1699 | `clinical_record.ex:1680-1699` (def :1683) |
| `get_functional_analysis_version/4` | 1701-1735 | `:1701-1735`; miss → `log_denied_audit` + `{:error, :not_found}` :1724-1733 |
| `decrypt_functional_analysis_version/2` | — | `:1737-1743` (decrypts body + note) |
| `dek_for/2` | — | `:375-376` (needs `encryption_version`) |
| `decrypt_or_placeholder/2` | 1948 | `:1948-1951` |
| `with_target_behavior/4` | 255-314 | `:306-314` |
| Schema fields | 14-28 | `functional_analysis_version.ex:14-28`; `body`/`change_note` virtual, `redact: true` (:19-20) |
| `Professional.full_name` | — | **field**, not a function: `lib/alethea/accounts/professional.ex:11` (required, :27) |
| `mount` assign block | — | `review.ex:90-147`; **no `handle_params`** (confirmed) |
| `change_functional_analysis` | 689-716 | `:689-716` |
| `generate_functional_analysis_draft` | — | `:719-752` |
| `save_functional_analysis` | — | `:755-796` |
| `register_functional_analysis_version` (event) | — | `:799-808`; private worker `:1265-1309`, success flash `:1277` |
| `handle_async(:functional_analysis_draft, …)` | 811-849 | `:811-878` (4 clauses) |
| `handle_info({:perform_autosave, …})` | 908-945 | `:908-945` |
| `format_datetime/1` (`"%d/%m/%Y %H:%M"`) | — | `:1448-1452` |
| `<aside id="workbench-editor-panel">` | 2327-2537 | `:2327-2537`; generate btn `:2336-2347`, chip `:2348`, form `:2372-2508`, version form `:2510-2535` |
| Pill precedent (`aria-pressed`) | — | `review.ex:1869-1882`, `.filter-pill` `editorial.css:2936-2967` |
| #363 describe / forged `render_hook` | 1578-1888 | `review_test.exs:1578-1888`, forged hook `:1828-1831`, `:sys.replace_state` `:1715-1717` |

## Technical Approach

Approach 1 (L1): a separate read-only panel swapped in by `:if` for the working form, register form, generate button and empty-draft block. Working-draft assigns (`functional_analysis_form`, `last_saved_functional_analysis_params`, `functional_analysis_lock_version`, `draft_status`, `autosave_seq`) are never read or written by the browsing path. Write handlers get pattern-matched no-op clauses while a version is selected.

## Interfaces / Contracts

**Domain** (`clinical_record.ex`, after :1699):

```elixir
@spec list_functional_analysis_version_summaries(Professional.t(), Ecto.UUID.t(), Ecto.UUID.t()) ::
        {:ok, [FunctionalAnalysisVersion.t()]} | {:error, term()}
# with_target_behavior/4; same where/order_by(asc: version_number)/preload(:professional) as list/3, plus
|> select([v], struct(v, [:id, :version_number, :encryption_version, :encrypted_change_note,
                          :professional_id, :target_behavior_id, :patient_id, :inserted_at]))
# then Enum.map(&decrypt_functional_analysis_version_note(&1, keyring))
defp decrypt_functional_analysis_version_note(version, keyring),
  do: %{version | change_note: decrypt_or_placeholder(version.encrypted_change_note, dek_for(version, keyring))}
```

Returned structs have `body: nil` and `encrypted_body: nil` (never loaded).

**LiveView** (`review.ex`):
- `alias Alethea.ClinicalRecord.FunctionalAnalysisVersion`.
- Mount (:90-147): `assign(:version_summaries, load_version_summaries(...))` (error → `[]`; mount already authorized), `assign(:selected_version, nil)`, `assign(:selected_version_content, nil)`.
- `@selected_version :: nil | %FunctionalAnalysisVersion{}` (fresh from `get/4`); `@selected_version_content :: nil | %FunctionalAnalysisContent{}` via `FunctionalAnalysisContent.parse/1` (placeholder body → `{:legacy, _}` → shown in previous notes).
- Event `select_functional_analysis_version`, three clauses placed with other `handle_event/3`s:
  1. `_params, %{assigns: %{draft_generation_pending: true}}` → `{:noreply, socket}` (L5).
  2. `%{"id" => "working-draft"}` → assign both selected assigns `nil`.
  3. `%{"id" => id}` → `get_functional_analysis_version/4`: `{:ok, v}` → assign v + parsed content; `{:error, :unauthorized}` → `redirect_to_patients(socket, :unauthorized)`; `{:error, _}` → `selected_version: nil`, flash `:error` "La versión no está disponible.", re-list (re-list `{:error, :unauthorized|:not_found}` → `redirect_to_patients`).
- Guard clauses, each inserted immediately **before** its existing clause:
  `def handle_event(name, _params, %{assigns: %{selected_version: %FunctionalAnalysisVersion{}}} = socket), do: {:noreply, socket}` for `"change_functional_analysis"`, `"save_functional_analysis"`, `"generate_functional_analysis_draft"`, `"register_functional_analysis_version"`.
- `register_functional_analysis_version/2` success branch (:1273-1277): add `assign(:version_summaries, …)` re-list.
- Helpers: `version_option_label/1` → `"Versión #{n} · #{format_datetime(inserted_at)} · #{author} · #{truncate_note(note)}"`; `author = p.full_name || p.email` (precedent `clinical_note_live/index.ex:176`); `truncate_note/1` → >60 graphemes ⇒ `String.slice(note, 0, 57) <> "…"`; `@version_view_sections` attribute (section, legend, `[{field, label}]`) mirroring :2398-2497 labels.

**Template** (inside `.review-draft`, after `#draft-tombstone`):
- `<div id="functional-analysis-version-selector" role="group" aria-label="Versiones registradas">` (AD7: always rendered, never `:if`-gated on `@version_summaries`): button `#functional-analysis-working-draft-option` ("Borrador de trabajo", `phx-value-id="working-draft"`, `aria-pressed={is_nil(@selected_version)}`) pinned first, then `:for` oldest-first buttons `id={"functional-analysis-version-option-#{v.id}"}`, `phx-click="select_functional_analysis_version"`, `phx-value-id={v.id}`, `disabled={@draft_generation_pending}`, `aria-pressed`, `filter-pill` classes. With `@version_summaries == []` the `:for` yields nothing and only the working-draft option (pre-selected) renders.
- `<section :if={@selected_version} id="functional-analysis-version-view">`: heading "Versión N", author, `format_datetime`, full note `#functional-analysis-version-view-change-note`, optional `#functional-analysis-version-view-previous-notes`, then `functional-analysis-section` fieldsets with `<div id={"functional-analysis-version-view-#{String.replace(field, "_", "-")}"}>` (plain text, no inputs).
- Add `and is_nil(@selected_version)` to `:if` of generate button (:2337), `#empty-draft` (:2360), `#functional-analysis-form` (:2373), `#functional-analysis-version-form` (:2511). Status chip stays (it describes the working draft).

## Architecture Decisions

| # | Decision | Rejected | Why |
|---|---|---|---|
| AD1 | Reuse `FunctionalAnalysisVersion` struct; `select struct(...)` excludes `encrypted_body` | New struct/plain map; flag on `list/3` | Same type as `get/4`, `Inspect` redaction kept; body ciphertext never enters socket memory. A boolean flag muddies `list/3` (out of scope); a 3-line note helper reuses `dek_for` + `decrypt_or_placeholder` |
| AD2 | Separate panel via `:if`, plain-text `<div>`s | `readonly` inputs | No form/phx-change in the panel ⇒ no write path exists to guard (L1) |
| AD3 | Guarded handlers **silently no-op** | Flash | Controls are unmounted while viewing, so only forged/stale events reach them; AC2 mandates no write, not feedback; flash would leak noise into a read-only view |
| AD4 | `handle_info({:perform_autosave,…})` and `handle_async(:functional_analysis_draft,…)` are **not** guarded | Guard them | Autosave `send/2` (:709) is queued behind an already-received select click; dropping it would lose the pre-selection edit (AC3). Async cannot overlap selection: selector disabled + clause 1 rejects selection while `draft_generation_pending` |
| AD5 | Failed selection → flash + stay on working draft + re-list | Error marker panel | No third mode; stale entry disappears (L3, generic text). Audit "denied" row on legally-deleted version is accepted (L3) |
| AD6 | One event, `"working-draft"` sentinel | Two events | Uniform pill list; UUID ids cannot collide |
| AD7 | Selector always renders, even with zero versions (shows only the working-draft option, pre-selected) | Hiding the selector entirely when `@version_summaries == []` | Spec's "No versions" scenario requires `#functional-analysis-version-selector` to render with just `#functional-analysis-working-draft-option` present and selected — this is how the clinician sees "no history yet" distinctly from "not loaded". Corrected after orchestrator reconciliation against spec.md |
| AD8 | L4 confirmed from source | Forced flush | `deps/phoenix_live_view/assets/js/phoenix_live_view/dom.js:367-375` binds `blur` on numeric-debounced inputs to `triggerCycle` (immediate send). Browser order mousedown→blur→click puts the change push before the click on the same channel. Not provable in LiveViewTest (no JS) |

## Data Flow

    mount ─→ list_..._summaries ─→ @version_summaries ─→ selector
    click option ─→ get_functional_analysis_version/4 ─→ parse ─→ @selected_version(+content) ─→ panel
                                   └ :not_found ─→ flash + re-list
    "working-draft" ─→ nil ─→ working form re-renders from untouched assigns
    register ok ─→ re-list

## File Changes

| File | Action |
|---|---|
| `lib/alethea/clinical_record.ex` | Modify: summaries fn + note helper |
| `lib/alethea_web/live/target_behavior_live/review.ex` | Modify: alias, assigns, events, guards, helpers, template |
| `priv/static/assets/css/editorial.css` | Modify: selector layout, `.functional-analysis-version-view__value { white-space: pre-wrap }` |
| `test/alethea/clinical_record/functional_analysis_version_test.exs` | Modify |
| `test/alethea_web/live/target_behavior_live/review_test.exs` | Modify: new describe "read-only E-O-R-C version browsing (GitHub #364)"; reuse `review_path/2`, `persist_draft!/4`, `register_version/2`, `version_count/0` (:1866-1887) |

## Testing Strategy

| Layer | Tests |
|---|---|
| Domain | Summaries: `body == nil` and `encrypted_body == nil`, note decrypted; oldest-first incl. gap after legal deletion; other professional → `{:error, :unauthorized}`; cross-patient target → `{:error, :not_found}` |
| LiveView | Selector lists labels oldest-first, working-draft first; selecting renders all 11 view fields + full note/author/date matching stored content; `#functional-analysis-form`, `#functional-analysis-version-form`, `#generate-functional-analysis-draft` absent; return restores unsaved edit (`render_change` + `:sys.get_state`) and same `#editor-draft-status`, incl. `:save_failed`/`:conflict` (L6) |
| Forged | While selected: `render_change(view, "change_functional_analysis", …)`, `render_hook` for save/register/generate (pattern `:1828-1831`) ⇒ draft unchanged via `get_functional_analysis_content`, `version_count()` unchanged, `draft_generation_pending` false; `:sys.replace_state` pending=true then select ⇒ no panel |
| Lifecycle | Re-list after own registration; legally deleted version (`Retention.legally_delete_record({"functional_analysis_version", id}, …)`) ⇒ flash, working form shown, option gone |

## Threat Matrix

N/A — no routing, shell, subprocess, VCS/PR automation, executable-file classification, or process-integration boundary.

## Migration / Rollout

No migration. Additive read function.

## Review Workload Forecast

| Slice | Prod | Tests | Total |
|---|---|---|---|
| PR1: summaries fn, mount load, selector, select/return, panel, failed-selection re-list, CSS | ~185 | ~150 | ~335 |
| PR2: 4 guard clauses, pending-select clause, re-list after registration | ~25 | ~130 | ~155 |

~490 total ⇒ **400-line budget risk: High**; a single PR would need `size:exception`. Chained recommended (PR1 → feature branch keeps the AC2 gap off `main`). Precedent: #328 PR2 UI landed at 358.

## Open Questions — RESOLVED by orchestrator reconciliation

- [x] AD7 corrected: selector always renders (see above); spec's "No versions" scenario requires this.
- [x] AD5 (flash on failed selection) is compatible with spec's "a generic not-available message shows" wording — no change needed.
