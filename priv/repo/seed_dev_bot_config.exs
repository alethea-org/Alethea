# Bootstraps the "dev" row in foundation_bot_configs WITHOUT starting the
# full Alethea application (specifically without Alethea.Telegram.BotToken,
# which requires that row to exist in `init/1` and crashes the whole app if
# it's missing — a chicken-and-egg problem on first boot / fresh DB).
#
# Starts only what BotConfig needs: Postgrex/Ecto (for Alethea.Repo) and
# Alethea.Encryption.Vault (Cloak.Ecto encrypts token_ciphertext /
# secret_token_ciphertext on write).
#
# Idempotent: only inserts when no "dev" row exists yet, so it never
# overwrites a real bot token/secret someone loaded by hand.
#
# Run with:
#     mix run --no-start priv/repo/seed_dev_bot_config.exs

{:ok, _} = Application.ensure_all_started(:postgrex)
{:ok, _} = Application.ensure_all_started(:ecto_sql)

{:ok, _repo_pid} = Alethea.Repo.start_link()
{:ok, _vault_pid} = Alethea.Encryption.Vault.start_link()

alias Alethea.Foundation.Accounts.BotConfig

case BotConfig.for_env("dev") do
  {:ok, existing} ->
    IO.puts(
      "SKIP env=dev already exists id=#{existing.id} bot_username=#{existing.bot_username}"
    )

  :not_found ->
    attrs = %{
      env: "dev",
      bot_token: "dev_fake_bot_token",
      secret_token: "dev_fake_secret_token",
      bot_username: "alethea_dev_bot"
    }

    case BotConfig.upsert(attrs) do
      {:ok, row} ->
        IO.puts("OK env=#{row.env} id=#{row.id} bot_username=#{row.bot_username}")

      {:error, changeset} ->
        IO.inspect(changeset.errors, label: "FAILED")
        System.halt(1)
    end
end
