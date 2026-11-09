# Design: /pausa command, onboarding notice and professional notification (#446)

All function names, line numbers and signatures below were read directly from the post-pull codebase (2026-11-09), not guessed from the issue text.

## 1. `Trigger.status` — add `"paused_by_patient"`

`lib/alethea/triggers/trigger.ex:70-76` — `validate_inclusion(:status, [...])` is an **Elixir-level `Ecto.Changeset` validation, not a DB check constraint** (the only `check_constraint/2` calls on this schema target `:kind`, not `:status` — `trigger.ex:79-81`). So **no migration is needed**: just add `"paused_by_patient"` to the list.

```elixir
|> validate_inclusion(:status, [
  "active",
  "inactive",
  "fired",
  "paused_by_crisis",
  "paused_by_delivery_failures",
  "paused_by_patient"
])
```

## 2. New domain function: `Triggers.pause_active_triggers_for_patient/1`

Model directly on `pause_active_triggers_for_crisis/1` (`lib/alethea/triggers.ex:694-726`), with the one correctness fix this issue requires: an explicit `kind` filter (the crisis function lacks one and today incorrectly also pauses reactive triggers — out of scope to fix there, but must not repeat here).

```elixir
@doc """
Pauses all active-kind triggers of a patient on their own /pausa command (#446).
Moves status to `paused_by_patient`, cancels scheduled Oban jobs, writes content-free
audit logs, and broadcasts a professional notification. Trigger reactivo is untouched
(the kind filter below is the fix pause_active_triggers_for_crisis/1 is missing).
"""
@spec pause_active_triggers_for_patient(binary()) :: {:ok, integer()} | {:error, term()}
def pause_active_triggers_for_patient(patient_id) when is_binary(patient_id) do
  with {:ok, valid_patient_id} <- Ecto.UUID.cast(patient_id) do
    Repo.transaction(fn ->
      query =
        from(t in Trigger,
          where: t.patient_id == ^valid_patient_id and t.kind == "active" and t.status == "active",
          lock: "FOR UPDATE"
        )

      triggers = Repo.all(query)

      for trigger <- triggers do
        trigger
        |> Trigger.changeset(%{status: "paused_by_patient"})
        |> Repo.update!()

        delete_scheduled_jobs(trigger.id)

        insert_content_free_audit!(
          trigger.professional_id,
          trigger.id,
          "trigger_paused_by_patient"
        )

        enqueue_trigger_rag_event(%{trigger | status: "paused_by_patient"})
      end

      if triggers != [] do
        broadcast_patient_pause(patient_id, triggers)
      end

      length(triggers)
    end)
  else
    :error -> {:error, :invalid_patient_id}
  end
end

defp broadcast_patient_pause(patient_id, triggers) do
  professional_id = triggers |> List.first() |> Map.fetch!(:professional_id)

  Phoenix.PubSub.broadcast(
    Alethea.PubSub,
    "psychologist:alerts",
    {:trigger_paused_by_patient,
     %{patient_id: patient_id, professional_id: professional_id, count: length(triggers)}}
  )
end
```

**Design note**: unlike the crisis path, there's no patient-level flag to also set (no equivalent of `urgent_intervention`'s fire-time re-check) — a patient-initiated pause has no race with a professional concurrently approving a new trigger that needs covering, so the single bulk status flip is sufficient.

## 3. `resume_trigger/3` — accept the new status

`lib/alethea/triggers.ex:647-687`, the `case` clause at line 677-679:

```elixir
%Trigger{status: status} = trigger
when status in ["paused_by_crisis", "paused_by_delivery_failures", "paused_by_patient"] ->
  reactivate_or_resume_trigger(trigger, professional.id, "trigger_resumed", dek)
```

No other change needed — `reactivate_or_resume_trigger/4` (`triggers.ex:1363+`) already generically resets `consecutive_delivery_failures`, revalidates the schedule, and re-enqueues `ActiveTriggerWorker`, regardless of which paused status the trigger came from.

`activate_trigger/3` (`triggers.ex:596-638`) should also get a defensive rollback clause for parity with the two existing ones (lines 620-624):

```elixir
%Trigger{status: "paused_by_patient"} ->
  Repo.rollback(:paused_by_patient)
```

## 4. `/pausa` recognition in `TelegramMessageWorker`

`lib/alethea/jobs/telegram_message_worker.ex:115-150`, `process_bound_message/5`. Insert the pause check **before** `empty_text?/1`, at the same branch level:

```elixir
defp process_bound_message(foundation_patient, chat_id, chat_id_hash, hash_prefix, text, opts) do
  telegram_message_id = Keyword.fetch!(opts, :telegram_message_id)

  cond do
    pause_command?(text) ->
      handle_pause_command(foundation_patient, chat_id, chat_id_hash, hash_prefix)

    empty_text?(text) ->
      handle_empty_inbound(foundation_patient, chat_id, hash_prefix)

    true ->
      # existing chat_id-refresh + continue_process_bound_message path
      ...
  end
end

defp pause_command?(text) when is_binary(text), do: String.trim(text) |> String.downcase() == "/pausa"
defp pause_command?(_), do: false
```

`handle_pause_command/4` mirrors `handle_empty_inbound/3`'s two-clause shape (unlinked foundation row → silent no-op; linked → act) and, for the linked case:

1. Resolves the legacy patient (`FoundationAccounts.legacy_patient/1`, same as `continue_process_bound_message/6` does at line 194).
2. Calls `Triggers.pause_active_triggers_for_patient(legacy_patient.id)`.
3. Sends the fixed confirmation — reuse `enqueue_outbound/6` (`telegram_message_worker.ex:765`) **with `message_id: nil`**, the exact no-Message-row path `enqueue_unregistered_reply/3` already uses (line 934-941: `enqueue_outbound(chat_id_hash, chat_id, nil, @unregistered_copy, hash_prefix)`). This keeps the confirmation off the clinical journal, consistent with the command itself never being persisted.

```elixir
@pausa_confirmation "Listo, pausamos tus mensajes programados. Podés escribirme cuando quieras."

defp handle_pause_command(%{legacy_patient_id: nil}, _chat_id, _chat_id_hash, hash_prefix) do
  Logger.info("TelegramMessageWorker: /pausa on unlinked chat, ignoring (hash_prefix=#{hash_prefix})")
  :ok
end

defp handle_pause_command(foundation_patient, chat_id, chat_id_hash, hash_prefix) do
  {:ok, legacy_patient} = FoundationAccounts.legacy_patient(foundation_patient)
  {:ok, _count} = Triggers.pause_active_triggers_for_patient(legacy_patient.id)
  enqueue_outbound(chat_id_hash, chat_id, nil, @pausa_confirmation, hash_prefix)
end
```

Exact `enqueue_outbound/6` opts (lane/priority defaults) to confirm against the live function body during apply — the call shape above is right, the keyword-list details are a one-line check, not a design risk.

## 5. Professional notification wiring

`lib/alethea_web/live/dashboard_live.ex` — subscribed to `"psychologist:alerts"` already (line 18). Add a `handle_info` clause next to the existing `:crisis_detected` one (line 778-834), simpler (no `urgent_intervention` flag, no critical-patients list):

```elixir
def handle_info({:trigger_paused_by_patient, %{patient_id: patient_id, count: count}}, socket) do
  professional = socket.assigns.current_professional

  case Accounts.get_patient_for_professional(professional.id, patient_id) do
    nil ->
      {:noreply, socket}

    patient ->
      notif =
        NotificationCenter.build_notification(:trigger_paused_by_patient, %{
          patient_alias: patient.alias,
          count: count
        })

      Phoenix.LiveView.send_update(NotificationCenter, id: "notification-center", new_notification: notif)

      {:noreply, socket}
  end
end
```

`lib/alethea_web/live/dashboard_live/components/notification_center.ex` — add matching clauses next to the `:crisis_detected`/`:risk_uncertain` ones (lines 229-248):

```elixir
defp notification_severity(:trigger_paused_by_patient, _), do: :info

defp notification_message(:trigger_paused_by_patient, %{patient_alias: alias, count: count}) do
  "#{alias} pausó #{count} mensaje(s) programado(s) con /pausa."
end
```

## 6. Durable badge + resume button in `triggers_live/index.ex`

Three touch points, all next to the existing `paused_by_delivery_failures` handling:

**Status pill** (`index.ex:1131-1144`, add a branch):
```heex
<% trigger.status == "paused_by_patient" -> %>
  <span id={"trigger-status-badge-#{trigger.id}"} class="pt-pill pt-pill--warning">
    Pausado por el paciente
  </span>
```

**Resume button** (`index.ex:1210`, extend the `in [...]` guard):
```heex
<% trigger.status in ["paused_by_crisis", "paused_by_delivery_failures", "paused_by_patient"] -> %>
  <!-- existing "Reanudar" button, unchanged -->
```

**Durable reason block** (`index.ex:1248`, add a sibling `if`):
```heex
<%= if trigger.status == "paused_by_patient" do %>
  <div
    id={"trigger-pause-reason-#{trigger.id}"}
    class="pt-alert pt-alert--warning"
    style="margin-top: 8px; margin-bottom: 8px; padding: 8px 12px; border-radius: 6px; font-size: 0.9em; background: var(--color-surface-subtle); border-left: 3px solid #f59e0b;"
  >
    El paciente pausó este trigger con el comando /pausa. Podés reanudarlo cuando corresponda.
  </div>
<% end %>
```

(Uses `pt-pill--warning` rather than `pt-pill--risk` — a patient-initiated pause is not a risk signal like crisis or delivery failure, so it gets a visually distinct, calmer badge. Confirm this class exists in the stylesheet during apply; fall back to `pt-pill--risk` if not, for consistency over novelty.)

## 7. Onboarding disclosure

`lib/alethea/jobs/telegram_onboarding_worker.ex:211-233`, `welcome_text/1`. Append the disclosure **after** the `case` resolves (covers both the default and the custom-message branch unconditionally):

```elixir
@scheduling_disclosure "Tu psicólogo/a también puede programarte mensajes puntuales desde Alethea."

defp welcome_text(patient) do
  name = first_name(patient.profile_name)

  base =
    case custom_welcome_message(patient) do
      nil ->
        default_welcome_text(name)

      custom ->
        resolved = interpolate_welcome_name(custom, name)
        if meaningless_welcome?(resolved), do: default_welcome_text(name), else: resolved
    end

  base <> " " <> @scheduling_disclosure
end
```

## 8. Testing plan

- `test/alethea/jobs/telegram_message_worker_test.exs` (or a new `telegram_message_worker_pause_test.exs`, prior art: `telegram_message_worker_crisis_triggers_test.exs`, `telegram_message_worker_reactive_triggers_test.exs`) — drive `TelegramMessageWorker.perform/1` with `/pausa`, `/Pausa `, and near-misses (`"pausa"`, `"necesito pausa"`); assert: no `Message` row created for the command, the patient's active-kind triggers become `paused_by_patient`, reactive-kind triggers stay `active`, a fixed confirmation is enqueued via `TelegramOutboundWorker` with no `message_id`, no `ActiveTriggerWorker` job remains scheduled.
- `test/alethea/triggers_test.exs` — extend the existing pause/resume test block (~L341-511) with `pause_active_triggers_for_patient/1` (mirrors the crisis test shape, plus an explicit assertion that a reactive-kind trigger is untouched) and `resume_trigger/3` accepting `"paused_by_patient"`.
- `test/alethea_web/live/triggers_live_test.exs` — assert the badge, the reason block, and the "Reanudar" button render for a `paused_by_patient` trigger.
- `test/alethea/jobs/telegram_onboarding_worker_test.exs` — assert the disclosure is present both for the default template and for a patient whose professional set a custom `welcome_message`.
- `test/alethea_web/live/dashboard_live_test.exs` — assert the `:trigger_paused_by_patient` PubSub message produces a notification via `NotificationCenter`.

## 9. Open item carried from proposal

Exact Spanish copy above (confirmation reply, badge label, reason block, professional notification sentence, onboarding disclosure sentence) is a first draft — confirm wording with the user before `sdd-apply` writes it for real.
