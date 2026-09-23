defmodule Alethea.ClinicalRecord.DismissedEvidenceSuggestion do
  @moduledoc """
  Records a professional's decision to dismiss an evidence suggestion for a
  target behavior. A dismissal identifies at least one RAG chunk or source
  resource and is removed when its target behavior is deleted.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "dismissed_evidence_suggestions" do
    field :chunk_id, :binary_id
    field :resource_id, :binary_id
    field :resource_type, :string
    field :dismissed_at, :utc_datetime_usec

    belongs_to :patient, Alethea.Accounts.Patient
    belongs_to :professional, Alethea.Accounts.Professional
    belongs_to :target_behavior, Alethea.ClinicalRecord.TargetBehavior

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @type t :: %__MODULE__{}

  @doc false
  def changeset(dismissal, attrs) do
    dismissal
    |> cast(attrs, [
      :patient_id,
      :professional_id,
      :target_behavior_id,
      :chunk_id,
      :resource_id,
      :resource_type,
      :dismissed_at
    ])
    |> validate_required([:patient_id, :professional_id, :target_behavior_id])
    |> validate_suggestion_identifier()
    |> default_dismissed_at()
    |> foreign_key_constraint(:target_behavior_id,
      name: :dismissed_evidence_suggestions_target_behavior_patient_fkey
    )
    |> unique_constraint([:target_behavior_id, :chunk_id],
      name: :dismissed_evidence_suggestions_target_behavior_chunk_index
    )
    |> unique_constraint([:target_behavior_id, :resource_id],
      name: :dismissed_evidence_suggestions_target_behavior_resource_index
    )
  end

  defp validate_suggestion_identifier(changeset) do
    if get_field(changeset, :chunk_id) || get_field(changeset, :resource_id) do
      changeset
    else
      add_error(changeset, :chunk_id, "at least one of chunk_id or resource_id must be present")
    end
  end

  defp default_dismissed_at(changeset) do
    if get_field(changeset, :dismissed_at) do
      changeset
    else
      put_change(changeset, :dismissed_at, DateTime.utc_now())
    end
  end
end
