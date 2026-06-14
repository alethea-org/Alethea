defmodule Alethea.Foundation.Accounts.Admin do
  @moduledoc """
  The foundation v2 `Admin` schema.

  ## Boundary with legacy and why no clinical access

  Per `openspec/CONTEXT.md`, the Admin role is "operador del SaaS ... sin
  acceso a datos clínicos de pacientes (separación de responsabilidades)".
  Admins manage billing, plans, support, and onboarding of psychologists
  only. They do NOT own patients, do NOT have a `professional_id` FK, and
  MUST NOT be allowed to read clinical data through the foundation APIs.

  ## Boundary with the rest of the foundation

  This module is part of the `Alethea.Foundation.*` parallel namespace.
  The legacy `Alethea.Accounts.*` is unaffected. Do not import both
  modules from a single caller until the migration is complete.

  See `openspec/sdd/bootstrap-alethea-v2/specs/accounts/spec.md` for the
  full contract and the test scenarios in this directory for the
  acceptance criteria.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Alethea.Repo

  @role_values ~w(superadmin support billing)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "foundation_admins" do
    field :email, :string
    field :password_hash, :string
    field :role, :string
    field :password, :string, virtual: true

    timestamps(type: :utc_datetime)
  end

  @doc """
  Registers a new admin and persists the row in `foundation_admins`.
  Hashes the `:password` virtual field into `:password_hash` before
  insert. Returns `{:ok, %Admin{}}` on success, or
  `{:error, %Ecto.Changeset{}}` on validation failure.

  Admin signup is **independent of the professional signup flow** — no
  `Professional` row is created.
  """
  def register_admin(attrs) when is_map(attrs) do
    %__MODULE__{}
    |> changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Builds a changeset for an admin. Casts the standard fields plus
  the `:password` virtual field; hashes the password into
  `:password_hash`.
  """
  def changeset(admin, attrs) do
    admin
    |> cast(attrs, [:email, :password, :role])
    |> validate_required([:email, :password, :role])
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+$/, message: "must have the @ sign and no spaces")
    |> validate_length(:password, min: 12, max: 72)
    |> validate_inclusion(:role, @role_values)
    |> unique_constraint(:email)
    |> put_password_hash()
  end

  defp put_password_hash(changeset) do
    case get_change(changeset, :password) do
      nil -> changeset
      password -> put_change(changeset, :password_hash, Pbkdf2.hash_pwd_salt(password))
    end
  end
end
