defmodule Alethea.Telegram.DevTunnelTest do
  @moduledoc """
  Reads the quick-tunnel hostname from cloudflared's metrics endpoint
  (issue #484). Every request goes to a `Req.Test` stub.
  """

  use ExUnit.Case, async: false

  alias Alethea.Telegram.DevTunnel

  setup do
    Application.put_env(:alethea, :telegram_dev_tunnel_req_options, plug: {Req.Test, __MODULE__})
    on_exit(fn -> Application.delete_env(:alethea, :telegram_dev_tunnel_req_options) end)
  end

  describe "hostname/1" do
    test "parses the hostname from GET <metrics>/quicktunnel" do
      Req.Test.expect(__MODULE__, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/quicktunnel"
        Req.Test.json(conn, %{"hostname" => "calm-river-1234.trycloudflare.com"})
      end)

      assert DevTunnel.hostname("http://tunnel:2000") ==
               {:ok, "calm-river-1234.trycloudflare.com"}
    end

    test "tolerates a trailing slash on the metrics URL" do
      Req.Test.expect(__MODULE__, fn conn ->
        assert conn.request_path == "/quicktunnel"
        Req.Test.json(conn, %{"hostname" => "a.trycloudflare.com"})
      end)

      assert DevTunnel.hostname("http://tunnel:2000/") == {:ok, "a.trycloudflare.com"}
    end

    test "an empty hostname is reported as unavailable" do
      Req.Test.expect(__MODULE__, &Req.Test.json(&1, %{"hostname" => ""}))
      assert DevTunnel.hostname("http://tunnel:2000") == {:error, :hostname_unavailable}
    end

    test "a response without a hostname is reported as unavailable" do
      Req.Test.expect(__MODULE__, &Req.Test.json(&1, %{"other" => 1}))
      assert DevTunnel.hostname("http://tunnel:2000") == {:error, :hostname_unavailable}
    end

    test "an unreachable metrics endpoint is reported as an unreachable tunnel" do
      Req.Test.expect(__MODULE__, &Req.Test.transport_error(&1, :econnrefused))
      assert DevTunnel.hostname("http://tunnel:2000") == {:error, :tunnel_unreachable}
    end

    test "a non-200 answer is reported as an unreachable tunnel" do
      Req.Test.expect(__MODULE__, &Plug.Conn.send_resp(&1, 404, "nope"))
      assert DevTunnel.hostname("http://tunnel:2000") == {:error, :tunnel_unreachable}
    end
  end

  describe "app_ready?/1" do
    test "is true on 200 and false otherwise" do
      Req.Test.expect(__MODULE__, &Plug.Conn.send_resp(&1, 200, "ok"))
      assert DevTunnel.app_ready?("http://app:4000/health")

      Req.Test.expect(__MODULE__, &Plug.Conn.send_resp(&1, 503, ""))
      refute DevTunnel.app_ready?("http://app:4000/health")

      Req.Test.expect(__MODULE__, &Req.Test.transport_error(&1, :econnrefused))
      refute DevTunnel.app_ready?("http://app:4000/health")
    end
  end
end
