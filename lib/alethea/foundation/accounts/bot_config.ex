defmodule Alethea.Foundation.Accounts.BotConfig do
  @moduledoc """
  The foundation v2 `BotConfig` schema — C-6: vault-sealed bot token.

  Stores the Telegram bot token and the webhook secret token as
  `Cloak.Ecto.Binary` ciphertext in the `foundation_bot_configs` table.
  One row per environment (`"dev" | "test" | "prod"`), enforced unique.

  ## Why a table (not a Vault slot)

  Per design Decision 4: a row in the DB is auditable, rotatable without
  a redeploy, and naturally scoped by environment. The `Cloak.Ecto`
  type (the `Alethea.Encryption.Binary` module, bound to the
  `Alethea.Encryption.Vault` AES-GCM key) is the column-level encryption
  primitive that protects the data at rest.

  ## Plaintext handling

  The schema exposes two logical plaintext fields — `:bot_token` and
  `:secret_token` — backed by the encrypted columns
  `token_ciphertext` and `secret_token_ciphertext` via Ecto's `:source`
  option. The `Cloak.Ecto.Binary` type encrypts the value on
  insert/update and decrypts it on load; callers always see the
  plaintext, the DB always stores the ciphertext. There is no path by
  which plaintext reaches the DB without going through Cloak.

  ## Boundary with the rest of the foundation

  This module is part of the `Alethea.Foundation.*` parallel namespace,
  following the same convention as the rest of the foundation
  (`Alethea.Foundation.Accounts.Patient`, etc.). Do not import this
  module and any legacy `Alethea.Accounts.*` module with a colliding
  short name in the same call site.

  See `openspec/sdd/telegram-paciente-foundation/specs/C-6-vault-sealed-bot-token/spec.md`
  for the full contract.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Alethea.Encryption.Binary
  alias Alethea.Repo

  @env_values ~w(dev test prod)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "foundation_bot_configs" do
    field :env, :string

    # Plaintext logical fields backed by the encrypted columns. The
    # `:source` option rebinds the field name to the on-disk column; the
    # `Cloak.Ecto.Binary` type handles encrypt-on-write / decrypt-on-read
    # transparently.
    field :bot_token, Binary, source: :token_ciphertext
    field :secret_token, Binary, source: :secret_token_ciphertext

    field :bot_username, :string

    timestamps(type: :utc_datetime)
  end

  @doc """
  Creates or updates a `BotConfig` row for the given env. The second
  `upsert/1` for the same env updates the existing row in place
  (enforced by the unique index on `env`).

  Returns `{:ok, %BotConfig{}}` on success, or
  `{:error, %Ecto.Changeset{}}` on validation failure.
  """
  def upsert(attrs) when is_map(attrs) do
    env = Map.fetch!(attrs, :env)

    case Repo.get_by(__MODULE__, env: env) do
      nil ->
        %__MODULE__{}
        |> changeset(attrs)
        |> Repo.insert()

      %__MODULE__{} = existing ->
        existing
        |> changeset(attrs)
        |> Repo.update()
    end
  end

  @doc """
  Returns the `BotConfig` row for the given env, or `:not_found` if none
  exists. The env is the canonical string (`"dev"`, `"test"`, `"prod"`).
  """
  def for_env(env) when is_binary(env) do
    case Repo.get_by(__MODULE__, env: env) do
      nil -> :not_found
      %__MODULE__{} = bot_config -> {:ok, bot_config}
    end
  end

  @doc false
  def changeset(bot_config, attrs) do
    bot_config
    |> cast(attrs, [:env, :bot_token, :secret_token, :bot_username])
    |> validate_required([:env, :bot_token, :secret_token, :bot_username])
    |> validate_inclusion(:env, @env_values)
    |> validate_length(:bot_token, min: 1)
    |> validate_length(:secret_token, min: 1)
    |> validate_length(:bot_username, min: 1)
    |> unique_constraint(:env)
  end
end
