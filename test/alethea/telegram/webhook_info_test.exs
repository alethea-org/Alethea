defmodule Alethea.Telegram.WebhookInfoTest do
  use ExUnit.Case, async: false

  alias Alethea.Telegram.WebhookInfo

  setup do
    previous_options = Application.get_env(:alethea, :telegram_webhook_info_req_options)

    Application.put_env(:alethea, :telegram_webhook_info_req_options,
      plug: {Req.Test, __MODULE__}
    )

    on_exit(fn ->
      if previous_options do
        Application.put_env(:alethea, :telegram_webhook_info_req_options, previous_options)
      else
        Application.delete_env(:alethea, :telegram_webhook_info_req_options)
      end
    end)
  end

  test "maps only the allowlisted webhook fields" do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/bottest/getWebhookInfo"

      Req.Test.json(conn, %{
        "ok" => true,
        "result" => %{
          "url" => "https://example.test/webhooks/telegram?secret=hidden",
          "pending_update_count" => 3,
          "last_error_date" => 1_700_000_000,
          "last_error_message" => "Webhook response failed",
          "ip_address" => "203.0.113.1",
          "max_connections" => 40
        }
      })
    end)

    assert {:ok,
            %{
              webhook_url: "https://example.test/webhooks/telegram",
              pending_update_count: 3,
              last_error_date: "2023-11-14T22:13:20Z",
              last_error_message: "Webhook response failed"
            }} =
             WebhookInfo.fetch("test")
  end

  test "classifies documented Req transport errors without returning their details" do
    assert {:error, :timeout} =
             WebhookInfo.fetch("test", fn _options ->
               {:error, %Req.TransportError{reason: :timeout}}
             end)

    assert {:error, :dns} =
             WebhookInfo.fetch("test", fn _options ->
               {:error, %Req.TransportError{reason: :nxdomain}}
             end)

    assert {:error, :tls} =
             WebhookInfo.fetch("test", fn _options ->
               {:error, %Req.TransportError{reason: {:tls_alert, :unknown_ca}}}
             end)

    assert {:error, :connection} =
             WebhookInfo.fetch("test", fn _options ->
               {:error, %Req.TransportError{reason: :econnrefused}}
             end)
  end

  test "classifies provider status failures without reading their body" do
    assert {:error, :unauthorized} =
             WebhookInfo.fetch("test", fn _options ->
               {:ok, %Req.Response{status: 401, body: %{"description" => "secret provider body"}}}
             end)

    assert {:error, :provider} =
             WebhookInfo.fetch("test", fn _options ->
               {:ok, %Req.Response{status: 503, body: %{"description" => "secret provider body"}}}
             end)
  end

  test "passes the URL and safety options in Req 0.5 request form" do
    assert {:error, :provider} =
             WebhookInfo.fetch("test", fn options ->
               assert Keyword.fetch!(options, :url) ==
                        "https://api.telegram.org/bottest/getWebhookInfo"

               assert Keyword.fetch!(options, :retry) == false
               assert Keyword.fetch!(options, :redirect) == false

               {:ok, %Req.Response{status: 503}}
             end)
  end

  test "contains the prior incompatible Req invocation error at the request seam" do
    assert {:error, :unexpected} =
             WebhookInfo.fetch("test", fn _options ->
               raise ArgumentError, "invalid Req invocation"
             end)
  end

  test "treats unknown request shapes as unexpected without rendering them" do
    assert {:error, :unexpected} =
             WebhookInfo.fetch("test", fn _options ->
               {:error, %Req.TransportError{reason: {:unknown, "secret transport detail"}}}
             end)
  end

  test "rejects invalid successful provider responses" do
    assert {:error, :invalid_response} =
             WebhookInfo.fetch("test", fn _options ->
               {:ok, %Req.Response{status: 200, body: %{"ok" => true, "result" => %{}}}}
             end)
  end

  test "formats only allowlisted fields without multiline provider text" do
    assert WebhookInfo.format(%{
             webhook_url: "https://example.test/webhooks/telegram",
             pending_update_count: 0,
             last_error_message: "Request failed"
           }) == [
             "WEBHOOK_URL=https://example.test/webhooks/telegram",
             "PENDING_UPDATE_COUNT=0",
             "LAST_ERROR_MESSAGE=Request failed"
           ]
  end
end
