defmodule Alethea.Triggers do
  @moduledoc """
  Context module for managing patient one-shot triggers (Issue #440).
  """

  import Ecto.Query

  alias Alethea.Accounts
  alias Alethea.Accounts.AuditLog
  alias Alethea.AI.Chains.TriggerPreviewChain
  alias Alethea.Clinical
  alias Alethea.Clinical.Message
  alias Alethea.Encryption.PatientVault
  alias Alethea.Repo
  alias Alethea.Triggers.{Schedule, Trigger, TriggerFiring}
  alias AletheaJobs.ActiveTriggerWorker

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
         true <- trimmed != "" do
      trigger_preview_chain().run(%{instruction: trimmed})
    else
      :error -> {:error, :unauthorized}
      nil -> {:error, :unauthorized}
      false -> {:error, :empty_instruction}
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
        |> where([t], t.patient_id == ^valid_patient_id)
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
            not is_nil(t.approved_text)
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
          where: t.patient_id == ^valid_patient_id,
          select: %{
            total: count(t.id),
            active: count(fragment("CASE WHEN ? = 'active' THEN 1 END", t.status)),
            inactive: count(fragment("CASE WHEN ? = 'inactive' THEN 1 END", t.status)),
            fired: count(fragment("CASE WHEN ? = 'fired' THEN 1 END", t.status)),
            paused_by_crisis:
              count(fragment("CASE WHEN ? = 'paused_by_crisis' THEN 1 END", t.status)),
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

      stats =
        Repo.one(query) ||
          %{total: 0, active: 0, inactive: 0, fired: 0, paused_by_crisis: 0, needs_approval: 0}

      active_kind = %{
        total: stats.total,
        active: stats.active,
        inactive: stats.inactive,
        fired: stats.fired,
        paused_by_crisis: stats.paused_by_crisis,
        needs_approval: stats.needs_approval
      }

      reactive_kind = %{
        total: 0,
        active: 0,
        inactive: 0,
        fired: 0,
        paused_by_crisis: 0,
        needs_approval: 0
      }

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
          paused_by_crisis: stats.paused_by_crisis
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
            where: t.id == ^valid_trigger_id and t.patient_id == ^valid_patient_id,
            lock: "FOR UPDATE"
          )

        case Repo.one(query) do
          nil ->
            Repo.rollback(:not_found)

          %Trigger{status: "fired"} ->
            Repo.rollback(:already_fired)

          %Trigger{status: "inactive"} = trigger ->
            decrypt_trigger_fields(trigger, dek)

          %Trigger{status: status} = trigger when status in ["active", "paused_by_crisis"] ->
            updated =
              trigger
              |> Trigger.changeset(%{status: "inactive"})
              |> Repo.update!()

            delete_scheduled_jobs(trigger.id)
            insert_content_free_audit!(professional.id, trigger.id, "trigger_deactivated")

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
           Accounts.get_patient_for_professional(professional.id, valid_patient_id),
         {:ok, dek} <- Clinical.patient_dek(patient, "trigger_activate") do
      Repo.transaction(fn ->
        query =
          from(t in Trigger,
            where: t.id == ^valid_trigger_id and t.patient_id == ^valid_patient_id,
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
           Accounts.get_patient_for_professional(professional.id, valid_patient_id),
         {:ok, dek} <- Clinical.patient_dek(patient, "trigger_resume") do
      Repo.transaction(fn ->
        query =
          from(t in Trigger,
            where: t.id == ^valid_trigger_id and t.patient_id == ^valid_patient_id,
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

          %Trigger{status: "paused_by_crisis"} = trigger ->
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
        end

        length(triggers)
      end)
    else
      :error -> {:error, :invalid_patient_id}
    end
  end

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
              where: t.id == ^valid_trigger_id and t.patient_id == ^valid_patient_id,
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
            where: t.id == ^valid_trigger_id and t.patient_id == ^valid_patient_id,
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

                scheduled_at_res =
                  if trigger.status == "active" do
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

                    if trigger.status == "active" do
                      delete_scheduled_jobs(trigger.id)

                      %{"trigger_id" => trigger.id}
                      |> ActiveTriggerWorker.new(scheduled_at: scheduled_at)
                      |> Oban.insert!()
                    end

                    insert_content_free_audit!(professional.id, trigger.id, "trigger_approved")

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
            |> Trigger.changeset(%{status: "active"})
            |> Repo.update!()

          delete_scheduled_jobs(trigger.id)

          %{"trigger_id" => trigger.id}
          |> ActiveTriggerWorker.new(scheduled_at: trigger.scheduled_at)
          |> Oban.insert!()

          insert_content_free_audit!(professional_id, trigger.id, audit_action)

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
              |> Trigger.changeset(%{status: "active", scheduled_at: next_scheduled_at})
              |> Repo.update!()

            delete_scheduled_jobs(trigger.id)

            %{"trigger_id" => trigger.id}
            |> ActiveTriggerWorker.new(scheduled_at: next_scheduled_at)
            |> Oban.insert!()

            insert_content_free_audit!(professional_id, trigger.id, audit_action)

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

    %{
      trigger
      | decrypted_instruction: dec_inst,
        decrypted_draft_message: dec_draft,
        decrypted_approved_text: dec_app
    }
  end
end
