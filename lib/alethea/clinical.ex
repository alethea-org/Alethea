defmodule Alethea.Clinical do
  @moduledoc """
  El contexto clínico para gestionar mensajes, diagnósticos y tendencias.
  """

  import Ecto.Query, warn: false
  alias Alethea.Repo
  alias Alethea.Clinical.Message
  alias Alethea.AI.Diagnosis
  alias Alethea.Encryption.PatientVault

  @doc """
  Guarda un mensaje clínico cifrado.
  """
  def save_message(patient, text, dek_bytes, direction, behavior_type, whatsapp_message_id \\ nil) do
    with {:ok, encrypted_content} <- PatientVault.encrypt(text, dek_bytes) do
      %Message{}
      |> Message.changeset(%{
        patient_id: patient.id,
        encrypted_content: encrypted_content,
        direction: direction,
        behavior_type: behavior_type,
        whatsapp_message_id: whatsapp_message_id,
        timestamp: DateTime.utc_now()
      })
      |> Repo.insert()
    end
  end

  @doc """
  Lista los mensajes recientes de un paciente para dar contexto a la IA.
  Retorna los mensajes ordenados por timestamp ascendente (para la conversación).
  """
  def list_recent_messages(patient_id, limit \\ 10) do
    Message
    |> where(patient_id: ^patient_id)
    |> order_by(desc: :inserted_at)
    |> limit(^limit)
    |> Repo.all()
    # Invertir para que queden en orden cronológico
    |> Enum.reverse()
  end

  @doc """
  Guarda el resultado de la inferencia de la IA.
  """
  def save_ai_diagnosis(message_id, %{model_version: version, ai_response: response} = result) do
    %Diagnosis{}
    |> Diagnosis.changeset(%{
      message_id: message_id,
      model_version: version,
      ai_response: response,
      extracted_emotions: Map.get(result, :extracted_emotions, %{}),
      detected_risk_level: Map.get(result, :detected_risk_level, "low")
    })
    |> Repo.insert()
  end
end
