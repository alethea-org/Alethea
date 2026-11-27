defmodule AletheaJobs.WeeklyReportWorker do
  @moduledoc """
  Worker que genera un reporte semanal consolidado para el psicólogo.
  Agrega resúmenes de sesiones, mensajes del paciente y tendencias emocionales
  de los últimos 7 días.
  """
  use Oban.Worker, queue: :reports, max_attempts: 3

  alias Alethea.{Accounts, Clinical, AI.Sanitizer}
  alias AletheaJobs.SafeReason

  require Logger

  defp weekly_summary_chain,
    do: Application.get_env(:alethea, :weekly_summary_chain, Alethea.AI.Chains.WeeklySummaryChain)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"patient_id" => patient_id}}) do
    patient = Accounts.get_patient!(patient_id)
    seven_days_ago = DateTime.add(DateTime.utc_now(), -7 * 24 * 3600, :second)

    summaries = Clinical.list_session_summaries(patient_id, seven_days_ago)
    aggregated_trends = Clinical.aggregate_trends(patient_id, seven_days_ago)

    # Sanitizar los resúmenes antes de enviarlos a la IA
    # A summary whose patient key is gone decrypts to `nil` and is skipped.
    sanitized_summaries =
      for %{summary_text: text} = summary <- summaries, is_binary(text) do
        %{summary | summary_text: Sanitizer.sanitize(text)}
      end

    # The week's own patient messages let the report describe what happened,
    # even before any session has been closed and summarized.
    sanitized_messages =
      case Clinical.list_inbound_texts_since(patient, seven_days_ago) do
        {:ok, texts} -> Enum.map(texts, &Sanitizer.sanitize/1)
        {:error, _reason} -> []
      end

    with {:ok, report} <-
           weekly_summary_chain().run(%{
             summaries: sanitized_summaries,
             trends: aggregated_trends,
             messages: sanitized_messages
           }),
         {:ok, _summary} <-
           Clinical.save_summary(%{
             period_start: seven_days_ago,
             period_end: DateTime.utc_now() |> DateTime.truncate(:second),
             summary_text: report.summary_text,
             status_level: report.status_level,
             anxiety_score: report.anxiety_score,
             social_score: report.social_score,
             emotional_range: report.emotional_range,
             crisis_events: report.crisis_events,
             session_count: report.session_count,
             type: "weekly",
             patient_id: patient.id
           }) do
      :ok
    else
      {:error, reason} ->
        Logger.error(
          "WeeklyReportWorker failed for patient #{patient_id}: #{SafeReason.for_log(reason)}"
        )

        {:error, job_reason(reason)}
    end
  end

  # Oban stores the returned reason in `oban_jobs.errors`, outside the
  # patient-level encryption. A `Summary` changeset carries the weekly
  # narrative in `changes` (e.g. when the model returns a score outside
  # 0.0..1.0 and `Summary.changeset/2` rejects it), so only the keys of
  # the failed fields are kept.
  defp job_reason(%Ecto.Changeset{} = changeset),
    do: {:invalid_changeset, changeset.errors |> Keyword.keys() |> Enum.uniq()}

  defp job_reason(reason), do: reason
end
