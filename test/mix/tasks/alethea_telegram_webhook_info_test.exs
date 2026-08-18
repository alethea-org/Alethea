defmodule Mix.Tasks.Alethea.Telegram.WebhookInfoTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  alias Alethea.Foundation.Accounts.BotConfig

  test "fails closed outside development before loading configuration or making a request" do
    assert_raise Mix.Error, "TELEGRAM_WEBHOOK_INFO_FAILED reason=development_only", fn ->
      capture_io(:stderr, fn ->
        Mix.Tasks.Alethea.Telegram.WebhookInfo.run([], :test)
      end)
    end
  end

  test "emits only the allowlisted failure class without raw request errors" do
    lookup = fn "dev", options ->
      send(self(), {:bot_config_lookup, options})
      {:ok, %BotConfig{bot_token: "sealed-test-token"}}
    end

    output =
      capture_io(:stderr, fn ->
        log =
          capture_log([level: :debug], fn ->
            assert_raise Mix.Error, "TELEGRAM_WEBHOOK_INFO_FAILED reason=unexpected", fn ->
              Mix.Tasks.Alethea.Telegram.WebhookInfo.run(
                [],
                :dev,
                fn fun -> fun.() end,
                lookup,
                fn _token ->
                  {:error, %RuntimeError{message: "token=sealed-test-token raw body"}}
                end
              )
            end
          end)

        assert log == ""
      end)

    assert_receive {:bot_config_lookup, [log: false]}
    assert output == ""
  end

  test "starts Req before fetching webhook info" do
    lookup = fn "dev", log: false ->
      {:ok, %BotConfig{bot_token: "sealed-test-token"}}
    end

    assert_raise Mix.Error, "TELEGRAM_WEBHOOK_INFO_FAILED reason=timeout", fn ->
      capture_io(:stderr, fn ->
        Mix.Tasks.Alethea.Telegram.WebhookInfo.run(
          [],
          :dev,
          fn fun -> fun.() end,
          lookup,
          fn _token ->
            assert_receive {:http_client_started, :req}
            {:error, :timeout}
          end,
          fn :req ->
            send(self(), {:http_client_started, :req})
            {:ok, [:req]}
          end
        )
      end)
    end
  end
end
