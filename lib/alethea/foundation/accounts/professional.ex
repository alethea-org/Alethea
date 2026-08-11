defmodule Alethea.Foundation.Accounts.Professional do
  @moduledoc """
  The foundation v2 `Psicólogo` schema.

  ## Boundary with legacy

  This module is part of the `Alethea.Foundation.*` parallel namespace. The
  legacy `Alethea.Accounts.Professional` continues to back the existing
  `professionals` table. Future changes migrate the legacy to the foundation
  one slice at a time. Do not import both modules from a single caller until
  the migration is complete.

  ## Bridge to the legacy `professionals` row

  The `legacy_professional_id` column is the seam decided in issue #111
  (Option A — lazy provisioning, hash-copy). The foundation professional
  is an **owner record only**: it carries the foundation-side foreign
  keys (patients, audit) while the legacy row keeps owning the
  credential. The column is populated by
  `provision_foundation_professional/1`, never by `register_professional/1`
  (which mints a fresh credential from a plaintext password). See
  `Alethea.Foundation.Accounts.find_or_provision_foundation_professional/1`
  for the lazy-provisioning entry point.

  See `openspec/sdd/bootstrap-alethea-v2/specs/accounts/spec.md` for the
  full contract and the test scenarios in this directory for the
  acceptance criteria.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Alethea.Accounts.Professional, as: LegacyProfessional
  alias Alethea.Repo

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "foundation_professionals" do
    field :email, :string
    field :password_hash, :string
    field :full_name, :string
    field :mfa_secret, :string
    field :crisis_message, :string
    field :remember_token_hash, :binary
    field :remember_token_expires_at, :utc_datetime
    field :password, :string, virtual: true

    # Bridge to the legacy `professionals` row that backs the dashboard
    # login (REQ per #111, Option A). The FK is `on_delete: :nilify_all`
    # so deleting a legacy professional (GDPR, admin tooling) does not
    # cascade-delete the foundation identity row. See migration
    # `20260811205104_add_legacy_professional_id_to_foundation_professionals.exs`
    # and the unique index
    # `foundation_professionals_legacy_professional_id_unique` that
    # makes the lazy-provisioning helper race-safe.
    belongs_to :legacy_professional, LegacyProfessional, foreign_key: :legacy_professional_id

    timestamps(type: :utc_datetime)
  end

  @doc """
  Registers a new professional and persists the row in
  `foundation_professionals`. Hashes the `:password` virtual field into
  `:password_hash` before insert. Returns `{:ok, %Professional{}}` on
  success, or `{:error, %Ecto.Changeset{}}` on validation failure.
  """
  def register_professional(attrs) when is_map(attrs) do
    %__MODULE__{}
    |> changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Builds a changeset for a professional. Casts the standard fields plus
  the `:password` virtual field; hashes the password into
  `:password_hash`. Used by `register_professional/1` and by the
  future `update_professional/2` change.
  """
  def changeset(professional, attrs) do
    professional
    |> cast(attrs, [
      :email,
      :password,
      :mfa_secret,
      :full_name,
      :crisis_message,
      :remember_token_hash,
      :remember_token_expires_at,
      :legacy_professional_id
    ])
    |> validate_required([:email, :password, :full_name])
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+$/, message: "must have the @ sign and no spaces")
    |> validate_length(:password, min: 12, max: 72)
    |> unique_constraint(:email)
    |> unique_constraint(:legacy_professional_id,
      name: :foundation_professionals_legacy_professional_id_unique
    )
    |> put_password_hash()
  end

  defp put_password_hash(changeset) do
    case get_change(changeset, :password) do
      nil -> changeset
      password -> put_change(changeset, :password_hash, Pbkdf2.hash_pwd_salt(password))
    end
  end

  @doc """
  Provisions a foundation Professional row from a legacy
  `Alethea.Accounts.Professional`. Copies `email`, `full_name`, and the
  legacy `password_hash` **verbatim** (no re-hash — the plaintext was
  never available on this side, and a re-hash would invalidate the
  legacy credential) and links the two rows via `legacy_professional_id`.

  Intended for `Alethea.Foundation.Accounts.find_or_provision_foundation_professional/1`,
  the lazy-provisioning entry point. Callers that need to register a
  brand-new foundation credential should use `register_professional/1`
  instead — this function deliberately bypasses the `:password` virtual
  field and the `validate_required([:password])` constraint because the
  legacy hash IS the credential.

  Returns `{:ok, %Professional{}}` on success, or
  `{:error, %Ecto.Changeset{}}` on validation failure. A unique
  violation on `legacy_professional_id` (concurrent call won the race)
  is converted to a changeset error rather than a raised exception, so
  the caller can re-lookup the winning row.
  """
  def provision_foundation_professional(%LegacyProfessional{} = legacy) do
    %__MODULE__{}
    |> Ecto.Changeset.change(%{
      email: legacy.email,
      full_name: legacy.full_name,
      password_hash: legacy.password_hash,
      legacy_professional_id: legacy.id
    })
    |> validate_required([:email, :full_name, :password_hash, :legacy_professional_id])
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+$/, message: "must have the @ sign and no spaces")
    |> unique_constraint(:legacy_professional_id,
      name: :foundation_professionals_legacy_professional_id_unique
    )
    |> Repo.insert()
  end
end
