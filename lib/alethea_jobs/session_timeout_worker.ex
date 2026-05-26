defmodule AletheaJobs.SessionTimeoutWorker do
  use Oban.Worker,
    queue: :sessions,
    max_attempts: 3,
    unique: [fields: [:args], period: 40 * 60]

  alias Alethea.{Accounts, Clinical}
  alias Alethea.Clinical.{Session, SessionManager}

  require Logger

  @client Application.compile_env(:alethea, :whatsapp_client, Alethea.WhatsApp.Client)
  @roberta_worker Application.compile_env(:alethea, :roberta_worker, Alethea.AI.RoBERTaWorker)
  @session_summary_chain Application.compile_env(
                           :alethea,
                           :session_summary_chain,
                           Alethea.AI.Chains.SessionSummaryChain
                         )

  @goodbye_message """
  Tu sesión de hoy ha concluido. Tu terapeuta podrá revisar el resumen en el próximo encuentro.
  Hasta pronto.
  """

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"session_id" => session_id, "patient_id" => patient_id, "phone" => phone}
      }) do
    session = Alethea.Repo.get!(Session, session_id)

    if session.status == "closed" do
      :ok
    else
      run_close_flow(session, patient_id, phone)
    end
  end

  defp run_close_flow(session, patient_id, phone) do
    patient = Accounts.get_patient!(patient_id)

    with {:ok, closed_session} <- SessionManager.close_session(session),
         messages <- Clinical.list_session_messages(closed_session.id),
         texts <- decrypt_messages(messages),
         emotion_scores <- @roberta_worker.analyze_batch(texts),
         :ok <- Clinical.save_trends(patient, emotion_scores, closed_session),
         {:ok, summary_text} <- @session_summary_chain.run(texts, emotion_scores),
         {:ok, _summary} <-
           Clinical.save_summary(%{
             period_start: closed_session.started_at,
             period_end: closed_session.closed_at,
             summary_text: summary_text,
             status_level: extract_status_level(summary_text),
             type: "session",
             patient_id: patient.id
           }) do
      @client.send_message(phone, @goodbye_message)
      :ok
    else
      {:error, reason} ->
        Logger.error("SessionTimeoutWorker failed for session #{session.id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp decrypt_messages(messages) do
    Enum.map(messages, fn msg ->
      Clinical.decrypt_content(msg.encrypted_content)
    end)
  end

  defp extract_status_level(text) do
    cond do
      String.contains?(text, "Intervención") -> "Intervención Requerida"
      String.contains?(text, "Alerta") -> "Alerta"
      true -> "Estable"
    end
  end
end
