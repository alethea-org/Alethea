defmodule Mix.Tasks.Alethea.Demo.Process do
  use Mix.Task

  alias Alethea.Operator.{DemoProcessor, TaskRuntime}

  @shortdoc "Processes one patient's pending journal entries for a development demo"

  @moduledoc """
  Processes pending inbound journal entries and generates one weekly report for an
  explicitly selected patient. This operational aid is available only in `:dev`.

      mix alethea.demo.process --patient-id <patient-uuid>

  The task does not contact Telegram. It reports only processing status and counts;
  it never prints journal content, report content, or credentials.
  """

  @switches [patient_id: :string]

  @impl Mix.Task
  def run(args), do: run(args, Mix.env())

  @doc false
  def run(args, env) do
    case parse_patient_id(args) do
      {:ok, patient_id} -> run_processing(patient_id, env)
      {:error, reason} -> Mix.raise(failure_message(reason))
    end
  end

  defp run_processing(patient_id, env) do
    if env == :dev do
      result =
        TaskRuntime.with_services(fn ->
          DemoProcessor.process(patient_id, env)
        end)

      case result do
        {:ok, %{emotions_processed: count, weekly_report: :generated}} ->
          Mix.shell().info(
            "ALETHEA_DEMO_PROCESSING_COMPLETE emotions_processed=#{count} weekly_report=generated"
          )

        {:error, reason} ->
          Mix.raise(failure_message(reason))
      end
    else
      Mix.raise(failure_message(:development_only))
    end
  end

  defp parse_patient_id(args) do
    case OptionParser.parse(args, strict: @switches) do
      {[patient_id: patient_id], [], []} when is_binary(patient_id) and patient_id != "" ->
        {:ok, patient_id}

      _ ->
        {:error, :invalid_arguments}
    end
  end

  defp failure_message(:development_only),
    do: "ALETHEA_DEMO_PROCESSING_FAILED reason=development_only"

  defp failure_message(:invalid_arguments),
    do: "usage: mix alethea.demo.process --patient-id <patient-uuid>"

  defp failure_message(:invalid_patient_id),
    do: "ALETHEA_DEMO_PROCESSING_FAILED reason=invalid_patient_id"

  defp failure_message(:patient_not_found),
    do: "ALETHEA_DEMO_PROCESSING_FAILED reason=patient_not_found"

  defp failure_message(:processing_failed),
    do: "ALETHEA_DEMO_PROCESSING_FAILED reason=processing_failed"
end
