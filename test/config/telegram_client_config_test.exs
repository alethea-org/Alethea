defmodule Alethea.TelegramClientConfigTest do
  use ExUnit.Case, async: false

  test "development runtime uses Req only when the demo adapter is explicitly enabled" do
    assert runtime_config_from_dotenv(
             "TELEGRAM_CLIENT_ADAPTER=req\nTELEGRAM_CHAT_ID_PEPPER=synthetic-test-pepper\n"
           )
           |> alethea_config(:telegram_client) ==
             Alethea.Telegram.Client.Req

    assert runtime_config_from_dotenv("")
           |> alethea_config(:telegram_client) == Alethea.Telegram.Client.Fake

    assert runtime_config_from_dotenv("TELEGRAM_CLIENT_ADAPTER=Req\n")
           |> alethea_config(:telegram_client) ==
             Alethea.Telegram.Client.Fake
  end

  test "development runtime maps the Telegram chat ID pepper without exposing it" do
    config = runtime_config_from_dotenv("TELEGRAM_CHAT_ID_PEPPER=synthetic-test-pepper\n")

    assert config
           |> alethea_config(:telegram_chat_id_pepper)
           |> is_binary()
  end

  test "development runtime fails closed when Req is enabled without a pepper" do
    assert_raise RuntimeError, ~r/TELEGRAM_CHAT_ID_PEPPER is missing or empty/, fn ->
      runtime_config_from_dotenv("TELEGRAM_CLIENT_ADAPTER=req\n")
    end
  end

  test "production runtime fails closed without a pepper" do
    assert_raise RuntimeError, ~r/TELEGRAM_CHAT_ID_PEPPER is missing or empty/, fn ->
      runtime_config_from_dotenv("", :prod)
    end
  end

  defp runtime_config_from_dotenv(dotenv_contents, env \\ :dev) do
    runtime_path = Path.expand("config/runtime.exs")

    dotenv_dir =
      Path.join(
        System.tmp_dir!(),
        "alethea-telegram-config-#{System.unique_integer([:positive])}"
      )

    original_env =
      Map.new(["TELEGRAM_CLIENT_ADAPTER", "TELEGRAM_CHAT_ID_PEPPER"], fn key ->
        {key, System.get_env(key)}
      end)

    File.mkdir_p!(dotenv_dir)
    File.write!(Path.join(dotenv_dir, ".env"), dotenv_contents)
    System.delete_env("TELEGRAM_CLIENT_ADAPTER")
    System.delete_env("TELEGRAM_CHAT_ID_PEPPER")

    on_exit(fn ->
      File.rm_rf!(dotenv_dir)

      Enum.each(original_env, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)

    File.cd!(dotenv_dir, fn -> Config.Reader.read!(runtime_path, env: env) end)
  end

  defp alethea_config(config, key) do
    config
    |> Keyword.fetch!(:alethea)
    |> Keyword.fetch!(key)
  end
end
