defmodule AletheaJobs.WeeklyReportWorker do
  @moduledoc """
  Worker que genera un reporte semanal consolidado para el psicólogo.
  Agrega resúmenes de sesiones y tendencias emocionales de los últimos 7 días.
  """
  use Oban.Worker, queue: :reports, max_attempts: 3

  alias Alethea.{Accounts, Clinical, AI.Sanitizer}

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
    sanitized_summaries =
      Enum.map(summaries, fn summary ->
        %{summary | summary_text: Sanitizer.sanitize(summary.summary_text)}
      end)

    with {:ok, report} <- weekly_summary_chain().run(sanitized_summaries, aggregated_trends),
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
        Logger.error("WeeklyReportWorker failed for patient #{patient_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
