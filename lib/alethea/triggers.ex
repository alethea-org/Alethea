defmodule Alethea.Triggers do
  @moduledoc """
  Context module for managing patient triggers: scheduled ("active" kind,
  Issue #440) and reactive ones that fire when a patient burst matches their
  condition (Issue #448), plus the elicited-reply window (Issue #447).
  """

  import Ecto.Query

  alias Alethea.Accounts
  alias Alethea.Accounts.AuditLog
  alias Alethea.AI.Chains.TriggerPreviewChain
  alias Alethea.AI.JournalingOutputGuard
  alias Alethea.Clinical
  alias Alethea.Clinical.Message
  alias Alethea.ClinicalRecord.Outbox, as: ClinicalRecordOutbox
  alias Alethea.Encryption.PatientVault
  alias Alethea.Repo
  alias Alethea.Triggers.{Schedule, Trigger, TriggerFiring}
  alias AletheaJobs.ActiveTriggerWorker

  @default_cooldown_hours 24

  # Issue #447: a patient reply within this many seconds of a delivered
  # Trigger activo message is prompted behavior ("elicited"), not
  # spontaneous. Only acknowledged deliveries ("sent") open the window.
  @elicited_window_seconds 2 * 60 * 60

  @doc """
  Whether an inbound message timestamped `inbound_timestamp` falls within
  2 hours of the patient's newest delivered Trigger activo message
  (issue #447).

  Only outbound trigger messages whose Telegram delivery was acknowledged
  (`delivery_state: "sent"`) anchor the window — pending, ambiguous, or
  failed firings do not prove the patient was prompted. When several
  delivered trigger messages exist, the newest one (by `timestamp`, then
  `id`) anchors the window. A reply timestamped before that delivery,
  or from another patient, is never inside it.

  `inbound_timestamp` may be `nil` for rows that predate the field —
  legacy rows are read as spontaneous.
  """
  @spec elicited_window_open?(binary(), DateTime.t() | nil) :: boolean()
  def elicited_window_open?(patient_id, inbound_timestamp)

  def elicited_window_open?(patient_id, %DateTime{} = inbound_timestamp)
      when is_binary(patient_id) do
    query =
      from m in Message,
        where:
          m.patient_id == ^patient_id and
            not is_nil(m.trigger_id) and
            m.direction == "outbound" and
            m.delivery_state == "sent",
        order_by: [desc: m.timestamp, desc: m.id],
        limit: 1,
        select: m.timestamp

    case Repo.one(query) do
      nil ->
        false

      delivered_at ->
        elapsed = DateTime.diff(inbound_timestamp, delivered_at, :second)
        elapsed >= 0 and elapsed <= @elicited_window_seconds
    end
  end

  def elicited_window_open?(_patient_id, nil), do: false

  @doc """
  Computes the next occurrence for an active trigger after `from_utc`.
  Delegates to `Alethea.Triggers.Schedule.next_occurrence/2`.
  """
  defdelegate next_occurrence(trigger, from_utc), to: Schedule

  @doc """
  Returns a human-readable badge label for a trigger schedule.
  Delegates to `Alethea.Triggers.Schedule.schedule_badge/1`.
  """
  defdelegate schedule_badge(trigger), to: Schedule

  @doc """
  Generates a clinically neutral preview message from an instruction.
  """
  @spec generate_preview(Accounts.Professional.t(), binary(), String.t()) ::
          {:ok, %{draft: String.t()}} | {:error, term()}
  def generate_preview(%Accounts.Professional{} = professional, patient_id, instruction)
      when is_binary(patient_id) and is_binary(instruction) do
    with {:ok, valid_patient_id} <- Ecto.UUID.cast(patient_id),
         %Accounts.Patient{} <-
           Accounts.get_patient_for_professional(professional.id, valid_patient_id),
         trimmed <- String.trim(instruction),
         true <- trimmed != "",
         {:ok, %{draft: draft} = preview} <- trigger_preview_chain().run(%{instruction: trimmed}),
         :ok <- JournalingOutputGuard.check(draft, :trigger) do
      {:ok, preview}
    else
      :error -> {:error, :unauthorized}
      nil -> {:error, :unauthorized}
      false -> {:error, :empty_instruction}
      {:blocked, reason} -> {:error, {:blocked, reason}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Creates and approves an active trigger (one-shot, daily, or weekly) in a single transaction,
  encrypting its content per patient, writing audit logs, and scheduling
  an ActiveTriggerWorker Oban job.
  """
  @spec create_and_approve_trigger(Accounts.Professional.t(), binary(), map()) ::
          {:ok, Trigger.t()} | {:error, term()}
  def create_and_approve_trigger(%Accounts.Professional{} = professional, patient_id, attrs)
      when is_binary(patient_id) and is_map(attrs) do
    schedule_type =
      Map.get(attrs, :schedule_type) || Map.get(attrs, "schedule_type") || "once"

    with {:ok, valid_patient_id} <- Ecto.UUID.cast(patient_id),
         %Accounts.Patient{} = patient <-
           Accounts.get_patient_for_professional(professional.id, valid_patient_id),
         {:ok, schedule_info} <- Schedule.initial_occurrence(patient, schedule_type, attrs),
         {:ok, instruction, draft_message, approved_text} <- validate_and_extract_texts(attrs),
         {:ok, dek} <- Clinical.patient_dek(patient, "trigger_creation"),
         {:ok, enc_instruction} <- PatientVault.encrypt(instruction, dek),
         {:ok, enc_draft} <- PatientVault.encrypt(draft_message, dek),
         {:ok, enc_approved} <- PatientVault.encrypt(approved_text, dek) do
      Repo.transaction(fn ->
        trigger_params = %{
          patient_id: patient.id,
          professional_id: professional.id,
          instruction: enc_instruction,
          draft_message: enc_draft,
          approved_text: enc_approved,
          scheduled_at: schedule_info.scheduled_at,
          schedule_type: schedule_info.schedule_type,
          time: schedule_info.time,
          weekdays: schedule_info.weekdays,
          end_date: schedule_info.end_date,
          timezone: patient.timezone || "America/Santiago",
          status: "active"
        }

        trigger =
          %Trigger{}
          |> Trigger.changeset(trigger_params)
          |> Repo.insert!()

        # Audit logs for create and approve (content-free)
        insert_content_free_audit!(professional.id, trigger.id, "trigger_created")
        insert_content_free_audit!(professional.id, trigger.id, "trigger_approved")
        enqueue_trigger_rag_event(trigger)

        # Schedule Oban job with only ID in args
        %{"trigger_id" => trigger.id}
        |> ActiveTriggerWorker.new(scheduled_at: schedule_info.scheduled_at)
        |> Oban.insert!()

        %{
          trigger
          | decrypted_instruction: instruction,
            decrypted_draft_message: draft_message,
            decrypted_approved_text: approved_text
        }
      end)
    else
      :error -> {:error, :unauthorized}
      nil -> {:error, :unauthorized}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Creates and approves a reactive trigger (#448) in a single transaction.

  A reactive trigger has no schedule: it fires when a patient burst on the
  safe path matches its `condition`. The condition, instruction, draft and
  approved text are encrypted with the patient's DEK. `cooldown_hours`
  defaults to 24. Writes the same content-free audit entries as an active
  trigger and schedules no job.
  """
  @spec create_and_approve_reactive_trigger(Accounts.Professional.t(), binary(), map()) ::
          {:ok, Trigger.t()} | {:error, term()}
  def create_and_approve_reactive_trigger(
        %Accounts.Professional{} = professional,
        patient_id,
        attrs
      )
      when is_binary(patient_id) and is_map(attrs) do
    with {:ok, valid_patient_id} <- Ecto.UUID.cast(patient_id),
         %Accounts.Patient{} = patient <-
           Accounts.get_patient_for_professional(professional.id, valid_patient_id),
         {:ok, condition} <- extract_condition(attrs),
         {:ok, instruction, draft_message, approved_text} <- validate_and_extract_texts(attrs),
         {:ok, dek} <- Clinical.patient_dek(patient, "trigger_creation"),
         {:ok, enc_condition} <- PatientVault.encrypt(condition, dek),
         {:ok, enc_instruction} <- PatientVault.encrypt(instruction, dek),
         {:ok, enc_draft} <- PatientVault.encrypt(draft_message, dek),
         {:ok, enc_approved} <- PatientVault.encrypt(approved_text, dek) do
      trigger_params = %{
        patient_id: patient.id,
        professional_id: professional.id,
        condition: enc_condition,
        instruction: enc_instruction,
        draft_message: enc_draft,
        approved_text: enc_approved,
        cooldown_hours: fetch_attr(attrs, :cooldown_hours) || @default_cooldown_hours,
        fire_once: fetch_attr(attrs, :fire_once) || false,
        timezone: patient.timezone || "America/Santiago",
        status: "active"
      }

      Repo.transaction(fn ->
        ensure_reactive_slot!(patient.id)

        case %Trigger{} |> Trigger.reactive_changeset(trigger_params) |> Repo.insert() do
          {:ok, trigger} ->
            insert_content_free_audit!(professional.id, trigger.id, "trigger_created")
            insert_content_free_audit!(professional.id, trigger.id, "trigger_approved")
            enqueue_trigger_rag_event(trigger)

            %{
              trigger
              | decrypted_condition: condition,
                decrypted_instruction: instruction,
                decrypted_draft_message: draft_message,
                decrypted_approved_text: approved_text
            }

          {:error, changeset} ->
            Repo.rollback(changeset)
        end
      end)
    else
      :error -> {:error, :unauthorized}
      nil -> {:error, :unauthorized}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Edits a reactive trigger's condition, cooldown and fire-once flag (#450).

  Owner-scoped like `update_trigger_instruction/4`. Only the keys present in
  `attrs` change: `condition` (re-encrypted with the patient DEK; blank gives
  `{:error, :empty_condition}`), `cooldown_hours` (> 0) and `fire_once`. The
  approved text is kept (it is drafted from the instruction, not the
  condition). Changing the condition sets `cooldown_reset_at`, so earlier
  firings stop counting towards the cooldown (firing history is kept).

  Writes a content-free `trigger_updated` audit entry only when something
  changed; an edit that changes nothing writes nothing.
  """
  @spec update_reactive_trigger(Accounts.Professional.t(), binary(), binary(), map()) ::
          {:ok, Trigger.t()} | {:error, term()}
  def update_reactive_trigger(
        %Accounts.Professional{} = professional,
        patient_id,
        trigger_id,
        attrs
      )
      when is_binary(patient_id) and is_binary(trigger_id) and is_map(attrs) do
    with {:ok, new_condition} <- reactive_condition_edit(attrs),
         {:ok, valid_patient_id} <- Ecto.UUID.cast(patient_id),
         {:ok, valid_trigger_id} <- Ecto.UUID.cast(trigger_id),
         %Accounts.Patient{} = patient <-
           Accounts.get_patient_for_professional(professional.id, valid_patient_id) do
      Repo.transaction(fn ->
        query =
          from(t in Trigger,
            where:
              t.id == ^valid_trigger_id and t.patient_id == ^valid_patient_id and
                is_nil(t.archived_at),
            lock: "FOR UPDATE"
          )

        case Repo.one(query) do
          nil ->
            Repo.rollback(:not_found)

          %Trigger{kind: "reactive"} = trigger ->
            dek = patient_dek!(patient, "reactive_trigger_update")
            apply_reactive_edit(trigger, attrs, new_condition, professional.id, dek)

          %Trigger{} ->
            Repo.rollback(:not_reactive)
        end
      end)
    else
      :error -> {:error, :unauthorized}
      nil -> {:error, :unauthorized}
      {:error, reason} -> {:error, reason}
    end
  end

  defp reactive_condition_edit(attrs) do
    case fetch_attr(attrs, :condition) do
      nil ->
        {:ok, nil}

      raw ->
        case raw |> to_string() |> String.trim() do
          "" -> {:error, :empty_condition}
          trimmed -> {:ok, trimmed}
        end
    end
  end

  defp apply_reactive_edit(trigger, attrs, new_condition, professional_id, dek) do
    condition_changed? =
      new_condition != nil and
        PatientVault.decrypt(trigger.condition, dek) != {:ok, new_condition}

    changes =
      %{}
      |> put_present(:cooldown_hours, fetch_attr(attrs, :cooldown_hours))
      |> put_present(:fire_once, fetch_attr(attrs, :fire_once))
      |> put_condition_change(condition_changed?, new_condition, dek)

    changeset = Trigger.changeset(trigger, changes)

    cond do
      not changeset.valid? ->
        Repo.rollback(changeset)

      changeset.changes == %{} ->
        decrypt_trigger_fields(trigger, dek)

      true ->
        changeset =
          if condition_changed?,
            do: Ecto.Changeset.put_change(changeset, :cooldown_reset_at, now_seconds()),
            else: changeset

        updated = Repo.update!(changeset)
        insert_content_free_audit!(professional_id, trigger.id, "trigger_updated")
        enqueue_trigger_rag_event(updated)
        decrypt_trigger_fields(updated, dek)
    end
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp put_condition_change(map, false, _condition, _dek), do: map

  defp put_condition_change(map, true, condition, dek) do
    case PatientVault.encrypt(condition, dek) do
      {:ok, encrypted} -> Map.put(map, :condition, encrypted)
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp now_seconds, do: DateTime.utc_now() |> DateTime.truncate(:second)

  @doc """
  Lists the reactive triggers of `patient` that may be offered to the
  trigger matcher right now (#448): kind `reactive`, status `active`,
  approved (an `approved_text` is present, which a changed instruction
  clears), and not fired within their `cooldown_hours` before `now`.

  Called by the journaling pipeline, not by a professional, so it is not
  owner-scoped. The patient DEK is loaded only when at least one trigger is
  eligible; each returned trigger carries `decrypted_condition` and
  `decrypted_approved_text`, and one whose condition or approved text cannot
  be decrypted is left out.
  """
  @spec eligible_reactive_triggers(Accounts.Patient.t(), DateTime.t()) ::
          {:ok, [Trigger.t()]} | {:error, term()}
  def eligible_reactive_triggers(%Accounts.Patient{} = patient, now \\ DateTime.utc_now()) do
    recent_firing =
      from(f in TriggerFiring,
        where:
          f.trigger_id == parent_as(:trigger).id and
            (is_nil(parent_as(:trigger).cooldown_reset_at) or
               f.fired_at > parent_as(:trigger).cooldown_reset_at) and
            f.fired_at >
              fragment(
                "? - make_interval(hours => ?)",
                type(^now, :utc_datetime),
                parent_as(:trigger).cooldown_hours
              )
      )

    triggers =
      from(t in Trigger,
        as: :trigger,
        where:
          t.patient_id == ^patient.id and t.kind == "reactive" and t.status == "active" and
            not is_nil(t.approved_text) and not exists(recent_firing),
        order_by: [asc: t.inserted_at, asc: t.id]
      )
      |> Repo.all()

    case triggers do
      [] ->
        {:ok, []}

      _ ->
        with {:ok, dek} <- Clinical.patient_dek(patient, "reactive_trigger_matching") do
          {:ok,
           triggers
           |> Enum.map(&decrypt_trigger_fields(&1, dek))
           |> Enum.reject(&(is_nil(&1.decrypted_condition) or is_nil(&1.decrypted_approved_text)))}
        end
    end
  end

  @doc """
  Records that a reactive trigger fired for the patient message it matched
  (#448). `scheduled_at` defaults to `fired_at`. The message itself is not
  modified: it stays a spontaneous patient message.
  """
  @spec record_reactive_firing(binary(), binary(), DateTime.t()) ::
          {:ok, TriggerFiring.t()} | {:error, Ecto.Changeset.t()}
  def record_reactive_firing(trigger_id, message_id, %DateTime{} = fired_at)
      when is_binary(trigger_id) and is_binary(message_id) do
    %TriggerFiring{}
    |> TriggerFiring.changeset(%{
      trigger_id: trigger_id,
      message_id: message_id,
      status: "fired",
      kind: "reactive",
      fired_at: DateTime.truncate(fired_at, :second)
    })
    |> Repo.insert()
    |> case do
      {:ok, firing} ->
        enqueue_firing_rag_event(firing)
        {:ok, firing}

      other ->
        other
    end
  end

  @doc """
  Records a reactive firing only if the trigger is still eligible when the
  firing is persisted (#448).

  Eligibility is checked at match time (`eligible_reactive_triggers/2`),
  before reply generation, and two bursts for the same patient can both
  pass that check before either persists. This re-validates it under
  `SELECT ... FOR UPDATE` on the trigger row: kind `reactive`, status
  `active`, approved, and no firing within `cooldown_hours` before
  `fired_at`. Concurrent callers for the same trigger serialize on the row
  lock, so at most one firing lands per cooldown window.

  Returns `{:ok, :skipped}` when the trigger is no longer eligible. Meant to
  run inside the caller's reply-save transaction, so the lock is held until
  that transaction commits.
  """
  @spec fire_reactive_trigger(binary(), binary(), DateTime.t()) ::
          {:ok, TriggerFiring.t()} | {:ok, :skipped} | {:error, term()}
  def fire_reactive_trigger(trigger_id, message_id, %DateTime{} = fired_at)
      when is_binary(trigger_id) and is_binary(message_id) do
    fired_at = DateTime.truncate(fired_at, :second)

    Repo.transaction(fn ->
      locked =
        Repo.one(
          from(t in Trigger,
            where: t.id == ^trigger_id,
            lock: "FOR UPDATE"
          )
        )

      case reactive_fireability(locked, fired_at) do
        :fireable ->
          case record_reactive_firing(trigger_id, message_id, fired_at) do
            {:ok, firing} ->
              clear_cooldown_reset(locked)
              deactivate_if_fire_once(locked)
              firing

            {:error, reason} ->
              Repo.rollback(reason)
          end

        :cooldown ->
          insert_content_free_audit!(
            locked.professional_id,
            locked.id,
            "trigger_firing_skipped_cooldown"
          )

          :skipped

        :ineligible ->
          :skipped
      end
    end)
  end

  # A firing after a condition edit starts a fresh cooldown, so the reset
  # marker is no longer needed. Clearing it makes that firing count even when
  # it lands in the same second as the edit (`fired_at > reset_at` is false).
  defp clear_cooldown_reset(%Trigger{cooldown_reset_at: nil}), do: :ok

  defp clear_cooldown_reset(%Trigger{id: id}) do
    Repo.update_all(from(t in Trigger, where: t.id == ^id), set: [cooldown_reset_at: nil])
    :ok
  end

  # D1 (#450): a fire-once trigger turns inactive in the same locked
  # transaction as its firing.
  defp deactivate_if_fire_once(%Trigger{fire_once: true} = trigger) do
    updated = trigger |> Trigger.changeset(%{status: "inactive"}) |> Repo.update!()

    insert_content_free_audit!(
      trigger.professional_id,
      trigger.id,
      "trigger_deactivated_fire_once"
    )

    enqueue_trigger_rag_event(updated)
    :ok
  end

  defp deactivate_if_fire_once(_trigger), do: :ok

  defp reactive_fireability(
         %Trigger{kind: "reactive", status: "active", approved_text: approved} = trigger,
         fired_at
       )
       when not is_nil(approved) do
    window_start = DateTime.add(fired_at, -trigger.cooldown_hours * 3600, :second)

    # Firings at or before `cooldown_reset_at` (a condition edit) do not count.
    counted_since =
      case trigger.cooldown_reset_at do
        nil -> window_start
        reset_at -> Enum.max([window_start, reset_at], DateTime)
      end

    in_cooldown? =
      Repo.exists?(
        from(f in TriggerFiring,
          where: f.trigger_id == ^trigger.id and f.fired_at > ^counted_since
        )
      )

    if in_cooldown?, do: :cooldown, else: :fireable
  end

  defp reactive_fireability(_trigger, _fired_at), do: :ineligible

  @doc """
  Lists all triggers for a given patient, including active, inactive, and unapproved.
  Decrypts fields using patient DEK.
  """
  @spec list_triggers(Accounts.Professional.t(), binary()) ::
          {:ok, [Trigger.t()]} | {:error, :unauthorized}
  def list_triggers(%Accounts.Professional{} = professional, patient_id)
      when is_binary(patient_id) do
    with {:ok, valid_patient_id} <- Ecto.UUID.cast(patient_id),
         %Accounts.Patient{} = patient <-
           Accounts.get_patient_for_professional(professional.id, valid_patient_id) do
      triggers =
        Trigger
        |> where([t], t.patient_id == ^valid_patient_id and is_nil(t.archived_at))
        |> order_by([t], asc: t.scheduled_at)
        |> Repo.all()

      decrypted =
        case Clinical.patient_dek(patient, "trigger_listing") do
          {:ok, dek} -> Enum.map(triggers, &decrypt_trigger_fields(&1, dek))
          _ -> triggers
        end

      {:ok, decrypted}
    else
      _ -> {:error, :unauthorized}
    end
  end

  @default_page_size 20

  @doc """
  Lists one page of a patient's non-archived triggers of a single kind with
  keyset pagination. Scheduled (`"active"`) triggers keep the soonest-first
  order of `list_triggers/2` (`scheduled_at` asc, `id` asc); reactive ones
  have no schedule and are listed newest first (`inserted_at` desc, `id` desc).

  Options:
    * `:kind` — `"active"` (scheduled, default) or `"reactive"`; filtered in the query.
    * `:limit` — page size (default #{@default_page_size}).
    * `:before` — cursor returned by a previous page; only older triggers are returned.

  Returns `{:ok, %{entries: triggers, more?: boolean, cursor: cursor | nil}}`.
  """
  @spec list_triggers_page(Accounts.Professional.t(), binary(), keyword()) ::
          {:ok, %{entries: [Trigger.t()], more?: boolean(), cursor: term()}}
          | {:error, :unauthorized}
  def list_triggers_page(%Accounts.Professional{} = professional, patient_id, opts \\ [])
      when is_binary(patient_id) do
    kind = Keyword.get(opts, :kind, "active")
    limit = Keyword.get(opts, :limit, @default_page_size)

    with {:ok, valid_patient_id} <- Ecto.UUID.cast(patient_id),
         %Accounts.Patient{} = patient <-
           Accounts.get_patient_for_professional(professional.id, valid_patient_id) do
      rows =
        Trigger
        |> where(
          [t],
          t.patient_id == ^valid_patient_id and t.kind == ^kind and is_nil(t.archived_at)
        )
        |> trigger_page_order(kind, Keyword.get(opts, :before))
        |> limit(^(limit + 1))
        |> Repo.all()

      {entries, more?} = split_page(rows, limit)

      decrypted =
        case Clinical.patient_dek(patient, "trigger_listing") do
          {:ok, dek} -> Enum.map(entries, &decrypt_trigger_fields(&1, dek))
          _ -> entries
        end

      {:ok,
       %{
         entries: decrypted,
         more?: more?,
         cursor: page_cursor(entries, &trigger_cursor(&1, kind))
       }}
    else
      _ -> {:error, :unauthorized}
    end
  end

  defp trigger_page_order(query, "active", cursor) do
    query =
      case cursor do
        {%DateTime{} = scheduled_at, id} ->
          where(
            query,
            [t],
            t.scheduled_at > ^scheduled_at or (t.scheduled_at == ^scheduled_at and t.id > ^id)
          )

        nil ->
          query
      end

    order_by(query, [t], asc: t.scheduled_at, asc: t.id)
  end

  defp trigger_page_order(query, _reactive, cursor) do
    query =
      case cursor do
        {%DateTime{} = inserted_at, id} ->
          where(
            query,
            [t],
            t.inserted_at < ^inserted_at or (t.inserted_at == ^inserted_at and t.id < ^id)
          )

        nil ->
          query
      end

    order_by(query, [t], desc: t.inserted_at, desc: t.id)
  end

  defp trigger_cursor(trigger, "active"), do: {trigger.scheduled_at, trigger.id}
  defp trigger_cursor(trigger, _reactive), do: {trigger.inserted_at, trigger.id}

  defp split_page(rows, limit) do
    {entries, rest} = Enum.split(rows, limit)
    {entries, rest != []}
  end

  defp page_cursor([], _key_fun), do: nil
  defp page_cursor(entries, key_fun), do: entries |> List.last() |> key_fun.()

  @doc """
  Lists active and approved triggers for a given patient.
  Decrypts instruction and approved_text using patient DEK.
  """
  @spec list_active_triggers(Accounts.Professional.t(), binary()) ::
          {:ok, [Trigger.t()]} | {:error, :unauthorized}
  def list_active_triggers(%Accounts.Professional{} = professional, patient_id)
      when is_binary(patient_id) do
    with {:ok, valid_patient_id} <- Ecto.UUID.cast(patient_id),
         %Accounts.Patient{} = patient <-
           Accounts.get_patient_for_professional(professional.id, valid_patient_id) do
      triggers =
        Trigger
        |> where(
          [t],
          t.patient_id == ^valid_patient_id and t.status == "active" and
            not is_nil(t.approved_text) and is_nil(t.archived_at)
        )
        |> order_by([t], asc: t.scheduled_at)
        |> Repo.all()

      decrypted =
        case Clinical.patient_dek(patient, "trigger_listing") do
          {:ok, dek} -> Enum.map(triggers, &decrypt_trigger_fields(&1, dek))
          _ -> triggers
        end

      {:ok, decrypted}
    else
      _ -> {:error, :unauthorized}
    end
  end

  @doc """
  Returns an owner-scoped summary of trigger counts grouped by kind and status for a given patient.
  Aggregates counts at the database level without decrypting PHI.
  """
  @spec get_trigger_summary(Accounts.Professional.t(), binary()) ::
          {:ok, map()} | {:error, :unauthorized}
  def get_trigger_summary(%Accounts.Professional{} = professional, patient_id)
      when is_binary(patient_id) do
    with {:ok, valid_patient_id} <- Ecto.UUID.cast(patient_id),
         %Accounts.Patient{} <-
           Accounts.get_patient_for_professional(professional.id, valid_patient_id) do
      query =
        from(t in Trigger,
          where: t.patient_id == ^valid_patient_id and is_nil(t.archived_at),
          group_by: t.kind,
          select: %{
            kind: t.kind,
            total: count(t.id),
            active: count(fragment("CASE WHEN ? = 'active' THEN 1 END", t.status)),
            inactive: count(fragment("CASE WHEN ? = 'inactive' THEN 1 END", t.status)),
            fired: count(fragment("CASE WHEN ? = 'fired' THEN 1 END", t.status)),
            paused_by_crisis:
              count(fragment("CASE WHEN ? = 'paused_by_crisis' THEN 1 END", t.status)),
            paused_by_delivery_failures:
              count(fragment("CASE WHEN ? = 'paused_by_delivery_failures' THEN 1 END", t.status)),
            needs_approval:
              count(
                fragment(
                  "CASE WHEN ? IS NULL AND ? != 'fired' THEN 1 END",
                  t.approved_text,
                  t.status
                )
              )
          }
        )

      zero = %{
        total: 0,
        active: 0,
        inactive: 0,
        fired: 0,
        paused_by_crisis: 0,
        paused_by_delivery_failures: 0,
        needs_approval: 0
      }

      by_kind = Map.new(Repo.all(query), fn row -> {row.kind, Map.delete(row, :kind)} end)

      active_kind = Map.get(by_kind, "active", zero)
      reactive_kind = Map.get(by_kind, "reactive", zero)
      stats = Map.merge(active_kind, reactive_kind, fn _key, a, r -> a + r end)

      summary = %{
        total: stats.total,
        by_kind: %{
          active: active_kind,
          reactive: reactive_kind
        },
        by_status: %{
          active: stats.active,
          inactive: stats.inactive,
          fired: stats.fired,
          paused_by_crisis: stats.paused_by_crisis,
          paused_by_delivery_failures: stats.paused_by_delivery_failures
        },
        active_kind: active_kind,
        reactive_kind: reactive_kind,
        needs_approval: stats.needs_approval
      }

      {:ok, summary}
    else
      _ -> {:error, :unauthorized}
    end
  end

  def get_trigger_summary(_professional, _patient_id), do: {:error, :unauthorized}

  @doc """
  Plural delegate for `get_trigger_summary/2`.
  """
  defdelegate get_triggers_summary(professional, patient_id),
    to: __MODULE__,
    as: :get_trigger_summary

  @doc """
  Deactivates an active trigger without deleting it (S1).
  Removes any scheduled Oban jobs and records an audit log entry.
  """
  @spec deactivate_trigger(Accounts.Professional.t(), binary(), binary()) ::
          {:ok, Trigger.t()} | {:error, term()}
  def deactivate_trigger(%Accounts.Professional{} = professional, patient_id, trigger_id)
      when is_binary(patient_id) and is_binary(trigger_id) do
    with {:ok, valid_patient_id} <- Ecto.UUID.cast(patient_id),
         {:ok, valid_trigger_id} <- Ecto.UUID.cast(trigger_id),
         %Accounts.Patient{} = patient <-
           Accounts.get_patient_for_professional(professional.id, valid_patient_id),
         {:ok, dek} <- Clinical.patient_dek(patient, "trigger_deactivate") do
      Repo.transaction(fn ->
        query =
          from(t in Trigger,
            where:
              t.id == ^valid_trigger_id and t.patient_id == ^valid_patient_id and
                is_nil(t.archived_at),
            lock: "FOR UPDATE"
          )

        case Repo.one(query) do
          nil ->
            Repo.rollback(:not_found)

          %Trigger{status: "fired"} ->
            Repo.rollback(:already_fired)

          %Trigger{status: "inactive"} = trigger ->
            decrypt_trigger_fields(trigger, dek)

          %Trigger{status: status} = trigger
          when status in [
                 "active",
                 "paused_by_crisis",
                 "paused_by_delivery_failures",
                 "paused_by_patient"
               ] ->
            updated =
              trigger
              |> Trigger.changeset(%{status: "inactive"})
              |> Repo.update!()

            delete_scheduled_jobs(trigger.id)
            insert_content_free_audit!(professional.id, trigger.id, "trigger_deactivated")
            enqueue_trigger_rag_event(updated)

            decrypt_trigger_fields(updated, dek)
        end
      end)
    else
      :error -> {:error, :unauthorized}
      nil -> {:error, :unauthorized}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Archives a trigger of either kind: the professional-facing "delete".

  The row is kept because firings and produced messages reference it as
  clinical/audit history. Archiving stops it for good (non-fired triggers
  become `inactive`, scheduled jobs are removed), stamps `archived_at` so
  listings and summaries hide it, and records a content-free audit entry.
  Archiving an already archived trigger is a no-op.
  """
  @spec archive_trigger(Accounts.Professional.t(), binary(), binary()) ::
          {:ok, Trigger.t()} | {:error, term()}
  def archive_trigger(%Accounts.Professional{} = professional, patient_id, trigger_id)
      when is_binary(patient_id) and is_binary(trigger_id) do
    with {:ok, valid_patient_id} <- Ecto.UUID.cast(patient_id),
         {:ok, valid_trigger_id} <- Ecto.UUID.cast(trigger_id),
         %Accounts.Patient{} = patient <-
           Accounts.get_patient_for_professional(professional.id, valid_patient_id) do
      Repo.transaction(fn ->
        query =
          from(t in Trigger,
            where: t.id == ^valid_trigger_id and t.patient_id == ^valid_patient_id,
            lock: "FOR UPDATE"
          )

        case Repo.one(query) do
          nil ->
            Repo.rollback(:not_found)

          %Trigger{archived_at: %DateTime{}} = trigger ->
            trigger

          %Trigger{} = trigger ->
            status = if trigger.status == "fired", do: "fired", else: "inactive"

            updated =
              trigger
              |> Ecto.Changeset.change(
                status: status,
                archived_at: DateTime.utc_now() |> DateTime.truncate(:second)
              )
              |> Repo.update!()

            delete_scheduled_jobs(trigger.id)
            insert_content_free_audit!(professional.id, trigger.id, "trigger_archived")
            enqueue_trigger_rag_event(updated)

            updated
        end
      end)
      |> case do
        {:ok, trigger} -> {:ok, decrypt_for_patient(trigger, patient)}
        error -> error
      end
    else
      :error -> {:error, :unauthorized}
      nil -> {:error, :unauthorized}
    end
  end

  defp decrypt_for_patient(trigger, patient) do
    case Clinical.patient_dek(patient, "trigger_archive") do
      {:ok, dek} -> decrypt_trigger_fields(trigger, dek)
      _ -> trigger
    end
  end

  @doc """
  Reactivates an inactive trigger (S1, S6).
  For one-shot triggers, returns an actionable error if the schedule expired.
  For recurring triggers, recomputes the next future occurrence in the patient's timezone
  without missed-send catchup, and schedules a new ActiveTriggerWorker Oban job.
  Rejects triggers paused by crisis (which must be resumed via `resume_trigger/3`).
  """
  @spec activate_trigger(Accounts.Professional.t(), binary(), binary()) ::
          {:ok, Trigger.t()} | {:error, term()}
  def activate_trigger(%Accounts.Professional{} = professional, patient_id, trigger_id)
      when is_binary(patient_id) and is_binary(trigger_id) do
    with {:ok, valid_patient_id} <- Ecto.UUID.cast(patient_id),
         {:ok, valid_trigger_id} <- Ecto.UUID.cast(trigger_id),
         %Accounts.Patient{} = patient <-
           Accounts.get_patient_for_professional(professional.id, valid_patient_id) do
      Repo.transaction(fn ->
        # Patient row before trigger row: the same lock order as the burst
        # reply worker, so activating a reactive trigger cannot deadlock with
        # its firing (#450).
        lock_patient!(valid_patient_id)

        # Inside the transaction: a rejection (limit, status) also rolls back
        # the key-access audit that loading the DEK writes.
        dek = patient_dek!(patient, "trigger_activate")

        query =
          from(t in Trigger,
            where:
              t.id == ^valid_trigger_id and t.patient_id == ^valid_patient_id and
                is_nil(t.archived_at),
            lock: "FOR UPDATE"
          )

        case Repo.one(query) do
          nil ->
            Repo.rollback(:not_found)

          %Trigger{status: "fired"} ->
            Repo.rollback(:already_fired)

          %Trigger{approved_text: nil} ->
            Repo.rollback(:unapproved)

          %Trigger{status: "paused_by_crisis"} ->
            Repo.rollback(:paused_by_crisis)

          %Trigger{status: "paused_by_delivery_failures"} ->
            Repo.rollback(:paused_by_delivery_failures)

          %Trigger{status: "paused_by_patient"} ->
            Repo.rollback(:paused_by_patient)

          %Trigger{status: "active"} = trigger ->
            decrypt_trigger_fields(trigger, dek)

          %Trigger{status: "inactive"} = trigger ->
            reactivate_or_resume_trigger(trigger, professional.id, "trigger_activated", dek)
        end
      end)
    else
      :error -> {:error, :unauthorized}
      nil -> {:error, :unauthorized}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Resumes a trigger paused by crisis (Issue #443).
  Can only be performed by the patient's owning professional.
  Rechecks schedule validity, re-enqueues ActiveTriggerWorker, and audits the action.
  """
  @spec resume_trigger(Accounts.Professional.t(), binary(), binary()) ::
          {:ok, Trigger.t()} | {:error, term()}
  def resume_trigger(%Accounts.Professional{} = professional, patient_id, trigger_id)
      when is_binary(patient_id) and is_binary(trigger_id) do
    with {:ok, valid_patient_id} <- Ecto.UUID.cast(patient_id),
         {:ok, valid_trigger_id} <- Ecto.UUID.cast(trigger_id),
         %Accounts.Patient{} = patient <-
           Accounts.get_patient_for_professional(professional.id, valid_patient_id) do
      Repo.transaction(fn ->
        # Patient row before trigger row: the same lock order as the burst
        # reply worker, so activating a reactive trigger cannot deadlock with
        # its firing (#450).
        lock_patient!(valid_patient_id)

        # Inside the transaction: a rejection (limit, status) also rolls back
        # the key-access audit that loading the DEK writes.
        dek = patient_dek!(patient, "trigger_resume")

        query =
          from(t in Trigger,
            where:
              t.id == ^valid_trigger_id and t.patient_id == ^valid_patient_id and
                is_nil(t.archived_at),
            lock: "FOR UPDATE"
          )

        case Repo.one(query) do
          nil ->
            Repo.rollback(:not_found)

          %Trigger{status: "fired"} ->
            Repo.rollback(:already_fired)

          %Trigger{approved_text: nil} ->
            Repo.rollback(:unapproved)

          %Trigger{status: "active"} = trigger ->
            decrypt_trigger_fields(trigger, dek)

          %Trigger{status: "inactive"} ->
            Repo.rollback(:not_paused)

          %Trigger{status: status} = trigger
          when status in [
                 "paused_by_crisis",
                 "paused_by_delivery_failures",
                 "paused_by_patient"
               ] ->
            reactivate_or_resume_trigger(trigger, professional.id, "trigger_resumed", dek)
        end
      end)
    else
      :error -> {:error, :unauthorized}
      nil -> {:error, :unauthorized}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Pauses all active triggers of a patient when a crisis is detected (Issue #443).
  Moves status to `paused_by_crisis`, cancels scheduled Oban jobs, and writes content-free audit logs.
  """
  @spec pause_active_triggers_for_crisis(binary()) :: {:ok, integer()} | {:error, term()}
  def pause_active_triggers_for_crisis(patient_id) when is_binary(patient_id) do
    with {:ok, valid_patient_id} <- Ecto.UUID.cast(patient_id) do
      Repo.transaction(fn ->
        query =
          from(t in Trigger,
            where: t.patient_id == ^valid_patient_id and t.status == "active",
            lock: "FOR UPDATE"
          )

        triggers = Repo.all(query)

        for trigger <- triggers do
          trigger
          |> Trigger.changeset(%{status: "paused_by_crisis"})
          |> Repo.update!()

          delete_scheduled_jobs(trigger.id)

          insert_content_free_audit!(
            trigger.professional_id,
            trigger.id,
            "trigger_paused_by_crisis"
          )

          enqueue_trigger_rag_event(%{trigger | status: "paused_by_crisis"})
        end

        length(triggers)
      end)
    else
      :error -> {:error, :invalid_patient_id}
    end
  end

  @doc """
  Pauses all active-kind triggers of a patient on their own /pausa command (#446).
  Moves status to `paused_by_patient`, cancels scheduled Oban jobs, writes content-free
  audit logs, and broadcasts a professional notification. Trigger reactivo is untouched
  (the `kind` filter below is the fix `pause_active_triggers_for_crisis/1` is missing).
  """
  @spec pause_active_triggers_for_patient(binary()) :: {:ok, integer()} | {:error, term()}
  def pause_active_triggers_for_patient(patient_id) when is_binary(patient_id) do
    with {:ok, valid_patient_id} <- Ecto.UUID.cast(patient_id) do
      Repo.transaction(fn ->
        query =
          from(t in Trigger,
            where:
              t.patient_id == ^valid_patient_id and t.kind == "active" and t.status == "active",
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
          broadcast_patient_pause(valid_patient_id, triggers)
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

  @doc """
  Handles delivery failure for an outbound trigger message (Issue #445, S1-S3).
  Marks the associated TriggerFiring as "not_delivered", increments
  consecutive_delivery_failures, and after 3 consecutive failures pauses the trigger,
  cancels scheduled jobs, and writes a content-free audit log.
  """
  @spec handle_delivery_failure(binary()) :: :ok | :not_trigger | {:error, term()}
  def handle_delivery_failure(message_id) when is_binary(message_id) do
    with {:ok, valid_message_id} <- Ecto.UUID.cast(message_id) do
      Repo.transaction(fn ->
        case Repo.get(Clinical.Message, valid_message_id) do
          %Clinical.Message{trigger_id: trigger_id} = message when not is_nil(trigger_id) ->
            now = DateTime.utc_now() |> DateTime.truncate(:second)

            firing = Repo.get_by(TriggerFiring, message_id: message.id)

            if firing && firing.status == "not_delivered" do
              # Already processed as not_delivered (idempotent no-op)
              :ok
            else
              if firing do
                from(f in TriggerFiring, where: f.id == ^firing.id)
                |> Repo.update_all(set: [status: "not_delivered", updated_at: now])
              end

              case Repo.one(from(t in Trigger, where: t.id == ^trigger_id, lock: "FOR UPDATE")) do
                %Trigger{} = trigger ->
                  new_failures = (trigger.consecutive_delivery_failures || 0) + 1

                  if new_failures >= 3 and trigger.status == "active" do
                    trigger
                    |> Trigger.changeset(%{
                      status: "paused_by_delivery_failures",
                      consecutive_delivery_failures: new_failures
                    })
                    |> Repo.update!()

                    delete_scheduled_jobs(trigger.id)

                    insert_content_free_audit!(
                      trigger.professional_id,
                      trigger.id,
                      "trigger_paused_by_delivery_failures"
                    )

                    enqueue_trigger_rag_event(%{trigger | status: "paused_by_delivery_failures"})
                  else
                    trigger
                    |> Trigger.changeset(%{consecutive_delivery_failures: new_failures})
                    |> Repo.update!()
                  end

                  :ok

                nil ->
                  :ok
              end
            end

          _ ->
            :not_trigger
        end
      end)
      |> case do
        {:ok, result} -> result
        {:error, reason} -> {:error, reason}
      end
    else
      :error -> {:error, :invalid_message_id}
    end
  end

  def handle_delivery_failure(_), do: {:error, :invalid_message_id}

  @doc """
  Handles delivery success for an outbound trigger message (Issue #445, S4).
  Resets consecutive_delivery_failures to 0 when the message belongs to a trigger.
  """
  @spec handle_delivery_success(binary()) :: :ok | :not_trigger | {:error, term()}
  def handle_delivery_success(message_id) when is_binary(message_id) do
    with {:ok, valid_message_id} <- Ecto.UUID.cast(message_id) do
      Repo.transaction(fn ->
        case Repo.get(Clinical.Message, valid_message_id) do
          %Clinical.Message{trigger_id: trigger_id} when not is_nil(trigger_id) ->
            case Repo.one(from(t in Trigger, where: t.id == ^trigger_id, lock: "FOR UPDATE")) do
              %Trigger{consecutive_delivery_failures: failures} = trigger
              when not is_nil(failures) and failures > 0 ->
                trigger
                |> Trigger.changeset(%{consecutive_delivery_failures: 0})
                |> Repo.update!()

                :ok

              _ ->
                :ok
            end

          _ ->
            :not_trigger
        end
      end)
      |> case do
        {:ok, result} -> result
        {:error, reason} -> {:error, reason}
      end
    else
      :error -> {:error, :invalid_message_id}
    end
  end

  def handle_delivery_success(_), do: {:error, :invalid_message_id}

  @doc """
  Updates the instruction of an active trigger (S2, S3, S5).
  If unchanged, preserves approved text and revision.
  If changed, clears approved text and draft persistently, increments approval revision,
  removes pending scheduled jobs, and records an audit log entry.
  """
  @spec update_trigger_instruction(Accounts.Professional.t(), binary(), binary(), String.t()) ::
          {:ok, Trigger.t()} | {:error, term()}
  def update_trigger_instruction(
        %Accounts.Professional{} = professional,
        patient_id,
        trigger_id,
        new_instruction
      )
      when is_binary(patient_id) and is_binary(trigger_id) and is_binary(new_instruction) do
    trimmed = String.trim(new_instruction)

    if trimmed == "" do
      {:error, :empty_instruction}
    else
      with {:ok, valid_patient_id} <- Ecto.UUID.cast(patient_id),
           {:ok, valid_trigger_id} <- Ecto.UUID.cast(trigger_id),
           %Accounts.Patient{} = patient <-
             Accounts.get_patient_for_professional(professional.id, valid_patient_id),
           {:ok, dek} <- Clinical.patient_dek(patient, "trigger_instruction_update") do
        Repo.transaction(fn ->
          query =
            from(t in Trigger,
              where:
                t.id == ^valid_trigger_id and t.patient_id == ^valid_patient_id and
                  is_nil(t.archived_at),
              lock: "FOR UPDATE"
            )

          case Repo.one(query) do
            nil ->
              Repo.rollback(:not_found)

            %Trigger{status: "fired"} ->
              Repo.rollback(:already_fired)

            %Trigger{} = trigger ->
              case PatientVault.decrypt(trigger.instruction, dek) do
                {:ok, ^trimmed} ->
                  # Exact unchanged instruction preserves approved text and revision
                  decrypt_trigger_fields(trigger, dek)

                _ ->
                  {:ok, enc_instruction} = PatientVault.encrypt(trimmed, dek)
                  next_rev = (trigger.approval_revision || 1) + 1

                  updated =
                    trigger
                    |> Trigger.changeset(%{
                      instruction: enc_instruction,
                      approved_text: nil,
                      draft_message: nil,
                      approval_revision: next_rev
                    })
                    |> Repo.update!()

                  delete_scheduled_jobs(trigger.id)
                  insert_content_free_audit!(professional.id, trigger.id, "trigger_updated")
                  enqueue_trigger_rag_event(updated)

                  %{
                    updated
                    | decrypted_instruction: trimmed,
                      decrypted_draft_message: nil,
                      decrypted_approved_text: nil
                  }
              end
          end
        end)
      else
        :error -> {:error, :unauthorized}
        nil -> {:error, :unauthorized}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Reapproves an updated trigger with a newly reviewed message (S2, S3, S5).
  Requires a positive integer expected_revision to guard against concurrent edits and stale snapshots.
  """
  @spec reapprove_trigger(Accounts.Professional.t(), binary(), binary(), map()) ::
          {:ok, Trigger.t()} | {:error, term()}
  def reapprove_trigger(%Accounts.Professional{} = professional, patient_id, trigger_id, attrs)
      when is_binary(patient_id) and is_binary(trigger_id) and is_map(attrs) do
    raw_rev =
      Map.get(attrs, :expected_revision) || Map.get(attrs, "expected_revision") ||
        Map.get(attrs, :approval_revision) || Map.get(attrs, "approval_revision")

    with {:ok, expected_rev} <- validate_positive_integer_revision(raw_rev),
         app_text <- Map.get(attrs, :approved_text) || Map.get(attrs, "approved_text") || "",
         app_trimmed <- String.trim(to_string(app_text)),
         true <- app_trimmed != "",
         draft_text <-
           Map.get(attrs, :draft_message) || Map.get(attrs, "draft_message") || app_trimmed,
         draft_trimmed <- String.trim(to_string(draft_text)),
         expected_inst <-
           Map.get(attrs, :expected_instruction) || Map.get(attrs, "expected_instruction"),
         {:ok, valid_patient_id} <- Ecto.UUID.cast(patient_id),
         {:ok, valid_trigger_id} <- Ecto.UUID.cast(trigger_id),
         %Accounts.Patient{} = patient <-
           Accounts.get_patient_for_professional(professional.id, valid_patient_id),
         {:ok, dek} <- Clinical.patient_dek(patient, "trigger_reapprove"),
         {:ok, enc_app} <- PatientVault.encrypt(app_trimmed, dek),
         {:ok, enc_draft} <- PatientVault.encrypt(draft_trimmed, dek) do
      Repo.transaction(fn ->
        query =
          from(t in Trigger,
            where:
              t.id == ^valid_trigger_id and t.patient_id == ^valid_patient_id and
                is_nil(t.archived_at),
            lock: "FOR UPDATE"
          )

        case Repo.one(query) do
          nil ->
            Repo.rollback(:not_found)

          %Trigger{status: "fired"} ->
            Repo.rollback(:already_fired)

          %Trigger{} = trigger ->
            if trigger.approval_revision != expected_rev do
              Repo.rollback(:stale_revision)
            else
              inst_match? =
                if expected_inst != nil do
                  case PatientVault.decrypt(trigger.instruction, dek) do
                    {:ok, inst} -> inst == expected_inst
                    _ -> false
                  end
                else
                  true
                end

              if not inst_match? do
                Repo.rollback(:stale_instruction)
              else
                # If trigger is active, verify schedule validity and re-enqueue
                now = DateTime.utc_now()

                # Reactive triggers (#448) have no schedule to recheck.
                scheduled_at_res =
                  if trigger.status == "active" and trigger.kind == "active" do
                    case trigger.schedule_type do
                      "once" ->
                        if DateTime.compare(trigger.scheduled_at, now) != :gt do
                          {:error,
                           {:expired_schedule,
                            "El horario programado ya venció. Para programar un nuevo envío, crea un nuevo trigger con un horario futuro."}}
                        else
                          {:ok, trigger.scheduled_at}
                        end

                      recurring when recurring in ["daily", "weekly"] ->
                        if DateTime.compare(trigger.scheduled_at, now) != :gt do
                          attrs_sched = %{
                            time: trigger.time,
                            weekdays: trigger.weekdays,
                            end_date: trigger.end_date
                          }

                          patient_tz = %{timezone: trigger.timezone}

                          case Schedule.initial_occurrence(
                                 patient_tz,
                                 recurring,
                                 attrs_sched,
                                 now
                               ) do
                            {:ok, %{scheduled_at: next_at}} ->
                              {:ok, next_at}

                            {:error, {:invalid_end_date, _}} ->
                              {:error,
                               {:end_date_passed,
                                "La fecha de fin ya expiró. Modifica la fecha de fin o crea un nuevo trigger."}}

                            {:error, reason} ->
                              {:error, reason}
                          end
                        else
                          {:ok, trigger.scheduled_at}
                        end
                    end
                  else
                    {:ok, trigger.scheduled_at}
                  end

                case scheduled_at_res do
                  {:error, reason} ->
                    Repo.rollback(reason)

                  {:ok, scheduled_at} ->
                    updated =
                      trigger
                      |> Trigger.changeset(%{
                        approved_text: enc_app,
                        draft_message: enc_draft,
                        scheduled_at: scheduled_at
                      })
                      |> Repo.update!()

                    if trigger.status == "active" and trigger.kind == "active" do
                      delete_scheduled_jobs(trigger.id)

                      %{"trigger_id" => trigger.id}
                      |> ActiveTriggerWorker.new(scheduled_at: scheduled_at)
                      |> Oban.insert!()
                    end

                    insert_content_free_audit!(professional.id, trigger.id, "trigger_approved")
                    enqueue_trigger_rag_event(updated)

                    %{
                      updated
                      | decrypted_instruction:
                          case PatientVault.decrypt(updated.instruction, dek) do
                            {:ok, val} -> val
                            _ -> nil
                          end,
                        decrypted_draft_message: draft_trimmed,
                        decrypted_approved_text: app_trimmed
                    }
                end
              end
            end
        end
      end)
    else
      {:error, :missing_expected_revision} -> {:error, :missing_expected_revision}
      false -> {:error, :empty_approved_text}
      :error -> {:error, :unauthorized}
      nil -> {:error, :unauthorized}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Retrieves a trigger by ID for the owning professional.
  """
  @spec get_trigger(Accounts.Professional.t(), binary(), binary()) ::
          {:ok, Trigger.t()} | {:error, :unauthorized | :not_found}
  def get_trigger(%Accounts.Professional{} = professional, patient_id, trigger_id)
      when is_binary(patient_id) and is_binary(trigger_id) do
    with {:ok, valid_patient_id} <- Ecto.UUID.cast(patient_id),
         %Accounts.Patient{} = patient <-
           Accounts.get_patient_for_professional(professional.id, valid_patient_id) do
      case Ecto.UUID.cast(trigger_id) do
        {:ok, valid_trigger_id} ->
          case Repo.get_by(Trigger, id: valid_trigger_id, patient_id: valid_patient_id) do
            nil ->
              {:error, :not_found}

            trigger ->
              trigger_decrypted =
                case Clinical.patient_dek(patient, "trigger_get") do
                  {:ok, dek} -> decrypt_trigger_fields(trigger, dek)
                  _ -> trigger
                end

              {:ok, trigger_decrypted}
          end

        :error ->
          {:error, :not_found}
      end
    else
      _ -> {:error, :unauthorized}
    end
  end

  @doc """
  Lists trigger firings for a given patient in reverse chronological order.
  """
  @spec list_firings(Accounts.Professional.t(), binary()) ::
          {:ok, [TriggerFiring.t()]} | {:error, :unauthorized}
  def list_firings(%Accounts.Professional{} = professional, patient_id)
      when is_binary(patient_id) do
    with {:ok, valid_patient_id} <- Ecto.UUID.cast(patient_id),
         %Accounts.Patient{} <-
           Accounts.get_patient_for_professional(professional.id, valid_patient_id) do
      firings =
        TriggerFiring
        |> join(:inner, [f], t in assoc(f, :trigger))
        |> where([f, t], t.patient_id == ^valid_patient_id)
        |> preload([:trigger, :message])
        |> order_by([f], desc: f.fired_at)
        |> Repo.all()

      {:ok, firings}
    else
      _ -> {:error, :unauthorized}
    end
  end

  @doc """
  Lists one page of a patient's trigger firings, newest first
  (`fired_at` desc, `id` desc) with keyset pagination.

  Options:
    * `:limit` — page size (default #{@default_page_size}).
    * `:before` — cursor returned by a previous page; only older firings are returned.

  Returns `{:ok, %{entries: firings, more?: boolean, cursor: cursor | nil}}`.
  """
  @spec list_firings_page(Accounts.Professional.t(), binary(), keyword()) ::
          {:ok, %{entries: [TriggerFiring.t()], more?: boolean(), cursor: term()}}
          | {:error, :unauthorized}
  def list_firings_page(%Accounts.Professional{} = professional, patient_id, opts \\ [])
      when is_binary(patient_id) do
    limit = Keyword.get(opts, :limit, @default_page_size)

    with {:ok, valid_patient_id} <- Ecto.UUID.cast(patient_id),
         %Accounts.Patient{} <-
           Accounts.get_patient_for_professional(professional.id, valid_patient_id) do
      rows =
        TriggerFiring
        |> join(:inner, [f], t in assoc(f, :trigger))
        |> where([f, t], t.patient_id == ^valid_patient_id)
        |> firing_keyset_before(Keyword.get(opts, :before))
        |> order_by([f], desc: f.fired_at, desc: f.id)
        |> limit(^(limit + 1))
        |> preload([:trigger, :message])
        |> Repo.all()

      {entries, more?} = split_page(rows, limit)

      {:ok,
       %{entries: entries, more?: more?, cursor: page_cursor(entries, &{&1.fired_at, &1.id})}}
    else
      _ -> {:error, :unauthorized}
    end
  end

  defp firing_keyset_before(query, nil), do: query

  defp firing_keyset_before(query, {%DateTime{} = fired_at, id}) do
    where(
      query,
      [f],
      f.fired_at < ^fired_at or (f.fired_at == ^fired_at and f.id < ^id)
    )
  end

  @doc """
  Retrieves a produced message linked to a trigger for the owning professional,
  decrypting its content per patient DEK.
  """
  @spec get_produced_message(Accounts.Professional.t(), binary(), binary()) ::
          {:ok, Message.t(), String.t()} | {:error, :unauthorized | :not_found}
  def get_produced_message(%Accounts.Professional{} = professional, patient_id, message_id)
      when is_binary(patient_id) and is_binary(message_id) do
    with {:ok, valid_patient_id} <- Ecto.UUID.cast(patient_id),
         %Accounts.Patient{} = patient <-
           Accounts.get_patient_for_professional(professional.id, valid_patient_id) do
      case Ecto.UUID.cast(message_id) do
        {:ok, valid_message_id} ->
          query =
            from(m in Message,
              where:
                m.id == ^valid_message_id and m.patient_id == ^valid_patient_id and
                  not is_nil(m.trigger_id)
            )

          case Repo.one(query) do
            nil ->
              {:error, :not_found}

            message ->
              with {:ok, dek} <- Clinical.patient_dek(patient, "trigger_message_view"),
                   {:ok, text} <- PatientVault.decrypt(message.encrypted_content, dek) do
                {:ok, message, text}
              else
                _ -> {:error, :decryption_failed}
              end
          end

        :error ->
          {:error, :not_found}
      end
    else
      _ -> {:error, :unauthorized}
    end
  end

  # --- Internal Helpers ---

  defp validate_positive_integer_revision(val) when is_integer(val) and val > 0, do: {:ok, val}
  defp validate_positive_integer_revision(_), do: {:error, :missing_expected_revision}

  defp validate_and_extract_texts(attrs) do
    instruction =
      Map.get(attrs, :instruction) || Map.get(attrs, "instruction") || ""

    approved_text =
      Map.get(attrs, :approved_text) || Map.get(attrs, "approved_text") || ""

    draft_message =
      Map.get(attrs, :draft_message) || Map.get(attrs, "draft_message") || approved_text

    inst_trimmed = String.trim(to_string(instruction))
    app_trimmed = String.trim(to_string(approved_text))
    draft_trimmed = String.trim(to_string(draft_message))

    cond do
      inst_trimmed == "" -> {:error, :empty_instruction}
      app_trimmed == "" -> {:error, :empty_approved_text}
      true -> {:ok, inst_trimmed, draft_trimmed, app_trimmed}
    end
  end

  defp trigger_preview_chain do
    Application.get_env(:alethea, :trigger_preview_chain, TriggerPreviewChain)
  end

  @default_max_active_reactive_triggers 20

  @doc """
  Returns the globally configured maximum of active reactive triggers per
  patient (#450). Defaults to 20.
  """
  @spec max_active_reactive_triggers() :: pos_integer()
  def max_active_reactive_triggers do
    case Application.get_env(:alethea, :max_active_reactive_triggers) do
      limit when is_integer(limit) and limit > 0 -> limit
      _ -> @default_max_active_reactive_triggers
    end
  end

  defp patient_dek!(patient, reason) do
    case Clinical.patient_dek(patient, reason) do
      {:ok, dek} -> dek
      {:error, error} -> Repo.rollback(error)
    end
  end

  defp lock_patient!(patient_id) do
    Repo.one!(
      from(p in Accounts.Patient, where: p.id == ^patient_id, lock: "FOR UPDATE", select: p.id)
    )
  end

  # Must run inside the transaction that writes the new active reactive
  # trigger. The `FOR UPDATE` lock on the patient row serializes concurrent
  # create/activate/resume calls for the same patient, so the count cannot go
  # stale before the write. Rolls back with `:reactive_limit_reached`.
  defp ensure_reactive_slot!(patient_id) do
    lock_patient!(patient_id)

    active_count =
      Repo.aggregate(
        from(t in Trigger,
          where: t.patient_id == ^patient_id and t.kind == "reactive" and t.status == "active"
        ),
        :count
      )

    if active_count >= max_active_reactive_triggers(),
      do: Repo.rollback(:reactive_limit_reached),
      else: :ok
  end

  @default_daily_cap 5

  @doc """
  Returns the globally configured active trigger daily send cap per patient (Issue #444, S2).
  Defaults to 5.
  """
  @spec daily_cap() :: non_neg_integer()
  def daily_cap do
    case Application.get_env(:alethea, :active_trigger_daily_cap) do
      cap when is_integer(cap) and cap >= 0 ->
        cap

      _ ->
        case Application.get_env(:alethea, __MODULE__) do
          kw when is_list(kw) -> Keyword.get(kw, :daily_cap, @default_daily_cap)
          _ -> @default_daily_cap
        end
    end
  end

  @doc """
  Counts the number of active sends ("fired" firings) for a patient on their local calendar day (Issue #444, S2).
  """
  @spec count_daily_active_sends(binary(), DateTime.t(), String.t() | nil) :: non_neg_integer()
  def count_daily_active_sends(patient_id, %DateTime{} = instant, timezone)
      when is_binary(patient_id) do
    {start_utc, end_utc} = local_day_utc_range(instant, timezone)

    query =
      from f in TriggerFiring,
        join: t in assoc(f, :trigger),
        where:
          t.patient_id == ^patient_id and
            f.status == "fired" and
            f.fired_at >= ^start_utc and
            f.fired_at < ^end_utc,
        select: count(f.id)

    Repo.one(query) || 0
  end

  @doc """
  Calculates the [start_utc, end_utc) interval corresponding to the patient's local calendar day
  for the given UTC instant and timezone, properly handling DST transitions.
  """
  @spec local_day_utc_range(DateTime.t(), String.t() | nil) :: {DateTime.t(), DateTime.t()}
  def local_day_utc_range(%DateTime{} = instant, timezone) do
    database = Tz.TimeZoneDatabase

    tz =
      if is_binary(timezone) and Alethea.Accounts.Timezone.valid?(timezone) do
        timezone
      else
        "America/Santiago"
      end

    {:ok, local_dt} = DateTime.shift_zone(instant, tz, database)
    local_date = DateTime.to_date(local_dt)
    tomorrow = Date.add(local_date, 1)

    start_utc = local_midnight_to_utc(local_date, tz, database)
    end_utc = local_midnight_to_utc(tomorrow, tz, database)

    {start_utc, end_utc}
  end

  defp local_midnight_to_utc(%Date{} = date, tz, database) do
    case DateTime.new(date, ~T[00:00:00], tz, database) do
      {:ok, dt} ->
        {:ok, utc_dt} = DateTime.shift_zone(dt, "Etc/UTC", database)
        DateTime.truncate(utc_dt, :second)

      {:ambiguous, dt1, dt2} ->
        {:ok, u1} = DateTime.shift_zone(dt1, "Etc/UTC", database)
        {:ok, u2} = DateTime.shift_zone(dt2, "Etc/UTC", database)
        earlier = if DateTime.compare(u1, u2) == :lt, do: u1, else: u2
        DateTime.truncate(earlier, :second)

      {:gap, _dt1, dt2} ->
        {:ok, u2} = DateTime.shift_zone(dt2, "Etc/UTC", database)
        DateTime.truncate(u2, :second)
    end
  end

  @doc """
  Enqueues the RAG context outbox job for a `TriggerFiring` (GitHub #452):
  trigger firings index into the clinical-record RAG as never-evidence
  therapist context. Public because `AletheaJobs.ActiveTriggerWorker`
  inserts firings directly; failures to enqueue never block the firing
  itself.
  """
  @spec enqueue_firing_rag_event(TriggerFiring.t()) :: :ok
  def enqueue_firing_rag_event(%TriggerFiring{} = firing) do
    case Repo.get(Trigger, firing.trigger_id) do
      %Trigger{} = trigger ->
        ClinicalRecordOutbox.trigger_event(
          "trigger_firing_created",
          "trigger_firing",
          firing.id,
          trigger.patient_id,
          trigger.professional_id
        )
        |> Oban.insert!()

        :ok

      nil ->
        :ok
    end
  end

  @doc """
  Enqueues the `trigger_saved` RAG context outbox job for `trigger` (#452).
  Public so `AletheaJobs.ActiveTriggerWorker` can also sync trigger status
  transitions (crisis pause, fired) into the RAG index (Jorge TR-001).
  """
  @spec enqueue_trigger_rag_event(Trigger.t()) :: :ok
  def enqueue_trigger_rag_event(%Trigger{} = trigger) do
    ClinicalRecordOutbox.trigger_event(
      "trigger_saved",
      "trigger",
      trigger.id,
      trigger.patient_id,
      trigger.professional_id
    )
    |> Oban.insert!()

    :ok
  end

  def insert_content_free_audit!(professional_id, resource_id, action) do
    %AuditLog{}
    |> AuditLog.changeset(%{
      professional_id: professional_id,
      action: action,
      resource_type: "trigger",
      resource_id: resource_id,
      details: %{}
    })
    |> Repo.insert!()
  end

  def delete_scheduled_jobs(trigger_id) do
    Repo.delete_all(
      from(j in Oban.Job,
        where:
          j.worker == "AletheaJobs.ActiveTriggerWorker" and
            fragment("?->>'trigger_id' = ?", j.args, ^trigger_id) and
            j.state in ["scheduled", "available", "retryable"]
      )
    )
  end

  # Reactive triggers (#448) have no schedule and no job: reactivating one
  # only makes it eligible for matching again.
  defp reactivate_or_resume_trigger(
         %Trigger{kind: "reactive"} = trigger,
         professional_id,
         audit_action,
         dek
       ) do
    ensure_reactive_slot!(trigger.patient_id)

    updated =
      trigger
      |> Trigger.changeset(%{status: "active"})
      |> Repo.update!()

    insert_content_free_audit!(professional_id, trigger.id, audit_action)
    enqueue_trigger_rag_event(updated)

    decrypt_trigger_fields(updated, dek)
  end

  defp reactivate_or_resume_trigger(trigger, professional_id, audit_action, dek) do
    now = DateTime.utc_now()

    case trigger.schedule_type do
      "once" ->
        if DateTime.compare(trigger.scheduled_at, now) != :gt do
          Repo.rollback(
            {:expired_schedule,
             "El horario programado ya venció. Para programar un nuevo envío, crea un nuevo trigger con un horario futuro."}
          )
        else
          updated =
            trigger
            |> Trigger.changeset(%{status: "active", consecutive_delivery_failures: 0})
            |> Repo.update!()

          delete_scheduled_jobs(trigger.id)

          %{"trigger_id" => trigger.id}
          |> ActiveTriggerWorker.new(scheduled_at: trigger.scheduled_at)
          |> Oban.insert!()

          insert_content_free_audit!(professional_id, trigger.id, audit_action)
          enqueue_trigger_rag_event(updated)

          decrypt_trigger_fields(updated, dek)
        end

      recurring when recurring in ["daily", "weekly"] ->
        attrs = %{
          time: trigger.time,
          weekdays: trigger.weekdays,
          end_date: trigger.end_date
        }

        patient_tz = %{timezone: trigger.timezone}

        case Schedule.initial_occurrence(patient_tz, recurring, attrs, now) do
          {:ok, %{scheduled_at: next_scheduled_at}} ->
            updated =
              trigger
              |> Trigger.changeset(%{
                status: "active",
                scheduled_at: next_scheduled_at,
                consecutive_delivery_failures: 0
              })
              |> Repo.update!()

            delete_scheduled_jobs(trigger.id)

            %{"trigger_id" => trigger.id}
            |> ActiveTriggerWorker.new(scheduled_at: next_scheduled_at)
            |> Oban.insert!()

            insert_content_free_audit!(professional_id, trigger.id, audit_action)
            enqueue_trigger_rag_event(updated)

            decrypt_trigger_fields(updated, dek)

          {:error, {:invalid_end_date, _msg}} ->
            Repo.rollback(
              {:end_date_passed,
               "La fecha de fin ya expiró. Modifica la fecha de fin o crea un nuevo trigger."}
            )

          {:error, reason} ->
            Repo.rollback(reason)
        end
    end
  end

  defp decrypt_trigger_fields(trigger, dek) do
    dec_inst =
      case trigger.instruction && PatientVault.decrypt(trigger.instruction, dek) do
        {:ok, val} -> val
        _ -> nil
      end

    dec_draft =
      case trigger.draft_message && PatientVault.decrypt(trigger.draft_message, dek) do
        {:ok, val} -> val
        _ -> nil
      end

    dec_app =
      case trigger.approved_text && PatientVault.decrypt(trigger.approved_text, dek) do
        {:ok, val} -> val
        _ -> nil
      end

    dec_condition =
      case trigger.condition && PatientVault.decrypt(trigger.condition, dek) do
        {:ok, val} -> val
        _ -> nil
      end

    %{
      trigger
      | decrypted_instruction: dec_inst,
        decrypted_draft_message: dec_draft,
        decrypted_approved_text: dec_app,
        decrypted_condition: dec_condition
    }
  end

  defp extract_condition(attrs) do
    case fetch_attr(attrs, :condition) |> to_string() |> String.trim() do
      "" -> {:error, :empty_condition}
      condition -> {:ok, condition}
    end
  end

  defp fetch_attr(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
end
