defmodule Alethea.ClinicalRecord.Tombstone do
  @moduledoc """
  Per-record content-free tombstone (design D5,
  sdd/clinical-record-retention, GitHub #197). Content-free by
  construction: no free-text column exists, and both string columns are
  closed vocabularies validated by `validate_inclusion/3`.

  `target_behavior_id` carries **no FK** — under BR5's independent clocks
  the parent `target_behavior` can itself be legally deleted while a
  child tombstone survives, exactly the
  `Alethea.ClinicalRecord.ConsultationEvidence.source_id` no-FK precedent.
  """
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias Alethea.Repo

  # The six existing ClinicalRecord `@resource_types`.
  @resource_types ~w(target_behavior clinical_note consultation_evidence
                     clinician_observation ai_proposal functional_analysis_draft)
  @triggers ~w(sweep manual)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "clinical_record_tombstones" do
    field :resource_type, :string
    field :resource_id, :binary_id
    field :target_behavior_id, :binary_id
    field :deleted_at, :utc_datetime
    field :trigger, :string

    belongs_to :patient, Alethea.Accounts.Patient
    belongs_to :deleted_by, Alethea.Accounts.Professional

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @type t :: %__MODULE__{}

  @doc false
  def changeset(tombstone, attrs) do
    tombstone
    |> cast(attrs, [
      :resource_type,
      :resource_id,
      :patient_id,
      :target_behavior_id,
      :deleted_at,
      :deleted_by_id,
      :trigger
    ])
    |> validate_required([:resource_type, :resource_id, :patient_id, :deleted_at, :trigger])
    |> validate_inclusion(:resource_type, @resource_types)
    |> validate_inclusion(:trigger, @triggers)
    |> unique_constraint([:resource_type, :resource_id])
  end

  @doc """
  Looks up the tombstone for an exact `{resource_type, resource_id}`
  pair, if the resource has been legally deleted. Returns `nil` when the
  resource is still active (or never existed). This is the D4 read/write
  gate's single source of truth.
  """
  @spec for_resource(String.t(), Ecto.UUID.t()) :: t() | nil
  def for_resource(resource_type, resource_id) do
    Repo.get_by(__MODULE__, resource_type: resource_type, resource_id: resource_id)
  end

  @doc """
  Looks up the most recent tombstone for a given `target_behavior_id` and
  `resource_type` (BR10, sdd/clinical-record-retention, GitHub #197,
  Phase 4/Slice D). Used where the resource's own `resource_id` is no
  longer known to the caller once the content row has been hard-deleted
  — e.g. `Alethea.ClinicalRecord.get_functional_analysis_draft/3`, which
  only carries `target_behavior_id` (design's read/write gate section).
  Returns `nil` when no matching tombstone exists.
  """
  @spec for_target_behavior(Ecto.UUID.t(), String.t()) :: t() | nil
  def for_target_behavior(target_behavior_id, resource_type) do
    __MODULE__
    |> where(target_behavior_id: ^target_behavior_id, resource_type: ^resource_type)
    |> order_by(desc: :deleted_at)
    |> limit(1)
    |> Repo.one()
  end
end
