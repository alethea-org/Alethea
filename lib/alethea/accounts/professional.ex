defmodule Alethea.Accounts.Professional do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "professionals" do
    field :email, :string
    field :password_hash, :string
    field :mfa_secret, :string
    field :password, :string, virtual: true

    has_many :patients, Alethea.Accounts.Patient

    timestamps(type: :utc_datetime)
  end

  def changeset(professional, attrs) do
    professional
    |> cast(attrs, [:email, :password, :mfa_secret])
    |> validate_required([:email, :password])
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
