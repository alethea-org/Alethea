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
  Lists active triggers for a given patient.
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
        |> where([t], t.patient_id == ^valid_patient_id and t.status == "active")
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

  defp insert_content_free_audit!(professional_id, resource_id, action) do
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

  defp decrypt_trigger_fields(trigger, dek) do
    dec_inst =
      case PatientVault.decrypt(trigger.instruction, dek) do
        {:ok, val} -> val
        _ -> nil
      end

    dec_draft =
      case PatientVault.decrypt(trigger.draft_message, dek) do
        {:ok, val} -> val
        _ -> nil
      end

    dec_app =
      case PatientVault.decrypt(trigger.approved_text, dek) do
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
