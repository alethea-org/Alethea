# Design: Continue working from a previous E-O-R-C version (#365)

**Inputs:** proposal.md (L1–L7, Q2 copy locked), exploration.md · **Base:** working tree @ 6230855 (#363/#364 merged). Every anchor below was re-read on that tree.

## Anchor verification (exploration → real)

| Anchor | Exploration | Real (`review.ex` unless noted) |
|---|---|---|
| mount assigns | 95-173 | `:122-173`; `autosave_seq` :136, `selected_version(_content)` :172-173 |
| `change_functional_analysis` | 737-764 | guard :727-734, body :737-764 (seq/send/:saving at :755-762) |
| `generate_…` guard / body | — | :767-774 / :777-810 (`draft_generation_pending: true` only at :795) |
| `register_…` event | — | guard :867-874, body :877-886 |
| `select_functional_analysis_version` | 890/898/905 | :889-896 (pending), :898-903 (working-draft), :905-934 (id; error branch :927-932) |
| `handle_info({:perform_autosave,…})` | 1034-1071 | :1034-1071 (`seq ==` + tombstone gate :1035) |
| `relist_version_summaries/1` | — | :1135-1149 (returns `{:noreply, socket}`) |
| `functional_analysis_form_values/1` | 1344 | :1344-1351 |
| `params_equal?/2` | — | :1353-1361 |
| `compute_draft_status/2` | 1383 | :1383-1397 (blank = `String.trim == ""`) |
| `version_registration_blocker/2` | 1419 | :1412-1443 (`:conflict` row :1419-1420) |
| `content_params/1` | 1502 | :1502-1506 |
| `#functional-analysis-version-view` | 2577-2626 | :2577-2626; meta row ends :2592; no actions |
| citation confirm markup | — | :1955-2006 (`button-primary--sm` / `button-secondary--sm`) |
| `version_number` | — | `functional_analysis_version.ex:18` (`:integer`) |
| `get_functional_analysis_version/4` | 1758 | `clinical_record.ex:1758` |
| tests: #363 helpers / #364 block | 1866-1887 / 1890-2216 | same; `eorc_params/1` :2210, forged pattern :2162-2179 |

## Technical Approach

Pure `review.ex` change. One extracted autosave-scheduling helper, one selection choke-point helper, one blocker, one apply function, three events, one assign, one actions block in the version panel. No domain/schema change; `register_functional_analysis_version` is never called.

## Interfaces / Contracts

**Mount:** `assign(:continue_confirmation_pending, false)` after :173.

**L2 – shared helper** (replaces :756-762 inline code):

```elixir
# Bumps seq so any queued stale autosave is ignored by :perform_autosave (:1035).
defp schedule_functional_analysis_autosave(socket, values) do
  seq = socket.assigns.autosave_seq + 1
  send(self(), {:perform_autosave, values, seq})
  socket |> assign(:autosave_seq, seq) |> assign(:draft_status, :saving)
end
```

`change_functional_analysis` keeps: the form assign (:741-746, must run even on no-op paths), the tombstone branch (:749) and the `params_equal?` branch (:752). Its `true` branch becomes `{:noreply, schedule_functional_analysis_autosave(socket, merged_values)}`. Behavior unchanged. The helper deliberately does **not** assign the form; each caller does.

**L7 – selection choke point:**

```elixir
defp put_selected_version(socket, version, content) do
  socket
  |> assign(:selected_version, version)
  |> assign(:selected_version_content, content)
  |> assign(:continue_confirmation_pending, false)
end
```

Replace the 3 assign pairs at :900-902, :920-922, :928-930 with `put_selected_version(nil, nil)` / `(version, content)` / `(nil, nil)`. Clause 1 (:889-896) needs no edit (AD5 invariant). The confirm path also calls `put_selected_version(nil, nil)`.

**Blocker (L5):**

```elixir
defp continuation_blocker(assigns) do
  cond do
    not match?(%FunctionalAnalysisVersion{}, assigns.selected_version) -> :noop
    assigns.draft_generation_pending -> :noop
    assigns.draft_tombstoned_at != nil -> :noop
    assigns.draft_status == :conflict ->
      {:flash, "Resolvé el conflicto de guardado antes de continuar desde una versión."}
    true -> nil
  end
end
```

**Events** (placed after the select clauses, :934):

| Event | Behavior |
|---|---|
| `request_continue_from_version` | blocker `:noop` → `{:noreply, socket}`; `{:flash, m}` → `put_flash(:error, m)`; `nil` + `working_form_blank?(socket)` → `apply_version_continuation(socket)` (L4); else `assign(:continue_confirmation_pending, true)` |
| `confirm_continue_from_version` | `continue_confirmation_pending != true` → no-op (forged confirm cannot skip acknowledgement); blocker `:noop` → no-op; `{:flash, m}` → flash + `assign(:continue_confirmation_pending, false)`; `nil` → `apply_version_continuation(socket)` |
| `cancel_continue_from_version` | `assign(:continue_confirmation_pending, false)` only |

`working_form_blank?/1`: `functional_analysis_form_values(socket) |> Map.values() |> Enum.all?(&(String.trim(&1) == ""))` (includes `previous_notes`, mirrors :1391).

`apply_version_continuation/1` (L3 re-fetch, used by both blank-request and confirm):
- `get_functional_analysis_version(prof, patient_id, tb_id, socket.assigns.selected_version.id)`
  - `{:ok, v}` → `{_f, c} = FunctionalAnalysisContent.parse(v.body)`; `values = content_params(c)`; assign `functional_analysis_form` = `to_form(values, as: "functional_analysis")`; `put_selected_version(nil, nil)`; `schedule_functional_analysis_autosave(values)`; flash `:info` "Contenido de la Versión #{v.version_number} copiado al borrador de trabajo."
  - `{:error, :unauthorized}` → `redirect_to_patients(socket, :unauthorized)`
  - `{:error, _}` → `put_selected_version(nil, nil)` + flash `:error` "La versión no está disponible." + `relist_version_summaries/1` (mirrors :927-932)

**Template** — insert after the meta row (:2592), before previous notes:

```heex
<div :if={!@draft_tombstoned_at} id="functional-analysis-version-actions" class="form-actions">
  <button :if={!@continue_confirmation_pending} type="button"
    id="functional-analysis-version-continue" phx-click="request_continue_from_version"
    class="button-primary button-primary--sm">Continuar desde esta versión</button>
</div>
<div :if={@continue_confirmation_pending} id="functional-analysis-version-continue-confirmation" role="alert">
  <p id="functional-analysis-version-continue-warning">
    El borrador de trabajo actual será reemplazado por el contenido de la Versión {@selected_version.version_number}. La versión histórica no se modifica y no se registra una versión nueva.
  </p>
  <div class="form-actions">
    <button type="button" id="functional-analysis-version-continue-confirm"
      phx-click="confirm_continue_from_version" class="button-primary button-primary--sm">Reemplazar borrador</button>
    <button type="button" id="functional-analysis-version-continue-cancel"
      phx-click="cancel_continue_from_version" class="button-secondary button-secondary--sm">Cancelar</button>
  </div>
</div>
```

## Architecture Decisions

| # | Decision | Rejected | Why |
|---|---|---|---|
| AD1 | Extract `schedule_functional_analysis_autosave/2` (seq+send+`:saving`) | Duplicate inline; synchronous save like :823-864 | One scheduling path = "normal autosave". `perform_autosave` drops any message whose seq ≠ current (:1035), so the bump is what makes a queued pre-copy autosave lose. A duplicate could drift and reintroduce that race |
| AD2 | Continuation **always** schedules; no `params_equal?` skip | Skip when copy == `last_saved` | Skipping would not bump seq: in `:saving`, a queued stale autosave of the old text would land and overwrite the copy; in `:save_failed`, the status would stay failed while the form equals DB. Explicit action, not a keystroke; an identical upsert is harmless |
| AD3 | Mirror only the `:conflict` row of `version_registration_blocker` (:1419) with new copy; do not reuse the function | Call `version_registration_blocker/2` | It also blocks `:save_failed` (:1422), `:saving` (:1425), unsaved form (:1428) and `:empty` (:1434), which contradicts L4/L6. `:conflict` is blocked because `functional_analysis_lock_version` is stale and the scheduled upsert would re-conflict; `:save_failed` keeps the valid lock version (:1063-1066 assign only status), and `:saving` is superseded by AD1 |
| AD4 | Tombstone/no-selection/pending → **silent** no-op in the blocker, checked before any fetch or scheduling; button hidden by `:if={!@draft_tombstoned_at}` | Flash; rely on `perform_autosave`'s tombstone gate | Matches #364 AD3 (only forged events reach it). Version panel **does** render on a tombstoned draft (selector :2539 and panel :2578 have no tombstone gate), so the server guard is required, not decorative. Guarding before the re-fetch also avoids a needless audited read |
| AD5 | Explicit `draft_generation_pending` row in blocker even though unreachable by construction | Rely on construction only | Verified invariant: pending ⇒ `selected_version == nil` (select clause 1 :889-896 rejects selection while pending; generate guard :767-774 rejects generation while selected; pending set only at :795). So the panel cannot render while pending. The row costs one line and protects against future paths that break the invariant (async merge at :965 would clobber the copied form) |
| AD6 | `put_selected_version/3` as the single choke point for L7 | Add `assign(:continue_confirmation_pending, false)` in each clause | One helper covers clause 2, both clause-3 branches and the confirm path; future selection paths cannot forget the reset |
| AD7 | Confirm requires `continue_confirmation_pending == true` | Allow confirm directly | A forged confirm must not bypass the replacement acknowledgement; blank drafts never need confirm (L4 applies on request) |
| AD8 | Blank test over `functional_analysis_form_values` (unsaved edits count) | `draft_status == :empty` | `draft_status` reflects the last save, not unsaved keystrokes; unsaved text is "current work" (proposal L4) |
| AD9 | Flash uses the re-fetched `v.version_number` | `@selected_version.version_number` | Same value; re-fetched struct is the authoritative one at copy time |

## Data Flow

    click Continuar ─→ request ─→ blocker ─┬ :noop / {:flash}
                                           ├ blank form ─→ apply
                                           └ else ─→ pending=true ─→ confirm/cancel UI
    confirm ─→ pending? ─→ blocker ─→ apply
    apply ─→ get_functional_analysis_version/4 ─┬ ok ─→ form=content_params ─→ put_selected_version(nil) ─→ schedule autosave ─→ :perform_autosave ─→ upsert
                                                 └ error ─→ flash + relist (or redirect)

## File Changes

| File | Action |
|---|---|
| `lib/alethea_web/live/target_behavior_live/review.ex` | Modify: assign, 2 helpers extracted, blocker, apply fn, 3 events, panel markup |
| `test/alethea_web/live/target_behavior_live/review_test.exs` | Modify: new describe "continue from a previous E-O-R-C version (GitHub #365)" after :2216; reuse `review_path/2`, `persist_draft!/4`, `version_count/0`, `eorc_params/1`, `field_view_id/1` |

No CSS needed (reuses `form-actions`, button classes).

## Testing Strategy

| Scenario | Assertions |
|---|---|
| Blank draft → immediate apply | no `#functional-analysis-version-continue-confirmation` ever; after `:sys.get_state`, `get_functional_analysis_content` == version content; form visible; flash text; `version_count()` unchanged |
| Draft has content → confirmation | click shows confirmation with "Versión N" warning; continue button hidden; DB unchanged |
| Confirm | DB == version content via real autosave path; `#functional-analysis-version-view` gone; `#functional-analysis-form` shows copied values |
| Cancel | confirmation gone, panel still shown, DB and form values unchanged |
| `:conflict` (`:sys.replace_state`) | request and forged confirm → flash "Resolvé el conflicto…", DB unchanged |
| `:save_failed` / `:saving` with queued stale autosave | `render_change` an edit, force status, request+confirm → after flush DB == version content (stale seq ignored) |
| Deletion race | open version, request (pending), `Retention.legally_delete_record`, confirm → flash "La versión no está disponible.", option gone, DB unchanged, no protected text in HTML |
| Forged events | `render_hook` confirm without request; request/confirm with no selection; tombstoned draft (`:sys.replace_state` `draft_tombstoned_at`); pending generation → DB unchanged, `autosave_seq` unchanged |
| Selection change clears pending | pending, then select working draft / other version → `continue_confirmation_pending == false`, no confirmation on reopen |
| AC5 reload | after confirm + flush, fresh `live/2` shows copied values in working form; reopening the historical version shows its original fields; `get_functional_analysis_version` body unchanged |

Sentiment regression: N/A (no AI pipeline change).

## Threat Matrix

N/A — no routing, shell, subprocess, VCS/PR automation, executable-file classification, or process-integration boundary.

## Migration / Rollout

No migration required. Revert-only rollback.

## Review Workload Forecast

| Slice | Prod | Tests | Total |
|---|---|---|---|
| Single PR | ~130 | ~240 | ~370 |

`Decision needed before apply: No` · `Chained PRs recommended: No` · `400-line budget risk: Medium`. A split is not deliverable: request without confirm would ship either destructive copy or a dead button. If tests overrun, consolidate forged-event cases into one table-driven test (as #364 :2162-2179) before considering `size:exception`.

## Open Questions

None blocking.
