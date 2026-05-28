defmodule Alethea.Clinical do
  @moduledoc """
  Contexto clínico para guardar mensajes, leer el historial reciente y persistir resultados de IA.
  Gestiona también el ciclo de vida de sesiones y tendencias emocionales.
  """

  import Ecto.Query, warn: false

  alias Alethea.Repo
  alias Alethea.Clinical.{Message, Summary, Trend}
  alias Alethea.AI.Diagnosis
  alias Alethea.Accounts.EncryptionKey
  alias Alethea.Encryption.PatientVault
  alias Alethea.Encryption.ProfessionalKek

  @spec save_message(
          Alethea.Accounts.Patient.t(),
          String.t(),
          binary() | nil,
          String.t(),
          String.t(),
          String.t() | nil,
          binary() | nil
        ) ::
          {:ok, Message.t()} | {:error, term()} | {:error, :duplicate, Message.t()}
  def save_message(
        patient,
        text,
        dek,
        direction,
        behavior_type,
        whatsapp_message_id \\ nil,
        session_id \\ nil
      ) do
    with {:ok, dek} <- get_dek(patient, dek),
         {:ok, encrypted_content} <- PatientVault.encrypt(text, dek) do
      attrs = %{
        patient_id: patient.id,
        direction: direction,
        behavior_type: behavior_type,
        encrypted_content: encrypted_content,
        timestamp: DateTime.utc_now() |> DateTime.truncate(:second),
        session_id: session_id
      }

      attrs =
        if whatsapp_message_id,
          do: Map.put(attrs, :whatsapp_message_id, whatsapp_message_id),
          else: attrs

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

  def list_session_messages(session_id) do
    Repo.all(
      from m in Message,
        where: m.session_id == ^session_id and m.direction == "inbound"
    )
  end

  @spec build_patient_context(Alethea.Accounts.Patient.t(), non_neg_integer()) ::
          {:ok, String.t()} | {:error, term()}
  def build_patient_context(patient, limit) do
    with {:ok, dek} <- patient_dek(patient) do
      patient.id
      |> list_recent_messages(limit)
      |> Enum.reverse()
      |> Enum.map(&decrypt_message_content(&1, dek))
      |> Enum.reduce_while({:ok, []}, fn
        {:ok, decrypted}, {:ok, acc} -> {:cont, {:ok, [decrypted | acc]}}
        {:error, reason}, _ -> {:halt, {:error, reason}}
      end)
      |> case do
        {:ok, decrypted_messages} ->
          {:ok, decrypted_messages |> Enum.reverse() |> Enum.join("\n")}

        error ->
          error
      end
    end
  end

  @spec save_ai_diagnosis(binary(), map()) :: {:ok, Diagnosis.t()} | {:error, term()}
  def save_ai_diagnosis(message_id, chain_result) do
    attrs = %{
      message_id: message_id,
      model_version:
        Map.get(chain_result, :model_version) || Map.get(chain_result, "model_version"),
      extracted_emotions:
        Map.get(chain_result, :extracted_emotions) || Map.get(chain_result, "extracted_emotions") ||
          %{},
      ai_response: Map.get(chain_result, :response) || Map.get(chain_result, "response")
    }

    %Diagnosis{}
    |> Diagnosis.changeset(attrs)
    |> Repo.insert()
  end

  def save_trends(patient, emotion_scores, _session) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Enum.each(emotion_scores, fn %{label: label, score: score} ->
      last_trend =
        Repo.one(
          from t in Trend,
            where: t.patient_id == ^patient.id and t.indicator_name == ^label,
            order_by: [desc: t.recorded_at],
            limit: 1
        )

      delta = if last_trend, do: score - last_trend.score, else: 0.0

      %Trend{}
      |> Trend.changeset(%{
        indicator_name: label,
        score: score,
        delta: delta,
        recorded_at: now,
        patient_id: patient.id
      })
      |> Repo.insert!()
    end)

    :ok
  end

  def save_summary(attrs) do
    %Summary{}
    |> Summary.changeset(attrs)
    |> Repo.insert()
  end

  def list_session_summaries(patient_id, since) do
    Repo.all(
      from s in Summary,
        where:
          s.patient_id == ^patient_id and
            s.type == "session" and
            s.period_start >= ^since
    )
  end

  def aggregate_trends(patient_id, since) do
    Repo.all(
      from t in Trend,
        where: t.patient_id == ^patient_id and t.recorded_at >= ^since,
        group_by: t.indicator_name,
        select: {t.indicator_name, avg(t.score)}
    )
    |> Enum.map(fn {name, avg_score} -> %{label: name, score: avg_score} end)
  end

  def decrypt_message_content(%Message{} = message, dek) do
    PatientVault.decrypt(message.encrypted_content, dek)
  end

  def get_dek(patient, dek \\ nil)
  def get_dek(_patient, dek) when is_binary(dek) and byte_size(dek) == 32, do: {:ok, dek}
  def get_dek(patient, _), do: patient_dek(patient)

  def patient_dek(patient) do
    patient = Repo.preload(patient, :professional)

    with %Alethea.Accounts.Professional{} = professional <- patient.professional,
         {:ok, kek} <- ProfessionalKek.load_kek(professional),
         %EncryptionKey{} = key <- Repo.get(EncryptionKey, patient.encryption_key_id),
         {:ok, dek} <- PatientVault.decrypt(key.encrypted_key, kek) do
      # Registrar acceso a datos sensibles (Auditoría)
      Alethea.Accounts.log_action(%{
        professional_id: professional.id,
        action: "PII_DECRYPT",
        resource_type: "Patient",
        resource_id: patient.id,
        details: %{reason: "clinical_context_loading"}
      })

      {:ok, dek}
    else
      nil -> {:error, :missing_encryption_key}
      {:error, reason} -> {:error, reason}
    end
  end
end
