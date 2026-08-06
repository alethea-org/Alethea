defmodule Alethea.Clinical do
  @moduledoc """
  Contexto clínico para guardar mensajes, leer el historial reciente y persistir resultados de IA.
  Gestiona también el ciclo de vida de sesiones y tendencias emocionales.
  """

  import Ecto.Query, warn: false

  alias Alethea.Repo
  alias Alethea.Clinical.{Message, Summary, Trend}
  alias Alethea.AI.Diagnosis
  alias Alethea.Clinical.EmotionAnalysis
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
          String.t() | nil
        ) ::
          {:ok, Message.t()} | {:error, term()}
  def save_message(
        patient,
        text,
        dek,
        direction,
        behavior_type,
        session_id \\ nil,
        telegram_message_id \\ nil
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
        if telegram_message_id,
          do: Map.put(attrs, :telegram_message_id, telegram_message_id),
          else: attrs

      %Message{}
      |> Message.changeset(attrs)
      |> Repo.insert()
      |> case do
        {:ok, message} ->
          {:ok, message}

        {:error, changeset} ->
          cond do
            Keyword.has_key?(changeset.errors, :telegram_message_id) && telegram_message_id ->
              # Telegram duplicates are surfaced as raw errors so the
              # worker treats them as retry-eligible (REQ-C3). The
              # Oban unique-period on `telegram_update_id` is the
              # first line of defence; this DB-level constraint is
              # the safety net for replays outside the Oban window.
              {:error, changeset}

            true ->
              {:error, changeset}
          end
      end
    end
  end

  @doc """
  Persists a `Message` for the Telegram channel (REQ-C3-worker-persists-message
  + REQ-C5-persist-inbound-message + REQ-C5-persist-outbound-reply).

  Unlike `save_message/7`, this variant takes the **foundation**
  `Alethea.Foundation.Accounts.Patient` (the row returned by
  `lookup_patient_by_chat_hash/1`) and the Telegram `message_id`. It
  resolves the legacy `Alethea.Accounts.Patient` via
  `Alethea.Foundation.Accounts.legacy_patient/1`, then delegates to
  `save_message/7` (passing `telegram_message_id` as the 7th arg) for
  the encryption + insert.

  The split between foundation and legacy Patient schemas is
  deliberate: the foundation row is the public identity surface
  (carries `telegram_chat_id_hash`, the tenant boundary); the legacy
  row backs the clinical pipeline (carries the DEK, the messages FK).
  This function is the single bridge.

  Returns `{:ok, %Message{}}` on success,
  `{:error, :not_linked}` if the foundation row has no
  `legacy_patient_id` set (the patient has not been onboarded to the
  clinical pipeline — should not happen in production for bound
  patients; surfaces the data integrity gap loudly),
  `{:error, :legacy_not_found}` if the referenced legacy row is gone,
  or `{:error, reason}` for downstream failures.

  ## Duplicate handling

  The `telegram_message_id` partial unique index rejects a second
  row for the same id; this function surfaces the changeset error to
  the caller — the worker treats it as a retry-eligible failure
  (REQ-C3-worker-persists-message "persistence failure crashes the
  job"). The Oban unique-period on `telegram_update_id` is the first
  line of defence; this DB-level constraint is the safety net for
  replays outside the Oban window.
  """
  @spec save_telegram_message(
          Alethea.Foundation.Accounts.Patient.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t() | nil,
          binary() | nil
        ) :: {:ok, Message.t()} | {:error, term()}
  def save_telegram_message(
        foundation_patient,
        text,
        direction,
        behavior_type,
        telegram_message_id,
        session_id \\ nil
      ) do
    case Alethea.Foundation.Accounts.legacy_patient(foundation_patient) do
      {:ok, legacy_patient} ->
        save_message(
          legacy_patient,
          text,
          nil,
          direction,
          behavior_type,
          session_id,
          telegram_message_id
        )

      :not_linked ->
        {:error, :not_linked}

      {:error, :legacy_not_found} ->
        {:error, :legacy_not_found}
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

  @spec get_message(binary()) :: {:ok, Message.t()} | {:error, :not_found}
  def get_message(message_id) do
    case Repo.get(Message, message_id) do
      nil -> {:error, :not_found}
      message -> {:ok, message}
    end
  end

  @spec get_message_emotions(binary()) :: {:ok, EmotionAnalysis.t()} | {:error, :not_found}
  def get_message_emotions(message_id) do
    case Repo.get_by(EmotionAnalysis, message_id: message_id) do
      nil -> {:error, :not_found}
      emotion -> {:ok, emotion}
    end
  end

  def list_session_messages(session_id) do
    Repo.all(
      from(m in Message,
        where: m.session_id == ^session_id and m.direction == "inbound"
      )
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
          from(t in Trend,
            where: t.patient_id == ^patient.id and t.indicator_name == ^label,
            order_by: [desc: t.recorded_at],
            limit: 1
          )
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

  @spec save_trends_from_analysis(EmotionAnalysis.t(), binary()) :: :ok
  def save_trends_from_analysis(%EmotionAnalysis{} = analysis, patient_id) do
    emotion_scores = [
      %{label: "joy", score: analysis.joy_score || 0.0},
      %{label: "sadness", score: analysis.sadness_score || 0.0},
      %{label: "anger", score: analysis.anger_score || 0.0},
      %{label: "fear", score: analysis.fear_score || 0.0},
      %{label: "neutral", score: analysis.neutral_score || 0.0}
    ]

    # save_trends espera un patient struct,，所以我们用虚拟结构
    fake_patient = %Alethea.Accounts.Patient{id: patient_id}
    save_trends(fake_patient, emotion_scores, nil)
  end

  def save_summary(attrs) do
    %Summary{}
    |> Summary.changeset(attrs)
    |> Repo.insert()
  end

  def list_session_summaries(patient_id, since) do
    Repo.all(
      from(s in Summary,
        where:
          s.patient_id == ^patient_id and
            s.type == "session" and
            s.period_start >= ^since
      )
    )
  end

  @spec list_daily_emotion_scores(binary(), DateTime.t()) :: [map()]
  def list_daily_emotion_scores(patient_id, since) do
    Repo.all(
      from ea in EmotionAnalysis,
        join: m in Message,
        on: ea.message_id == m.id,
        where:
          m.patient_id == ^patient_id and
            m.timestamp >= ^since and
            m.direction == "inbound",
        group_by: fragment("?::date", m.timestamp),
        order_by: [asc: fragment("?::date", m.timestamp)],
        select: %{
          date: fragment("?::date", m.timestamp),
          joy: avg(ea.joy_score),
          sadness: avg(ea.sadness_score),
          anger: avg(ea.anger_score),
          fear: avg(ea.fear_score),
          neutral: avg(ea.neutral_score)
        }
    )
  end

  def aggregate_trends(patient_id, since) do
    Repo.all(
      from(t in Trend,
        where: t.patient_id == ^patient_id and t.recorded_at >= ^since,
        group_by: t.indicator_name,
        select: {t.indicator_name, avg(t.score)}
      )
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
