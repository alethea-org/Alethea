defmodule Mix.Tasks.Alethea.Telegram.BootstrapTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Alethea.Foundation.Accounts.BotConfig
  alias Alethea.Repo

  @bot_token "123456:synthetic-bootstrap-token"
  @secret_token "synthetic_webhook_secret"
  @bot_username "alethea_synthetic_bot"

  setup do
    previous = telegram_env()
    set_telegram_env()

    on_exit(fn -> restore_env(previous) end)
    :ok
  end

  test "bootstraps a fresh database without starting the application or BotToken" do
    Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Repo.delete_all(BotConfig)
    Ecto.Adapters.SQL.Sandbox.checkin(Repo)
    :ok = Application.stop(:alethea)

    on_exit(fn ->
      {:ok, _} = Application.ensure_all_started(:alethea)
    end)

    output = capture_io(fn -> run_task(["--env", "test"]) end)

    refute Process.whereis(Alethea.Telegram.BotToken)
    refute output =~ @bot_token
    refute output =~ @secret_token

    {:ok, _} = Application.ensure_all_started(:alethea)
    Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    assert {:ok, %BotConfig{bot_username: @bot_username}} = BotConfig.for_env("test")

    Repo.delete_all(BotConfig)
    Ecto.Adapters.SQL.Sandbox.checkin(Repo)
  end

  test "updates the environment row idempotently without printing secrets" do
    Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Repo.delete_all(BotConfig)

    first_output = capture_io(fn -> run_task(["--env", "test"]) end)
    System.put_env("TELEGRAM_BOT_USERNAME", "alethea_updated_synthetic_bot")
    second_output = capture_io(fn -> run_task(["--env", "test"]) end)

    assert Repo.aggregate(BotConfig, :count) == 1

    assert {:ok, %BotConfig{bot_username: "alethea_updated_synthetic_bot"}} =
             BotConfig.for_env("test")

    for output <- [first_output, second_output] do
      refute output =~ @bot_token
      refute output =~ @secret_token
    end

    Repo.delete_all(BotConfig)
    Ecto.Adapters.SQL.Sandbox.checkin(Repo)
  end

  test "validates every required input without echoing its value" do
    for {name, message} <- [
          {"TELEGRAM_BOT_TOKEN", "TELEGRAM_BOT_TOKEN is required"},
          {"TELEGRAM_WEBHOOK_SECRET", "TELEGRAM_WEBHOOK_SECRET is required"},
          {"TELEGRAM_BOT_USERNAME", "TELEGRAM_BOT_USERNAME is required"}
        ] do
      value = System.get_env(name)
      System.put_env(name, "   ")

      assert_raise Mix.Error, message, fn ->
        capture_io(:stderr, fn -> run_task(["--env", "test"]) end)
      end

      System.put_env(name, value)
    end
  end

  defp run_task(args) do
    Mix.Task.reenable("alethea.telegram.bootstrap")
    Mix.Tasks.Alethea.Telegram.Bootstrap.run(args)
  end

  defp telegram_env do
    for name <- env_names(), into: %{}, do: {name, System.get_env(name)}
  end

  defp set_telegram_env do
    System.put_env("TELEGRAM_BOT_TOKEN", @bot_token)
    System.put_env("TELEGRAM_WEBHOOK_SECRET", @secret_token)
    System.put_env("TELEGRAM_BOT_USERNAME", @bot_username)
  end

  defp restore_env(previous) do
    Enum.each(previous, fn
      {name, nil} -> System.delete_env(name)
      {name, value} -> System.put_env(name, value)
    end)
  end

  defp env_names do
    ["TELEGRAM_BOT_TOKEN", "TELEGRAM_WEBHOOK_SECRET", "TELEGRAM_BOT_USERNAME"]
  end
end
