defmodule Mix.Tasks.Alethea.Telegram.DevTunnelTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  alias Alethea.Foundation.Accounts.BotConfig
  alias Mix.Tasks.Alethea.Telegram.DevTunnel, as: DevTunnelTask

  @token "123456:synthetic-tunnel-token"
  @secret "synthetic_tunnel_secret"
  @host "calm-river-1234.trycloudflare.com"
  @webhook_url "https://#{@host}/webhooks/telegram"

  setup do
    Application.put_env(:alethea, :telegram_dev_tunnel_req_options, plug: {Req.Test, __MODULE__})
    on_exit(fn -> Application.delete_env(:alethea, :telegram_dev_tunnel_req_options) end)
    :ok
  end

  defp deps(overrides \\ []) do
    test = self()

    Keyword.merge(
      [
        with_services: fn fun -> fun.() end,
        ensure_started: fn :req -> {:ok, [:req]} end,
        lookup: fn "dev", log: false ->
          {:ok, %BotConfig{bot_token: @token, secret_token: @secret}}
        end,
        register: fn token, secret, url ->
          send(test, {:register, token, secret, url})

          {:ok,
           %{
             status: :registered,
             webhook_url: url,
             allowed_updates: ["message"],
             pending_update_count: 0
           }}
        end,
        sleep: fn _ms -> :ok end
      ],
      overrides
    )
  end

  defp stub_tunnel_and_app do
    Req.Test.stub(__MODULE__, fn
      %{request_path: "/quicktunnel"} = conn -> Req.Test.json(conn, %{"hostname" => @host})
      %{request_path: "/health"} = conn -> Plug.Conn.send_resp(conn, 200, "ok")
    end)
  end

  # Runs the task and returns `{:ok | {:error, message}, stdout_and_logs}`.
  defp run_capturing(args, env, deps) do
    me = self()

    out =
      capture_io(fn ->
        log =
          capture_log([level: :debug], fn ->
            send(me, {:result, try_run(args, env, deps)})
          end)

        send(me, {:log, log})
      end)

    assert_received {:result, result}
    assert_received {:log, log}
    {result, out <> log}
  end

  defp try_run(args, env, deps) do
    DevTunnelTask.run(args, env, deps)
    :ok
  rescue
    error in Mix.Error -> {:error, Exception.message(error)}
  end

  test "registers the webhook against the tunnel hostname and prints no secrets" do
    stub_tunnel_and_app()

    {result, output} =
      run_capturing(["--metrics-url", "http://tunnel:2000"], :dev, deps())

    assert result == :ok
    assert_received {:register, @token, @secret, @webhook_url}
    assert output =~ "TELEGRAM_DEV_TUNNEL_HOST=#{@host}"
    assert output =~ @webhook_url
    refute output =~ @token
    refute output =~ @secret
  end

  test "refuses any environment other than dev before doing any work" do
    {result, output} = run_capturing([], :test, deps(lookup: fn _, _ -> flunk("looked up") end))

    assert result == {:error, "TELEGRAM_DEV_TUNNEL_FAILED reason=development_only"}
    refute output =~ @token
  end

  test "fails clearly when no dev BotConfig is stored" do
    stub_tunnel_and_app()

    {result, _output} = run_capturing([], :dev, deps(lookup: fn "dev", _ -> :not_found end))

    assert {:error, message} = result
    assert message =~ "TELEGRAM_DEV_TUNNEL_FAILED reason=bot_config_missing"
    assert message =~ "mix alethea.telegram.bootstrap"
  end

  test "fails clearly when the tunnel metrics endpoint is unreachable" do
    Req.Test.stub(__MODULE__, &Req.Test.transport_error(&1, :econnrefused))

    {result, output} = run_capturing([], :dev, deps())

    assert {:error, message} = result
    assert message =~ "TELEGRAM_DEV_TUNNEL_FAILED reason=tunnel_unreachable"
    refute output =~ @token
    refute_received {:register, _, _, _}
  end

  test "fails clearly when the tunnel reports an empty hostname" do
    Req.Test.stub(__MODULE__, &Req.Test.json(&1, %{"hostname" => ""}))

    {result, _output} = run_capturing([], :dev, deps())

    assert {:error, message} = result
    assert message =~ "TELEGRAM_DEV_TUNNEL_FAILED reason=hostname_unavailable"
  end

  test "--wait retries until the hostname appears" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(__MODULE__, fn
      %{request_path: "/health"} = conn ->
        Plug.Conn.send_resp(conn, 200, "ok")

      %{request_path: "/quicktunnel"} = conn ->
        case Agent.get_and_update(counter, &{&1, &1 + 1}) do
          0 -> Req.Test.json(conn, %{"hostname" => ""})
          _ -> Req.Test.json(conn, %{"hostname" => @host})
        end
    end)

    {result, _output} = run_capturing(["--wait", "5"], :dev, deps())

    assert result == :ok
    assert_received {:register, @token, @secret, @webhook_url}
  end

  test "fails clearly when the app never becomes reachable" do
    Req.Test.stub(__MODULE__, fn
      %{request_path: "/quicktunnel"} = conn -> Req.Test.json(conn, %{"hostname" => @host})
      %{request_path: "/health"} = conn -> Plug.Conn.send_resp(conn, 503, "")
    end)

    {result, _output} = run_capturing([], :dev, deps())

    assert {:error, message} = result
    assert message =~ "TELEGRAM_DEV_TUNNEL_FAILED reason=app_unreachable"
  end

  test "a registration failure is reported without the token or secret" do
    stub_tunnel_and_app()

    failing = fn _token, _secret, _url -> {:error, {:telegram, 401, "Unauthorized"}} end

    {result, output} = run_capturing([], :dev, deps(register: failing))

    assert {:error, message} = result
    assert message =~ "TELEGRAM_DEV_TUNNEL_FAILED"
    assert message =~ "Unauthorized"
    refute message <> output =~ @token
    refute message <> output =~ @secret
  end

  test "rejects unknown arguments with usage" do
    {result, _output} = run_capturing(["--bogus"], :dev, deps())
    assert {:error, "usage: mix alethea.telegram.dev_tunnel" <> _} = result
  end
end
