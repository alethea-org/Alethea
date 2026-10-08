defmodule AletheaJobs.RunningSummaryWorker do
  @moduledoc """
  Refreshes the protected factual running summary of one patient (#394).

  Args are `%{"patient_id" => id}` only. The job plans the next batch from
  persisted counts, unwraps the journaling DEK once (audit reason
  `"running_summary_generation"`), decrypts and sanitizes the window and the
  previous summary, asks the model, validates the answer, encrypts it under
  the same DEK and writes it with compare-and-swap. The DEK lives only in
  this process.

  Every error is returned as an atom (`:generation_failed`,
  `:invalid_summary`, `:persist_failed`) because Oban persists
  `inspect(reason)`; no summary or message text can reach `oban_jobs.errors`
  or the logs. After `max_attempts` the row stays as it was and a later
  inbound enqueues a fresh job (`:discarded` is not a unique state).
  """
  use Oban.Worker,
    queue: :running_summary,
    max_attempts: 3,
    unique: [
      keys: [:patient_id],
      period: :infinity,
      states: [:available, :scheduled, :retryable]
    ]

  require Logger

  alias Alethea.Accounts.Patient
  alias Alethea.AI.RunningSummaryValidator
  alias Alethea.AI.Sanitizer
  alias Alethea.Alerts.CrisisCopy
  alias Alethea.Clinical
  alias Alethea.Clinical.RunningSummary
  alias Alethea.Encryption.PatientVault
  alias Alethea.Repo

  @dek_reason "running_summary_generation"

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"patient_id" => patient_id}}) do
    case Repo.get(Patient, patient_id) do
      nil -> :ok
      %Patient{} = patient -> patient |> Repo.preload(:professional) |> run()
    end
  end

  defp run(patient) do
    case RunningSummary.plan(patient) do
      :not_due -> :ok
      {:build, plan} -> build(patient, plan)
      {:reset, observed} -> reset_and_rebuild(patient, observed)
    end
  end

  # A6: drop the row (CAS) and rebuild from scratch, never from old text.
  defp reset_and_rebuild(patient, observed) do
    with :ok <- RunningSummary.reset(patient, observed),
         {:build, plan} <- RunningSummary.plan(patient) do
      build(patient, plan)
    else
      {:error, :stale} -> {:cancel, :stale}
      _ -> :ok
    end
  end

  defp build(patient, plan) do
    result =
      with {:ok, dek} <- unwrap(patient),
           {:ok, request} <- request(patient, plan, dek),
           {:ok, summary} <- generate(request, patient),
           {:ok, ciphertext} <- encrypt(summary, dek) do
        RunningSummary.write(plan, ciphertext, patient)
      end

    finish(result, patient)
  end

  # Backlog: chain the next batch (the running job is not a unique state).
  defp finish(:ok, patient), do: RunningSummary.schedule_if_due(patient.id, "")

  defp finish({:error, :stale}, _patient), do: {:cancel, :stale}

  defp finish({:error, reason}, patient) when is_atom(reason) do
    Logger.warning("RunningSummaryWorker: failed (reason=#{reason}, patient_id=#{patient.id})")
    {:error, reason}
  end

  defp unwrap(patient) do
    case Clinical.patient_dek(patient, @dek_reason) do
      {:ok, dek} -> {:ok, dek}
      _ -> {:error, :generation_failed}
    end
  end

  defp request(patient, plan, dek) do
    with {:ok, turns} <- RunningSummary.window_turns(patient, plan, dek),
         {:ok, previous} <- previous_summary(plan, dek) do
      sanitized = Enum.map(turns, &%{&1 | content: Sanitizer.sanitize(&1.content)})
      {:ok, put_previous(%{turns: sanitized}, previous)}
    else
      _ -> {:error, :generation_failed}
    end
  end

  defp previous_summary(%{anchor_ciphertext: ciphertext}, dek) when is_binary(ciphertext),
    do: PatientVault.decrypt(ciphertext, dek)

  defp previous_summary(_plan, _dek), do: {:ok, nil}

  defp put_previous(request, nil), do: request

  defp put_previous(request, text),
    do: Map.put(request, :previous_summary, Sanitizer.sanitize(text))

  defp generate(request, patient) do
    case summarize(request) do
      {:ok, %{summary: text, truncated: false}} when is_binary(text) -> validate(text, patient)
      {:ok, %{truncated: _}} -> {:error, :invalid_summary}
      _ -> {:error, :generation_failed}
    end
  end

  # Exceptions are swallowed into an atom: their messages may carry text.
  defp summarize(request) do
    phi_worker().summarize(request)
  rescue
    _ -> {:error, :generation_failed}
  catch
    _, _ -> {:error, :generation_failed}
  end

  defp validate(text, patient) do
    case RunningSummaryValidator.validate(text, CrisisCopy.reply_text(patient)) do
      :ok -> {:ok, String.trim(text)}
      {:error, _} -> {:error, :invalid_summary}
    end
  end

  defp encrypt(summary, dek) do
    case PatientVault.encrypt(summary, dek) do
      {:ok, ciphertext} -> {:ok, ciphertext}
      _ -> {:error, :persist_failed}
    end
  end

  defp phi_worker, do: Application.get_env(:alethea, :phi_worker, Alethea.AI.PhiWorker)
end
