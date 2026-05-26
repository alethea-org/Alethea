defmodule Alethea.Clinical do
  @moduledoc """
  Contexto clínico para guardar mensajes, leer el historial reciente y persistir resultados de IA.
  """

  import Ecto.Query, warn: false

  alias Alethea.Repo
  alias Alethea.Clinical.Message
  alias Alethea.AI.Diagnosis
  alias Alethea.Accounts.EncryptionKey
  alias Alethea.Encryption.PatientVault
  alias Alethea.Encryption.ProfessionalKek

  @spec save_message(Alethea.Accounts.Patient.t(), String.t(), binary() | nil, String.t(), String.t(), String.t() | nil) ::
          {:ok, Message.t()} | {:error, term()} | {:error, :duplicate, Message.t()}
  def save_message(patient, text, dek, direction, behavior_type, whatsapp_message_id \\ nil) do
    with {:ok, dek} <- get_dek(patient, dek),
         {:ok, encrypted_content} <- PatientVault.encrypt(text, dek) do
      attrs = %{
        patient_id: patient.id,
        direction: direction,
        behavior_type: behavior_type,
        encrypted_content: encrypted_content,
        timestamp: DateTime.utc_now()
      }
      attrs = if whatsapp_message_id, do: Map.put(attrs, :whatsapp_message_id, whatsapp_message_id), else: attrs

      %Message{}
      |> Message.changeset(attrs)
      |> Repo.insert()
      |> case do
        {:ok, message} ->
          {:ok, message}

        {:error, changeset} ->
          if Keyword.has_key?(changeset.errors, :whatsapp_message_id) && whatsapp_message_id do
            case Repo.get_by(Message, whatsapp_message_id: whatsapp_message_id) do
              nil -> {:error, changeset}
              existing_message -> {:error, :duplicate, existing_message}
            end
          else
            {:error, changeset}
          end
      end
    end
  end

  @spec list_recent_messages(binary(), non_neg_integer()) :: [Message.t()]
  def list_recent_messages(patient_id, limit) when is_integer(limit) and limit > 0 do
    Message
    |> where(patient_id: ^patient_id)
    |> order_by(desc: :timestamp)
    |> limit(^limit)
    |> Repo.all()
  end

  @spec build_patient_context(Alethea.Accounts.Patient.t(), non_neg_integer()) :: {:ok, String.t()} | {:error, term()}
  def build_patient_context(patient, limit) do
    with {:ok, dek} <- patient_dek(patient) do
      patient
      |> list_recent_messages(limit)
      |> Enum.reverse()
      |> Enum.map(&decrypt_message_content(&1, dek))
      |> Enum.reduce_while({:ok, []}, fn
        {:ok, decrypted}, {:ok, acc} -> {:cont, {:ok, [decrypted | acc]}}
        {:error, reason}, _ -> {:halt, {:error, reason}}
      end)
      |> case do
        {:ok, decrypted_messages} ->
          {:ok, Enum.join(decrypted_messages, "\n")}

        error ->
          error
      end
    end
  end

  @spec save_ai_diagnosis(binary(), map()) :: {:ok, Diagnosis.t()} | {:error, term()}
  def save_ai_diagnosis(message_id, chain_result) do
    attrs = %{
      message_id: message_id,
      model_version: Map.get(chain_result, :model_version) || Map.get(chain_result, "model_version"),
      extracted_emotions:
        Map.get(chain_result, :extracted_emotions) || Map.get(chain_result, "extracted_emotions") || %{},
      ai_response: Map.get(chain_result, :response) || Map.get(chain_result, "response")
    }

    %Diagnosis{}
    |> Diagnosis.changeset(attrs)
    |> Repo.insert()
  end

  defp get_dek(_patient, dek) when is_binary(dek) and byte_size(dek) == 32, do: {:ok, dek}
  defp get_dek(patient, _), do: patient_dek(patient)

  defp patient_dek(patient) do
    patient = Repo.preload(patient, :professional)

    with %Alethea.Accounts.Professional{} = professional <- patient.professional,
         {:ok, kek} <- ProfessionalKek.load_kek(professional),
         %EncryptionKey{} = key <- Repo.get(EncryptionKey, patient.encryption_key_id),
         {:ok, dek} <- PatientVault.decrypt(key.encrypted_key, kek) do
      {:ok, dek}
    else
      nil -> {:error, :missing_encryption_key}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decrypt_message_content(%Message{} = message, dek) do
    PatientVault.decrypt(message.encrypted_content, dek)
  end
end
