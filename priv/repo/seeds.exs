# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# Inside the script, you can read and write to any of your
# repositories directly:
#
#     Alethea.Repo.insert!(%Alethea.SomeSchema{})
#
# We recommend using the bang functions (`insert!`, `update!`
# and so on) as they will fail if something goes wrong.

if Mix.env() == :dev do
  Alethea.Operator.TaskRuntime.with_services(fn ->
    case Alethea.Foundation.Accounts.BotConfig.for_env("dev") do
      {:ok, _bot_config} ->
        :ok

      :not_found ->
        {:ok, _bot_config} =
          Alethea.Foundation.Accounts.BotConfig.upsert(%{
            env: "dev",
            bot_token: "development-placeholder-token",
            secret_token: "development-placeholder-secret",
            bot_username: "alethea_development_bot"
          })
    end
  end)
end
