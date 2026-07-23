defmodule AletheaJobs.SessionTimeoutWorker do
  use Oban.Worker,
    queue: :sessions,
    max_attempts: 3,
    unique: [fields: [:args], period: 40 * 60]

  alias Alethea.{Accounts, Clinical, AI.Sanitizer}
  alias Alethea.Clinical.{Session, SessionManager}

  require Logger

  defp whatsapp_client,
    do: Application.get_env(:alethea, :whatsapp_client, Alethea.WhatsApp.Client)

  defp roberta_worker,
    do: Application.get_env(:alethea, :roberta_worker, Alethea.AI.RoBERTaWorker)

  defp session_summary_chain,
    do:
      Application.get_env(:alethea, :session_summary_chain, Alethea.AI.Chains.SessionSummaryChain)

  @goodbye_message """
  Tu sesión de hoy ha concluido. Tu terapeuta podrá revisar el resumen en el próximo encuentro.
  Hasta pronto.
  """

  # Telegram goodbye dispatch target (PR-1 #86). The raw `chat_id` is
  # never persisted at rest (only the HMAC `chat_id_hash`); both ride
  # in Oban job args at enqueue-time (the only place the raw chat_id
  # is available). The goodbye is enqueued on the safe lane with
  # `patient_id: nil` — goodbyes are nil-safe per design (see design.md).
  alias Alethea.Jobs.TelegramOutboundWorker

  @impl Oban.Worker
  # Telegram-channel args (PR-1 #86). Channel dispatch via Oban args
  # (no migration, no Session schema column) — see exploration.md's
  # "Channel-dispatch mechanism" decision.
  def perform(%Oban.Job{
        args: %{
          "session_id" => session_id,
          "patient_id" => patient_id,
          "channel" => "telegram",
          "chat_id" => chat_id,
          "chat_id_hash" => chat_id_hash
        }
      }) do
    session = Alethea.Repo.get!(Session, session_id)

    if session.status == "closed" do
      :ok
    else
      run_close_flow(session, patient_id,
        channel: "telegram",
        chat_id: chat_id,
        chat_id_hash: chat_id_hash
      )
    end
  end

  # Legacy WhatsApp args shape (unchanged, preserved by the
  # `process_message_worker.ex` pipeline). Absent `channel` + present
  # `phone` defaults to `"whatsapp"` (Req: WhatsApp Backward
  # Compatibility — the 2 pre-existing tests stay green unmodified).
  def perform(%Oban.Job{
        args:
          %{
            "session_id" => session_id,
            "patient_id" => patient_id,
            "phone" => phone
          } = args
      }) do
    channel = Map.get(args, "channel", "whatsapp")
    session = Alethea.Repo.get!(Session, session_id)

    if session.status == "closed" do
      :ok
    else
      run_close_flow(session, patient_id, channel: channel, phone: phone)
    end
  end

  defp run_close_flow(session, patient_id, opts) do
    patient = Accounts.get_patient!(patient_id)

    with {:ok, closed_session} <- SessionManager.close_session(session),
         messages <- Clinical.list_session_messages(closed_session.id),
         {:ok, texts} <- decrypt_messages(patient, messages),
         sanitized_texts = Enum.map(texts, &Sanitizer.sanitize/1),
         emotion_scores <- roberta_worker().analyze_batch(sanitized_texts),
         :ok <- Clinical.save_trends(patient, emotion_scores, closed_session),
         {:ok, summary_text} <- session_summary_chain().run(sanitized_texts, emotion_scores),
         {:ok, _summary} <-
           Clinical.save_summary(%{
             period_start: closed_session.started_at,
             period_end: closed_session.closed_at,
             summary_text: summary_text,
             status_level: extract_status_level(summary_text),
             type: "session",
             patient_id: patient.id
           }) do
      send_goodbye(opts, @goodbye_message)
      :ok
    else
      {:error, reason} ->
        Logger.error("SessionTimeoutWorker failed for session #{session.id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Channel switch on the goodbye send (PR-1 #86). The summary /
  # trends pipeline is channel-independent (it was always
  # channel-independent — only the final send was WhatsApp-coupled).
  # The goodbye body text is identical across channels; the dispatch
  # target differs:
  #
  #   * `"whatsapp"` → existing inline send via the WhatsApp client
  #     (unchanged behavior — the 2 pre-existing tests stay green
  #     unmodified).
  #   * `"telegram"` → enqueue a `TelegramOutboundWorker` goodbye job
  #     on the safe lane with `patient_id: nil` (goodbyes are
  #     nil-safe per design). The raw `chat_id` + `chat_id_hash`
  #     were carried in the job args from the enqueue site — they
  #     are NOT recoverable from any persisted Session column.
  defp send_goodbye(opts, body) when is_list(opts) do
    case Keyword.fetch!(opts, :channel) do
      "telegram" ->
        chat_id = Keyword.fetch!(opts, :chat_id)
        chat_id_hash = Keyword.fetch!(opts, :chat_id_hash)

        TelegramOutboundWorker.new(%{
          chat_id: chat_id,
          chat_id_hash: chat_id_hash,
          body: body,
          patient_id: nil
        })
        |> Oban.insert!()

        :ok

      "whatsapp" ->
        phone = Keyword.fetch!(opts, :phone)
        whatsapp_client().send_message(phone, body)

      other ->
        # Backstop: unknown channel (future addition). The session is
        # already closed + summary/trends persisted — a missing goodbye
        # is the gentlest possible failure mode. Logged, no raise.
        Logger.warning(
          "SessionTimeoutWorker: unknown channel for goodbye send (channel=#{inspect(other)})"
        )

        :ok
    end
  end

  defp decrypt_messages(patient, messages) do
    case Clinical.patient_dek(patient) do
      {:ok, dek} ->
        texts =
          Enum.map(messages, fn msg ->
            {:ok, text} = Clinical.decrypt_message_content(msg, dek)
            text
          end)

        {:ok, texts}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp extract_status_level(text) do
    cond do
      String.contains?(text, "Intervención") -> "Intervención Requerida"
      String.contains?(text, "Alerta") -> "Alerta"
      true -> "Estable"
    end
  end
end
