defmodule Mix.Tasks.Alethea.Rag.Reindex do
  use Mix.Task

  import Ecto.Query

  alias Alethea.Accounts.Patient

  alias Alethea.ClinicalRecord.{
    AIProposal,
    ClinicalNote,
    ClinicianObservation,
    ConsultationEvidence,
    FunctionalAnalysisDraft,
    Outbox
  }

  alias Alethea.Operator.TaskRuntime
  alias Alethea.Repo

  @shortdoc "Re-enqueues outbox jobs to rebuild one patient's RAG projection on demand"

  @moduledoc """
  On-demand recovery tool for the non-authoritative RAG projection
  (sdd/clinical-rag-projection, GitHub #196, design section 6). It
  re-enqueues one outbox job per currently INDEX-eligible resource for
  the given patient through the SAME `Alethea.ClinicalRecord.Outbox` ->
  `AletheaJobs.ClinicalRecordOutboxWorker` ->
  `Alethea.ClinicalRecord.Rag.Indexer` path incremental ingest already
  uses. It does **not** embed inline and it never runs on any schedule
  — this is a manually triggered, operator-run command only (spec's
  "On-Demand Rebuild" requirement: no cron/periodic trigger exists in
  the codebase for this).

      mix alethea.rag.reindex --patient-id <uuid>
      mix alethea.rag.reindex --patient-id <uuid> --confirm

  Without `--confirm` the task performs a dry run: it reports how many
  outbox jobs WOULD be enqueued per resource type and writes nothing.
  With `--confirm` it actually enqueues the jobs.

  Only currently INDEX-eligible resources are re-enqueued (spec's
  ingest-eligibility table): `target_behavior` rows are structural
  metadata and are never re-enqueued, and `AIProposal` rows are
  included only when `status == "accepted"` (pending/edited/discarded
  proposals are never indexed).

  `Alethea.ClinicalRecord.Rag.Indexer.replace_chunks/2` deletes-then-
  inserts by `(source_resource_type, source_resource_id)`, so
  re-running this task (or Oban retrying/duplicating the same job)
  always converges to the same chunk set per resource — no duplicate
  chunks are ever produced, regardless of how many times a resource's
  job is enqueued or retried.
  """

  @switches [patient_id: :string, confirm: :boolean]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.config")

    case parse_args(args) do
      {:ok, patient_id, confirm?} ->
        TaskRuntime.with_services(fn -> run_reindex(patient_id, confirm?) end)

      {:error, reason} ->
        Mix.raise(failure_message(reason))
    end
  end

  defp parse_args(args) do
    case OptionParser.parse(args, strict: @switches) do
      {opts, [], []} ->
        case Keyword.get(opts, :patient_id) do
          patient_id when is_binary(patient_id) and patient_id != "" ->
            {:ok, patient_id, Keyword.get(opts, :confirm, false)}

          _ ->
            {:error, :invalid_arguments}
        end

      _ ->
        {:error, :invalid_arguments}
    end
  end

  defp run_reindex(patient_id, confirm?) do
    case fetch_patient(patient_id) do
      nil ->
        Mix.raise(failure_message(:patient_not_found))

      patient ->
        entries = eligible_entries(patient.id)
        counts = count_by_resource_type(entries)

        if confirm? do
          enqueued = Enum.count(entries, &enqueue!/1)

          Mix.shell().info(
            "ALETHEA_RAG_REINDEX_COMPLETE patient_id=#{patient.id} " <>
              format_counts(counts) <> " enqueued=#{enqueued}"
          )
        else
          Mix.shell().info(
            "ALETHEA_RAG_REINDEX_DRY_RUN patient_id=#{patient.id} " <>
              format_counts(counts) <> " total=#{length(entries)}"
          )
        end
    end
  end

  defp fetch_patient(patient_id) do
    case Ecto.UUID.cast(patient_id) do
      {:ok, _uuid} -> Repo.get(Patient, patient_id)
      :error -> nil
    end
  end

  @resource_kinds ~w(clinical_note consultation_evidence clinician_observation ai_proposal functional_analysis_draft)

  defp eligible_entries(patient_id) do
    clinical_notes(patient_id) ++
      consultation_evidences(patient_id) ++
      clinician_observations(patient_id) ++
      accepted_ai_proposals(patient_id) ++
      functional_analysis_drafts(patient_id)
  end

  defp clinical_notes(patient_id) do
    ClinicalNote
    |> where([r], r.patient_id == ^patient_id)
    |> Repo.all()
    |> Enum.map(&{"clinical_note_created", "clinical_note", &1})
  end

  defp consultation_evidences(patient_id) do
    ConsultationEvidence
    |> where([r], r.patient_id == ^patient_id)
    |> Repo.all()
    |> Enum.map(&{"consultation_evidence_created", "consultation_evidence", &1})
  end

  defp clinician_observations(patient_id) do
    ClinicianObservation
    |> where([r], r.patient_id == ^patient_id)
    |> Repo.all()
    |> Enum.map(&{"clinician_observation_created", "clinician_observation", &1})
  end

  # AIProposal is INDEX-eligible only when accepted — pending/edited/
  # discarded proposals are never indexed (spec's ingest-eligibility
  # table).
  defp accepted_ai_proposals(patient_id) do
    AIProposal
    |> where([r], r.patient_id == ^patient_id and r.status == "accepted")
    |> Repo.all()
    |> Enum.map(&{"ai_proposal_accepted", "ai_proposal", &1})
  end

  defp functional_analysis_drafts(patient_id) do
    FunctionalAnalysisDraft
    |> where([r], r.patient_id == ^patient_id)
    |> Repo.all()
    |> Enum.map(&{"functional_analysis_draft_saved", "functional_analysis_draft", &1})
  end

  defp count_by_resource_type(entries) do
    grouped =
      entries
      |> Enum.map(fn {_event, resource_type, _record} -> resource_type end)
      |> Enum.frequencies()

    Map.new(@resource_kinds, &{&1, Map.get(grouped, &1, 0)})
  end

  defp format_counts(counts) do
    @resource_kinds
    |> Enum.map(&"#{&1}=#{Map.fetch!(counts, &1)}")
    |> Enum.join(" ")
  end

  defp enqueue!({event, _resource_type, record}) do
    case event |> Outbox.event(record) |> Oban.insert() do
      {:ok, _job} -> true
      {:error, _reason} -> false
    end
  end

  defp failure_message(:invalid_arguments),
    do: "usage: mix alethea.rag.reindex --patient-id <uuid> [--confirm]"

  defp failure_message(:patient_not_found),
    do: "ALETHEA_RAG_REINDEX_FAILED reason=patient_not_found"
end
