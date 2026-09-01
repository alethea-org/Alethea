defmodule Alethea.ClinicalRecord.Audit do
  @moduledoc """
  Content-free audit entry for `Alethea.ClinicalRecord` actions
  (sdd/clinical-record-foundation, GitHub #194, resolution on #187).

  Persists to the same `audit_logs` table as
  `Alethea.Accounts.AuditLog`, but through a **closed struct** and a
  changeset that only accepts a fixed action/resource_type/outcome
  vocabulary. `details` is never accepted as free-form input — it is
  always machine-built from `outcome`, so its keys can never be
  anything other than a subset of `{"outcome"}`. This is deliberately
  NOT `Accounts.log_action/1`: that function's `details` map is
  unconstrained (e.g. `create_patient/2` puts `alias` into it), which
  would let clinical content leak into an audit row.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Alethea.Repo

  @actions ~w(target_behavior_created clinical_note_created clinical_record_access_denied
              consultation_evidence_created clinician_observation_created
              clinician_observation_updated ai_proposals_requested ai_proposal_accepted
              ai_proposal_edited ai_proposal_discarded functional_analysis_draft_saved)
  @resource_types ~w(target_behavior clinical_note patient consultation_evidence
                     clinician_observation ai_proposal functional_analysis_draft)
  @outcomes ~w(success denied)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "audit_logs" do
    field :action, :string
    field :resource_type, :string
    field :resource_id, :binary_id
    field :details, :map
    field :ip_address, :string
    field :user_agent, :string
    # Transient input only — never persisted directly. `changeset/1`
    # derives the persisted `details` map from this field, so a caller
    # can never inject an arbitrary `details` shape.
    field :outcome, :string, virtual: true

    belongs_to :professional, Alethea.Accounts.Professional

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

  @doc """
  Builds the insert changeset for a closed `%Audit{}` struct. Rejects
  any `action`/`resource_type`/`outcome` outside the fixed vocabulary
  above, and always derives `details` from `outcome` — a caller cannot
  pass a `details` map directly.
  """
  @spec changeset(t()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = audit) do
    %__MODULE__{}
    |> cast(Map.from_struct(audit), [
      :professional_id,
      :action,
      :resource_type,
      :resource_id,
      :outcome
    ])
    |> validate_required([:professional_id, :action, :resource_type, :outcome])
    |> validate_inclusion(:action, @actions)
    |> validate_inclusion(:resource_type, @resource_types)
    |> validate_inclusion(:outcome, @outcomes)
    |> put_details()
  end

  defp put_details(changeset) do
    case fetch_change(changeset, :outcome) do
      {:ok, outcome} -> put_change(changeset, :details, %{"outcome" => outcome})
      :error -> changeset
    end
  end

  @doc """
  Persists a single content-free denial audit row. Not run inside the
  create `Ecto.Multi` — a denied attempt never reaches it (spec:
  "no clinical row, no DEK/KEK load, and no outbox job occur").
  """
  @spec log_denied(Ecto.UUID.t(), Ecto.UUID.t(), String.t()) ::
          {:ok, t()} | {:error, Ecto.Changeset.t()}
  def log_denied(professional_id, resource_id, resource_type \\ "patient") do
    %__MODULE__{
      professional_id: professional_id,
      action: "clinical_record_access_denied",
      resource_type: resource_type,
      resource_id: resource_id,
      outcome: "denied"
    }
    |> changeset()
    |> Repo.insert()
  end
end
