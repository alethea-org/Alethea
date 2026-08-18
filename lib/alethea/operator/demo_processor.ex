defmodule Alethea.Operator.DemoProcessor do
  @moduledoc false

  import Ecto.Query

  alias Alethea.Accounts
  alias Alethea.Clinical.{EmotionAnalysis, Message}
  alias Alethea.Repo
  alias AletheaJobs.{EmotionAnalysisWorker, WeeklyReportWorker}

  @spec process(String.t(), atom()) ::
          {:ok, %{emotions_processed: non_neg_integer(), weekly_report: :generated}}
          | {:error,
             :development_only | :invalid_patient_id | :patient_not_found | :processing_failed}
  def process(patient_id, env \\ Mix.env()) do
    with :ok <- ensure_development(env),
         {:ok, patient_id} <- valid_patient_id(patient_id),
         {:ok, patient} <- patient(patient_id),
         {:ok, processed_count} <- process_pending_emotions(patient.id),
         :ok <- generate_weekly_report(patient.id) do
      {:ok, %{emotions_processed: processed_count, weekly_report: :generated}}
    end
  end

  defp ensure_development(:dev), do: :ok
  defp ensure_development(_env), do: {:error, :development_only}

  defp valid_patient_id(patient_id) when is_binary(patient_id) do
    case Ecto.UUID.cast(patient_id) do
      {:ok, patient_id} -> {:ok, patient_id}
      :error -> {:error, :invalid_patient_id}
    end
  end

  defp valid_patient_id(_patient_id), do: {:error, :invalid_patient_id}

  defp patient(patient_id) do
    case Accounts.get_patient!(patient_id) do
      nil -> {:error, :patient_not_found}
      patient -> {:ok, patient}
    end
  rescue
    Ecto.NoResultsError -> {:error, :patient_not_found}
  end

  defp process_pending_emotions(patient_id) do
    pending_message_ids(patient_id)
    |> Enum.reduce_while({:ok, 0}, fn message_id, {:ok, count} ->
      case EmotionAnalysisWorker.perform(%Oban.Job{args: %{"message_id" => message_id}}) do
        {:ok, _analysis} -> {:cont, {:ok, count + 1}}
        :ok -> {:cont, {:ok, count}}
        {:error, _reason} -> {:halt, {:error, :processing_failed}}
      end
    end)
  end

  defp pending_message_ids(patient_id) do
    Repo.all(
      from message in Message,
        left_join: analysis in EmotionAnalysis,
        on: analysis.message_id == message.id,
        where:
          message.patient_id == ^patient_id and
            message.direction == "inbound" and
            is_nil(analysis.id),
        order_by: [asc: message.timestamp, asc: message.id],
        select: message.id
    )
  end

  defp generate_weekly_report(patient_id) do
    case WeeklyReportWorker.perform(%Oban.Job{args: %{"patient_id" => patient_id}}) do
      :ok -> :ok
      {:error, _reason} -> {:error, :processing_failed}
    end
  end
end
