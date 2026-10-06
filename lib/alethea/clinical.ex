defmodule Alethea.Clinical do
  @moduledoc """
  Contexto clínico para guardar mensajes, leer el historial reciente y persistir resultados de IA.
  Gestiona también el ciclo de vida de sesiones y tendencias emocionales.

  **Boundary note**: journaling del paciente (mensajes, resúmenes,
  tendencias) vive acá — es distinto de `Alethea.ClinicalRecord`, que
  guarda las conductas objetivo y notas clínicas que autora el
  profesional. Son tablas separadas, sin writer compartido, sin path
  de escritura de IA hacia `target_behaviors` o `clinical_notes`.
  Cualquier archivo que importe ambos DEBE aliasear uno explícitamente,
  ej. `alias Alethea.Clinical, as: Journaling`, para evitar colisión visual.
  """

  import Ecto.Query, warn: false

  alias Alethea.Repo
  alias Alethea.Clinical.{Message, Outbox, Summary, Trend}
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
    with {:ok, changeset} <-
           encrypted_message_changeset(
             patient,
             text,
             dek,
             direction,
             behavior_type,
             session_id,
             telegram_message_id
           ) do
      persist(changeset, direction, patient)
    end
  end

  defp encrypted_message_changeset(
         patient,
         text,
         dek,
         direction,
         behavior_type,
         session_id,
         telegram_message_id
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

      {:ok, Message.changeset(%Message{}, attrs)}
    end
  end

  # Inbound messages are the "voz del paciente" producer
  # (sdd/telegram-rag-ingestion-262, AD2): the Message row and the
  # `Clinical.Outbox` job commit atomically via `Ecto.Multi` so the
  # RAG indexer can never observe a persisted message with no
  # corresponding outbox event (or vice versa).
  #
  # Gated to `direction == "inbound"` ONLY (AD2 — key discovery): both
  # outbound call sites (`telegram_message_worker.ex`'s
  # `persist_and_enqueue_outbound/7` and `handle_crisis_path/9`)
  # already run INSIDE an enclosing `Repo.transaction`. Ecto nested
  # transactions take no savepoint — a failing inner
  # `Repo.transaction(multi)` would roll back the OUTER transaction,
  # after which the callers' own `Repo.rollback(reason)` in their
  # `else` branch could no longer run correctly. The outbound clause
  # below stays a byte-for-byte bare `Repo.insert/1` to keep that
  # path provably untouched.
  defp persist(changeset, "inbound", patient) do
    Ecto.Multi.new()
    |> Ecto.Multi.insert(:message, changeset)
    |> Oban.insert(:outbox_event, fn %{message: message} ->
      Outbox.event("patient_message_received", message, patient.professional_id)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{message: message}} ->
        {:ok, message}

      {:error, :message, changeset, _changes} ->
        # AD3: remap onto the exact `{:error, %Ecto.Changeset{}}` shape
        # the public contract (and the worker's telegram_message_id
        # duplicate-detection branch, plus
        # `AletheaJobs.SafeReason.for_log/1`'s changeset pattern match)
        # already expects from the pre-Multi bare `Repo.insert/1` path.
        {:error, changeset}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  defp persist(changeset, _direction, _patient) do
    Repo.insert(changeset)
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

  The partial unique index on `(patient_id, telegram_message_id)`
  rejects a second row for the same Telegram message in the same
  patient's conversation; this function surfaces the changeset error to
  the caller. Inbound callers that must survive a re-execution use
  `find_or_save_telegram_inbound/4` instead, which resumes the persisted
  row.
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

  @doc """
  Persists the inbound `Message` for a Telegram update, or returns the one
  already persisted for it (issue #390).

  The identity of an inbound is the Telegram `message_id` within the
  patient's conversation. A re-execution of the same job (Oban retry,
  concurrent execution, replay outside the Oban unique window) finds the
  existing row and resumes from it instead of failing on the unique
  index. The row is created together with its patient-voice outbox event
  exactly once (see `persist/3`).

  If two executions race on the insert, the loser's insert is rejected by
  the unique index and it returns the winner's row.

  Returns `{:ok, %Message{}}`, or the same errors as
  `save_telegram_message/6`.
  """
  @spec find_or_save_telegram_inbound(
          Alethea.Foundation.Accounts.Patient.t(),
          String.t(),
          String.t(),
          binary() | nil
        ) :: {:ok, Message.t()} | {:error, term()}
  def find_or_save_telegram_inbound(foundation_patient, text, telegram_message_id, session_id) do
    case Alethea.Foundation.Accounts.legacy_patient(foundation_patient) do
      {:ok, legacy_patient} ->
        case get_telegram_inbound(legacy_patient.id, telegram_message_id) do
          %Message{} = existing ->
            {:ok, existing}

          nil ->
            legacy_patient
            |> save_message(
              text,
              nil,
              "inbound",
              "spontaneous",
              session_id,
              telegram_message_id
            )
            |> resume_on_duplicate_inbound(legacy_patient.id, telegram_message_id)
        end

      :not_linked ->
        {:error, :not_linked}

      {:error, :legacy_not_found} ->
        {:error, :legacy_not_found}
    end
  end

  defp get_telegram_inbound(patient_id, telegram_message_id) do
    Repo.one(
      from(m in Message,
        where:
          m.patient_id == ^patient_id and m.direction == "inbound" and
            m.telegram_message_id == ^telegram_message_id
      )
    )
  end

  defp resume_on_duplicate_inbound(
         {:error, %Ecto.Changeset{} = changeset} = error,
         patient_id,
         telegram_message_id
       ) do
    with true <- unique_violation?(changeset, :telegram_message_id),
         %Message{} = winner <- get_telegram_inbound(patient_id, telegram_message_id) do
      {:ok, winner}
    else
      _ -> error
    end
  end

  defp resume_on_duplicate_inbound(result, _patient_id, _telegram_message_id), do: result

  defp unique_violation?(%Ecto.Changeset{errors: errors}, field) do
    Enum.any?(errors, fn
      {^field, {_message, opts}} -> Keyword.get(opts, :constraint) == :unique
      _other -> false
    end)
  end

  @doc """
  Persists the outbound reply to one inbound Telegram message (issue #390).

  The row records its provenance in `reply_to_message_id`, under a unique
  index: an inbound has at most one reply. The content is encrypted with
  the patient's DEK exactly like any other message. Its delivery starts
  as `"pending"` (see `claim_telegram_delivery/1`).

  Returns `{:error, :reply_already_exists}` when another execution already
  persisted the reply for this inbound; the caller reuses that reply
  (`get_telegram_reply/1`) instead of persisting or delivering a second
  one. Like every outbound save it is a bare insert, safe to call inside
  the caller's `Repo.transaction` (see `persist/3`).
  """
  @spec save_telegram_reply(
          Alethea.Foundation.Accounts.Patient.t(),
          String.t(),
          String.t(),
          binary(),
          binary() | nil
        ) :: {:ok, Message.t()} | {:error, :reply_already_exists} | {:error, term()}
  def save_telegram_reply(foundation_patient, text, behavior_type, inbound_message_id, session_id) do
    with {:ok, legacy_patient} <- linked_legacy_patient(foundation_patient),
         {:ok, changeset} <-
           encrypted_message_changeset(
             legacy_patient,
             text,
             nil,
             "outbound",
             behavior_type,
             session_id,
             nil
           ) do
      changeset
      |> Ecto.Changeset.put_change(:reply_to_message_id, inbound_message_id)
      |> Ecto.Changeset.put_change(:delivery_state, "pending")
      |> Repo.insert()
      |> case do
        {:ok, reply} ->
          {:ok, reply}

        {:error, %Ecto.Changeset{} = failed} = error ->
          if unique_violation?(failed, :reply_to_message_id),
            do: {:error, :reply_already_exists},
            else: error
      end
    end
  end

  @doc """
  Returns the reply persisted for an inbound Telegram message, or `nil`.
  """
  @spec get_telegram_reply(binary()) :: Message.t() | nil
  def get_telegram_reply(inbound_message_id) do
    Repo.get_by(Message, reply_to_message_id: inbound_message_id)
  end

  @doc """
  Decrypts a persisted reply so a resumed execution can deliver the
  content the clinical record already holds instead of generating a new
  one. The plaintext is returned to the caller only; it is never logged.
  """
  @spec telegram_reply_text(Alethea.Foundation.Accounts.Patient.t(), Message.t()) ::
          {:ok, String.t()} | {:error, term()}
  def telegram_reply_text(foundation_patient, %Message{} = reply) do
    with {:ok, legacy_patient} <- linked_legacy_patient(foundation_patient),
         {:ok, dek} <- patient_dek(legacy_patient) do
      decrypt_message_content(reply, dek)
    end
  end

  @typedoc """
  Delivery outcome of an outbound Telegram reply:

    * `"pending"` — persisted, no send in progress.
    * `"sending"` — one execution of the delivery job holds the claim.
    * `"sent"` — Telegram acknowledged the message.
    * `"ambiguous"` — the request may have reached Telegram and nobody
      knows whether it was delivered. Never resent.
    * `"failed"` — the retry budget ran out before any send.

  `nil` means the row is not a tracked reply.
  """
  @type telegram_delivery_state :: String.t() | nil

  @doc """
  Claims the delivery of a persisted reply for one execution of the
  delivery job (`"pending"` -> `"sending"`), atomically.

  Returns `:claimed` to exactly one caller. Every other caller gets
  `{:not_claimed, state}` with the state it lost to, and must not send:
  the reply is already sent, in flight, or in an outcome that forbids a
  resend.
  """
  @spec claim_telegram_delivery(binary()) ::
          :claimed | {:not_claimed, telegram_delivery_state()}
  def claim_telegram_delivery(message_id) do
    case move_telegram_delivery(message_id, ["pending"], delivery_state: "sending") do
      :ok -> :claimed
      :unchanged -> {:not_claimed, telegram_delivery_state(message_id)}
    end
  end

  @doc """
  Returns the delivery state of a message, `nil` when it is untracked or
  does not exist.
  """
  @spec telegram_delivery_state(binary()) :: telegram_delivery_state()
  def telegram_delivery_state(message_id) do
    Repo.one(from(m in Message, where: m.id == ^message_id, select: m.delivery_state))
  end

  @doc """
  Records the outcome of a delivery attempt. Each outcome only applies
  from the states it may legitimately follow, so a late or duplicate
  report can never undo a stronger one:

    * `{:sent, telegram_message_id}` — acknowledged. Wins over
      `"ambiguous"`: the execution holding the claim learned the truth.
    * `:not_sent` — the holder knows its request never reached Telegram;
      the reply returns to `"pending"` for a later attempt.
    * `:ambiguous` — only from `"sending"`; never downgrades `"sent"`.
    * `:failed` — retry budget exhausted without a send.

  Returns `:ok` when the row moved and `:unchanged` otherwise (including
  untracked rows, which stay untouched).
  """
  @spec record_telegram_delivery(
          binary(),
          {:sent, integer() | String.t() | nil} | :not_sent | :ambiguous | :failed
        ) :: :ok | :unchanged
  def record_telegram_delivery(message_id, {:sent, telegram_message_id}) do
    move_telegram_delivery(message_id, ["pending", "sending", "ambiguous"],
      delivery_state: "sent",
      delivered_telegram_message_id: telegram_message_id && to_string(telegram_message_id)
    )
  end

  def record_telegram_delivery(message_id, :not_sent) do
    move_telegram_delivery(message_id, ["sending", "ambiguous"], delivery_state: "pending")
  end

  def record_telegram_delivery(message_id, :ambiguous) do
    move_telegram_delivery(message_id, ["sending"], delivery_state: "ambiguous")
  end

  def record_telegram_delivery(message_id, :failed) do
    move_telegram_delivery(message_id, ["pending", "sending", "ambiguous"],
      delivery_state: "failed"
    )
  end

  # Single conditional UPDATE: the state check and the write are one
  # statement, so concurrent executions cannot both observe the same
  # source state.
  defp move_telegram_delivery(message_id, from_states, changes) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {count, _} =
      from(m in Message, where: m.id == ^message_id and m.delivery_state in ^from_states)
      |> Repo.update_all(set: Keyword.put(changes, :updated_at, now))

    if count == 1, do: :ok, else: :unchanged
  end

  defp linked_legacy_patient(foundation_patient) do
    case Alethea.Foundation.Accounts.legacy_patient(foundation_patient) do
      {:ok, legacy_patient} -> {:ok, legacy_patient}
      :not_linked -> {:error, :not_linked}
      {:error, :legacy_not_found} -> {:error, :legacy_not_found}
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

  @doc """
  Devuelve el reporte semanal más reciente del paciente, o `nil` si no hay ninguno.

  No filtra por fecha: un reporte semanal cubre la semana *anterior*, así que su
  `period_start` casi siempre queda fuera de una ventana de 7 días.
  """
  @spec latest_weekly_summary(binary()) :: Summary.t() | nil
  def latest_weekly_summary(patient_id) do
    Repo.one(
      from(s in Summary,
        where: s.patient_id == ^patient_id and s.type == "weekly",
        order_by: [desc: s.period_end, desc: s.inserted_at],
        limit: 1
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
