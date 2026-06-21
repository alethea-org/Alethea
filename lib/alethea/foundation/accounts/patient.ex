defmodule Alethea.Foundation.Accounts.Patient do
  @moduledoc """
  The foundation v2 `Paciente` schema.

  ## Boundary with legacy

  This module is part of the `Alethea.Foundation.*` parallel namespace. The
  legacy `Alethea.Accounts.Patient` continues to back the existing
  `patients` table. The two schemas share the `professional_id` FK
  convention so the `Alethea.Foundation.Tenant.scope_query/2` helper can
  operate on either.

  See `openspec/sdd/bootstrap-alethea-v2/specs/accounts/spec.md` for the
  full contract and the test scenarios in this directory for the
  acceptance criteria.

  ## Profile fields

  The `profile_*` and `emergency_contact_*` fields come from the
  `Perfil del paciente` section of `UBIQUITOUS_LANGUAGE.md`. They are
  optional and may be populated over time; they are NOT required at
  signup. `telegram_chat_id` is filled by the `telegram-paciente-foundation`
  change.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Alethea.Foundation.Accounts.Professional
  alias Alethea.Repo

  @status_values ~w(active archived deleted)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "foundation_patients" do
    belongs_to :professional, Professional

    # Bridge to the legacy `patients` table that backs the clinical
    # message pipeline (REQ-C3-worker-resolves-patient + C-5).
    # Nullable: a foundation row may exist before the patient is
    # onboarded to the clinical pipeline (e.g., created by foundation
    # admin tools). PR #4 (Telegram onboarding) populates this in
    # lockstep with the legacy row creation.
    # `on_delete: :nilify_all` on the FK so deleting a legacy patient
    # (GDPR right-to-erasure, admin tooling) does NOT cascade-delete
    # the foundation identity row — see migration
    # `20260620000002_add_legacy_patient_id_to_foundation_patients.exs`.
    belongs_to :legacy_patient, Alethea.Accounts.Patient, foreign_key: :legacy_patient_id

    field :alias, :string
    field :status, :string, default: "active"

    # REQ-C2-chat-id-stored-as-hmac: the column is the HMAC-SHA256 of
    # the raw chat_id (64-char lowercase hex), not the raw chat_id
    # itself. The column is `null: true` because a patient may exist
    # before they `/start` the bot. The partial unique index
    # `foundation_patients_telegram_chat_id_hash_unique` enforces
    # "at most one patient per hash" at the DB layer.
    field :telegram_chat_id_hash, :string

    field :profile_name, :string
    field :profile_birth_date, :date
    field :profile_gender, :string
    field :profile_language, :string
    field :profile_email, :string

    field :emergency_contact_name, :string
    field :emergency_contact_relationship, :string
    field :emergency_contact_phone, :string

    timestamps(type: :utc_datetime)
  end

  @doc """
  Creates a patient bound to the given professional. The
  `professional_id` is set programmatically (NOT in the changeset cast
  list) so callers cannot override the tenant boundary via attrs.
  """
  def create_patient(%Professional{id: professional_id}, attrs) when is_map(attrs) do
    %__MODULE__{}
    |> changeset(attrs)
    |> Ecto.Changeset.put_change(:professional_id, professional_id)
    |> Repo.insert()
  end

  def create_patient(nil, _attrs) do
    changeset =
      %__MODULE__{}
      |> changeset(%{})
      |> Ecto.Changeset.add_error(:professional_id, "can't be blank")

    {:error, %{changeset | action: :insert}}
  end

  @doc """
  Updates a patient. Only the fields in the changeset cast list are
  accepted; `professional_id` is never re-bindable through this path.
  """
  def update_patient(%__MODULE__{} = patient, attrs) when is_map(attrs) do
    patient
    |> changeset(attrs)
    |> Repo.update()
  end

  @doc false
  def changeset(patient, attrs) do
    patient
    |> cast(attrs, [
      :alias,
      :status,
      :telegram_chat_id_hash,
      :legacy_patient_id,
      :profile_name,
      :profile_birth_date,
      :profile_gender,
      :profile_language,
      :profile_email,
      :emergency_contact_name,
      :emergency_contact_relationship,
      :emergency_contact_phone
    ])
    |> validate_required([:alias])
    |> validate_inclusion(:status, @status_values)
    # REQ-C2-partial-unique-index: the DB layer rejects a second
    # patient bound to the same hash. The constraint is named on
    # the changeset so the violation is converted to a changeset
    # error (`:telegram_chat_id_hash` already taken) rather than a
    # raised `Ecto.ConstraintError`. This is the same pattern as
    # the existing `BotConfig` and `Patient.professional_id` indexes.
    |> unique_constraint(:telegram_chat_id_hash,
      name: :foundation_patients_telegram_chat_id_hash_unique
    )
  end
end
