defmodule Alethea.ClinicalRecord.Outbox do
  @moduledoc """
  Builds content-free Oban job args for `Alethea.ClinicalRecord` domain
  events (sdd/clinical-record-foundation, GitHub #194). `event/2`
  allowlists via `Map.take/2` so extra/PII fields can never leak into
  `oban_jobs.args`, even if a future caller widens the candidate map.
  """

  alias Alethea.ClinicalRecord.{
    AIProposal,
    ClinicalNote,
    ClinicianObservation,
    ConsultationEvidence,
    FunctionalAnalysisDraft,
    TargetBehavior
  }

  alias AletheaJobs.ClinicalRecordOutboxWorker

  @allowed_args ~w(event resource_type resource_id patient_id professional_id)

  @doc """
  Builds the outbox job insert changeset for `event_type` from a
  persisted `TargetBehavior`, `ClinicalNote`, `ConsultationEvidence`,
  `ClinicianObservation`, `AIProposal`, or `FunctionalAnalysisDraft`.
  `args` is restricted to identifier fields only — see `@allowed_args`.
  """
  @spec event(
          String.t(),
          TargetBehavior.t()
          | ClinicalNote.t()
          | ConsultationEvidence.t()
          | ClinicianObservation.t()
          | AIProposal.t()
          | FunctionalAnalysisDraft.t()
        ) :: Ecto.Changeset.t()
  def event(event_type, record) when is_binary(event_type) do
    %{
      "event" => event_type,
      "resource_type" => resource_type(record),
      "resource_id" => record.id,
      "patient_id" => record.patient_id,
      "professional_id" => record.professional_id
    }
    |> Map.take(@allowed_args)
    |> ClinicalRecordOutboxWorker.new()
  end

  defp resource_type(%TargetBehavior{}), do: "target_behavior"
  defp resource_type(%ClinicalNote{}), do: "clinical_note"
  defp resource_type(%ConsultationEvidence{}), do: "consultation_evidence"
  defp resource_type(%ClinicianObservation{}), do: "clinician_observation"
  defp resource_type(%AIProposal{}), do: "ai_proposal"
  defp resource_type(%FunctionalAnalysisDraft{}), do: "functional_analysis_draft"
end
