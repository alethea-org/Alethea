defmodule Alethea.Foundation.Accounts.PatientAuthCode do
  @moduledoc """
  Ephemeral onboarding code (C-4, PR #4). Persists both the deep-link
  token (`kind: "deep_link"`, minted by `Alethea.Telegram.DeepLinkToken.mint/0`)
  and the six-digit web fallback code (`kind: "six_digit"`) that bind a
  Telegram chat to a `Alethea.Foundation.Accounts.Patient` row.

  ## TASK-4-1 scope (this commit)

  This commit ships the table + schema + `create_patient_auth_code/2`
  (the persistence half of `REQ-C4-mint-deep-link-token`). The
  eligibility check (`verify_patient_auth_code/3`) and the atomic
  bind-and-consume (`consume_patient_auth_code/2`) land in the next
  commit (TASK-4-2) in this same PR.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Alethea.Foundation.Accounts.Patient

  @kinds ~w(deep_link six_digit)

  @ttl_seconds 600

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "foundation_patient_auth_codes" do
    belongs_to :patient, Patient

    field :code, :string
    field :kind, :string
    field :expires_at, :utc_datetime
    field :used_at, :utc_datetime
    field :attempt_count, :integer, default: 0
    field :last_attempt_ip, :string

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(auth_code, attrs) do
    auth_code
    |> cast(attrs, [
      :patient_id,
      :code,
      :kind,
      :expires_at,
      :used_at,
      :attempt_count,
      :last_attempt_ip
    ])
    |> validate_required([:patient_id, :code, :kind, :expires_at])
    |> validate_inclusion(:kind, @kinds)
    |> unique_constraint([:patient_id, :code, :kind],
      name: :foundation_patient_auth_codes_patient_code_kind_unique
    )
  end

  @doc """
  Mints a fresh auth code for `patient_id`. `opts` must include
  `kind: "deep_link" | "six_digit"`.

  Per `REQ-C4-mint-deep-link-token`, the row is created with
  `expires_at = now + 10 min`, `used_at: nil`, `attempt_count: 0`,
  `last_attempt_ip: nil`.
  """
  @spec create_patient_auth_code(binary(), keyword()) ::
          {:ok, t()} | {:error, Ecto.Changeset.t()}
  def create_patient_auth_code(patient_id, opts) do
    kind = Keyword.fetch!(opts, :kind)
    code = generate_code(kind)

    expires_at =
      DateTime.utc_now()
      |> DateTime.add(@ttl_seconds, :second)
      |> DateTime.truncate(:second)

    %__MODULE__{}
    |> changeset(%{
      patient_id: patient_id,
      code: code,
      kind: kind,
      expires_at: expires_at,
      used_at: nil,
      attempt_count: 0,
      last_attempt_ip: nil
    })
    |> Alethea.Repo.insert()
  end

  # ----------------------------------------------------------------
  # Code generation
  # ----------------------------------------------------------------

  defp generate_code("deep_link"), do: Alethea.Telegram.DeepLinkToken.mint()

  defp generate_code("six_digit") do
    (:rand.uniform(1_000_000) - 1)
    |> Integer.to_string()
    |> String.pad_leading(6, "0")
  end

  @type t :: %__MODULE__{}
end
