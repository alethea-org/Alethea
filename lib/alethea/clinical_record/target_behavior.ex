defmodule Alethea.ClinicalRecord.TargetBehavior do
  @moduledoc """
  Encrypted target-behavior row authored by a patient's responsible
  professional (sdd/clinical-record-foundation, GitHub #194). Plaintext
  is never cast here — `Alethea.ClinicalRecord.create_target_behavior/3`
  (PR2) encrypts under the patient's DEK before calling `changeset/2`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "target_behaviors" do
    field :encrypted_description, :binary
    field :encryption_version, :integer, default: 1

    belongs_to :patient, Alethea.Accounts.Patient
    belongs_to :professional, Alethea.Accounts.Professional

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(target_behavior, attrs) do
    target_behavior
    |> cast(attrs, [:encrypted_description, :encryption_version, :patient_id, :professional_id])
    |> validate_required([:encrypted_description, :patient_id, :professional_id])
  end
end
