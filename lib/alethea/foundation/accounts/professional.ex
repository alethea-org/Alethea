defmodule Alethea.Foundation.Accounts.Professional do
  @moduledoc """
  The foundation v2 `Psicólogo` schema.

  ## Boundary with legacy

  This module is part of the `Alethea.Foundation.*` parallel namespace. The
  legacy `Alethea.Accounts.Professional` continues to back the existing
  `professionals` table. Future changes migrate the legacy to the foundation
  one slice at a time. Do not import both modules from a single caller until
  the migration is complete.

  See `openspec/sdd/bootstrap-alethea-v2/specs/accounts/spec.md` for the
  full contract and the test scenarios in this directory for the
  acceptance criteria.
  """

  use Ecto.Schema
  import Ecto.Changeset

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
      :remember_token_expires_at
    ])
    |> validate_required([:email, :password, :full_name])
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+$/, message: "must have the @ sign and no spaces")
    |> validate_length(:password, min: 12, max: 72)
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
