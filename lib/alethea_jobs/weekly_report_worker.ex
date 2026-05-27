defmodule AletheaJobs.WeeklyReportWorker do
  @moduledoc """
  Worker que genera un reporte semanal consolidado para el psicólogo.
  Agrega resúmenes de sesiones y tendencias emocionales de los últimos 7 días.
  """
  use Oban.Worker, queue: :reports, max_attempts: 3

  alias Alethea.{Accounts, Clinical, AI.Sanitizer}

  require Logger

  @weekly_summary_chain Application.compile_env(
                          :alethea,
                          :weekly_summary_chain,
                          Alethea.AI.Chains.WeeklySummaryChain
                        )

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

    with {:ok, report_text} <- @weekly_summary_chain.run(sanitized_summaries, aggregated_trends),
         {:ok, _summary} <-
           Clinical.save_summary(%{
             period_start: seven_days_ago,
             period_end: DateTime.utc_now() |> DateTime.truncate(:second),
             summary_text: report_text,
             status_level: extract_status_level(report_text),
             type: "weekly",
             patient_id: patient.id
           }) do
      :ok
    else
      {:error, reason} ->
        Logger.error(
          "WeeklyReportWorker failed for patient #{patient_id}: #{inspect(reason)}"
        )

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
