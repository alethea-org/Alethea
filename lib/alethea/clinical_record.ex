defmodule Alethea.ClinicalRecord do
  @moduledoc """
  Professional-authored clinical record: target behaviors and immutable
  clinical notes (sdd/clinical-record-foundation, GitHub #194).

  **Boundary note**: this context is distinct from `Alethea.Clinical`,
  which owns patient Telegram journaling (messages, summaries, trends).
  The two are structurally separate — different tables, no shared
  writer, no AI write path into `target_behaviors` or `clinical_notes`.
  Any file that imports both MUST alias one explicitly, e.g.
  `alias Alethea.Clinical, as: Journaling`, to avoid visual collision.

  `create_target_behavior/3` ships in PR2. `create_clinical_note/3`
  lands in PR3 — see `Alethea.ClinicalRecord.TargetBehavior`,
  `Alethea.ClinicalRecord.ClinicalNote`, `Alethea.ClinicalRecord.Audit`,
  and `Alethea.ClinicalRecord.Outbox` for the building blocks shipped
  in PR1.
  """

  require Logger

  alias Alethea.Accounts
  alias Alethea.Accounts.Professional
  alias Alethea.ClinicalRecord.{Audit, Outbox, TargetBehavior}
  alias Alethea.Encryption.PatientVault
  alias Alethea.Repo

  @doc """
  Authorizes via `Accounts.get_patient_for_professional/2`, encrypts
  `description` under the patient's DEK, and commits the target
  behavior row, a content-free audit row, and an outbox job in one
  `Ecto.Multi` — all-or-nothing.
  """
  @spec create_target_behavior(Professional.t(), Ecto.UUID.t(), String.t()) ::
          {:ok, TargetBehavior.t()}
          | {:error,
             :unauthorized
             | :not_found
             | :empty_plaintext
             | :invalid_key_size
             | :encryption_failed
             | Ecto.Changeset.t()
             | term()}
  def create_target_behavior(%Professional{} = professional, patient_id, description) do
    case Accounts.get_patient_for_professional(professional.id, patient_id) do
      nil ->
        case Audit.log_denied(professional.id, patient_id, "patient") do
          {:ok, _audit} ->
            :ok

          {:error, reason} ->
            Logger.warning("clinical_record log_denied failed: #{inspect(reason)}")
        end

        {:error, :unauthorized}

      patient ->
        with {:ok, kek} <- Accounts.load_professional_kek(professional),
             {:ok, dek} <- Accounts.load_patient_dek(patient, kek),
             {:ok, ciphertext} <- PatientVault.encrypt(description, dek) do
          insert_target_behavior(professional, patient, ciphertext)
        end
    end
  end

  defp insert_target_behavior(professional, patient, ciphertext) do
    Ecto.Multi.new()
    |> Ecto.Multi.insert(
      :record,
      TargetBehavior.changeset(%TargetBehavior{}, %{
        patient_id: patient.id,
        professional_id: professional.id,
        encrypted_description: ciphertext
      })
    )
    |> Ecto.Multi.insert(:audit, fn %{record: record} ->
      Audit.changeset(%Audit{
        professional_id: professional.id,
        action: "target_behavior_created",
        resource_type: "target_behavior",
        resource_id: record.id,
        outcome: "success"
      })
    end)
    |> Oban.insert(:outbox_event, fn %{record: record} ->
      Outbox.event("target_behavior_created", record)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{record: record}} ->
        {:ok, record}

      {:error, step, reason, _changes} ->
        Logger.warning("clinical_record multi failed at #{step}")
        {:error, reason}
    end
  end
end
