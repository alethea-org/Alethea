defmodule Alethea.Repo.Migrations.CreateFoundationBotConfigs do
  @moduledoc """
  C-6: Vault-sealed bot token storage.

  Creates the `foundation_bot_configs` table. Both `token_ciphertext` and
  `secret_token_ciphertext` are `:binary` columns encrypted at rest via
  `Cloak.Ecto.Binary` (the `Alethea.Encryption.Binary` type, bound to the
  `Alethea.Encryption.Vault` AES-GCM key). The `env` column is the per-env
  discriminator: dev / test / prod — enforced unique.

  ## Why a table (not a Vault slot)

  The `Alethea.Encryption.Vault` is an in-process GenServer holding a single
  AES key. It is the right home for app-wide *config* but the wrong home
  for per-env *sealed values*: a `BotConfig` row is auditable, rotatable
  without redeploy, and naturally scoped by environment. The `Cloak.Ecto`
  type is the column-level encryption primitive that uses the Vault's
  AES key for at-rest encryption.

  ## Why a unique index on `env`

  REQ-C6-distinct-per-env: dev / test / prod must never share a row. A
  dev / test misconfiguration that pointed at the prod row would route
  every test message to production. The unique index makes this
  impossible at the DB layer.
  """

  use Ecto.Migration

  def change do
    create table(:foundation_bot_configs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :env, :string, null: false
      add :token_ciphertext, :binary, null: false
      add :bot_username, :string, null: false
      add :secret_token_ciphertext, :binary, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:foundation_bot_configs, [:env], name: :foundation_bot_configs_env_unique)
  end
end
