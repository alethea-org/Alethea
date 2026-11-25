defmodule Alethea.Accounts.Professional do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "professionals" do
    field :email, :string
    field :password_hash, :string
    field :mfa_secret, :string
    field :full_name, :string
    field :crisis_message, :string
    field :welcome_message, :string
    field :timezone, :string, default: "Etc/UTC"
    field :remember_token_hash, :binary
    field :remember_token_expires_at, :utc_datetime
    field :password, :string, virtual: true

    has_many :patients, Alethea.Accounts.Patient
    has_many :audit_logs, Alethea.Accounts.AuditLog

    timestamps(type: :utc_datetime)
  end

  def changeset(professional, attrs) do
    professional
    |> cast(attrs, [
      :email,
      :password,
      :mfa_secret,
      :full_name,
      :crisis_message,
      :welcome_message,
      :timezone
    ])
    |> update_change(:email, &normalize_email/1)
    |> validate_required([:email, :full_name])
    |> validate_password_required(professional)
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+$/, message: "must have the @ sign and no spaces")
    |> validate_length(:password, min: 12, max: 72)
    |> validate_length(:welcome_message, max: 4096)
    |> Alethea.Accounts.Timezone.validate_timezone(:timezone)
    # The index is on `lower(email)` (see the
    # `canonicalize_professional_email` migration) and keeps this name.
    |> unique_constraint(:email, name: :professionals_email_index)
    |> put_password_hash()
  end

  @doc """
  Returns the canonical form of a professional email: trimmed and
  lowercased.

  The email is the professional's identity. Storage, lookup
  (`Alethea.Accounts.get_professional_by_email/1`), the admin role
  (`Alethea.Accounts.Admin.admin?/1`) and the demo admission allowlist
  (`Alethea.Accounts.AdmissionPolicy.allowed_email?/1`) all compare this
  form, and the database enforces uniqueness on `lower(email)`, so case
  or whitespace variants can never become separate accounts.
  """
  @spec normalize_email(String.t()) :: String.t()
  def normalize_email(email) when is_binary(email) do
    email |> String.trim() |> String.downcase()
  end

  # `:password` is virtual and never reloaded from the DB, so a
  # blanket `validate_required(:password)` would reject every partial
  # update of an existing professional (e.g. `save_crisis_message` /
  # `save_welcome_message` in `DashboardLive`, which only send the one
  # changed field). Password is required at registration (`professional`
  # has no `:id` yet) but optional on update of an already-persisted row.
  defp validate_password_required(changeset, %__MODULE__{id: nil}) do
    validate_required(changeset, [:password])
  end

  defp validate_password_required(changeset, %__MODULE__{}), do: changeset

  defp put_password_hash(changeset) do
    case get_change(changeset, :password) do
      nil -> changeset
      password -> put_change(changeset, :password_hash, Pbkdf2.hash_pwd_salt(password))
    end
  end
end
