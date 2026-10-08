defmodule Alethea.ReleaseTest do
  use Alethea.DataCase, async: false

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  alias Alethea.Foundation.Accounts.BotConfig
  alias Alethea.Release
  alias Alethea.Repo

  # Synthetic values: no real bot, and every HTTP request below is served by
  # a `Req.Test` stub.
  @bot_token "123456:synthetic-release-token"
  @secret_token "synthetic_release_secret"
  @bot_username "alethea_release_bot"
  @webhook_url "https://app.example.test/webhooks/telegram"

  @telegram_vars %{
    "TELEGRAM_BOT_TOKEN" => @bot_token,
    "TELEGRAM_WEBHOOK_SECRET" => @secret_token,
    "TELEGRAM_BOT_USERNAME" => @bot_username
  }

  @app_env_keys [
    :telegram_webhook_url,
    :telegram_webhook_registration_req_options,
    :telegram_webhook_info_req_options
  ]

  describe "migrate/0" do
    test "leaves every migration applied and returns :ok on an up-to-date database" do
      assert Release.migrate() == :ok

      assert Enum.all?(Ecto.Migrator.migrations(Alethea.Repo), fn {status, _version, _name} ->
               status == :up
             end)
    end
  end

  describe "rollback/2" do
    test "is exported for bin/alethea eval" do
      Code.ensure_loaded!(Release)
      assert function_exported?(Release, :rollback, 2)
    end
  end

  describe "telegram_bootstrap/0" do
    setup :telegram_environment

    test "writes the row for the build environment, then reports it unchanged" do
      first = capture_io(fn -> assert Release.telegram_bootstrap() == :ok end)
      second = capture_io(fn -> assert Release.telegram_bootstrap() == :ok end)

      assert first == "TELEGRAM_BOT_CONFIG env=test status=created username=#{@bot_username}\n"
      assert second == "TELEGRAM_BOT_CONFIG env=test status=unchanged username=#{@bot_username}\n"

      assert Repo.aggregate(BotConfig, :count) == 1

      assert {:ok, %BotConfig{bot_token: @bot_token, secret_token: @secret_token}} =
               BotConfig.for_env("test")
    end

    test "rotates the stored values when the variables change" do
      capture_io(fn -> Release.telegram_bootstrap() end)
      System.put_env("TELEGRAM_WEBHOOK_SECRET", "synthetic_rotated_secret")

      output = capture_io(fn -> Release.telegram_bootstrap() end)

      assert output =~ "status=updated"
      refute output =~ "synthetic_rotated_secret"

      assert {:ok, %BotConfig{secret_token: "synthetic_rotated_secret"}} =
               BotConfig.for_env("test")
    end

    test "raises a fixed, secret-free line and writes nothing on invalid input" do
      System.put_env("TELEGRAM_WEBHOOK_SECRET", "#{@secret_token} with spaces")

      error =
        assert_raise RuntimeError, fn ->
          capture_io(fn -> Release.telegram_bootstrap() end)
        end

      assert error.message ==
               "TELEGRAM_BOOTSTRAP_FAILED env=test reason=TELEGRAM_WEBHOOK_SECRET must contain " <>
                 "1 to 256 letters, digits, underscores, or hyphens"

      System.delete_env("TELEGRAM_BOT_TOKEN")

      assert_raise RuntimeError, ~r/reason=TELEGRAM_BOT_TOKEN is required\z/, fn ->
        capture_io(fn -> Release.telegram_bootstrap() end)
      end

      assert Repo.aggregate(BotConfig, :count) == 0
    end
  end

  describe "telegram_check/0" do
    setup :telegram_environment

    test "succeeds on the stored row without the variables and without writing" do
      capture_io(fn -> Release.telegram_bootstrap() end)
      Enum.each(@telegram_vars, fn {name, _value} -> System.delete_env(name) end)

      {output, log} =
        with_log(fn -> capture_io(fn -> assert Release.telegram_check() == :ok end) end)

      assert output == "TELEGRAM_BOT_CONFIG env=test status=kept username=#{@bot_username}\n"

      for text <- [output, log] do
        refute text =~ @bot_token
        refute text =~ @secret_token
      end

      assert Repo.aggregate(BotConfig, :count) == 1
    end

    test "raises a fixed line naming the variables when no row is stored" do
      Enum.each(@telegram_vars, fn {name, _value} -> System.delete_env(name) end)

      error =
        assert_raise RuntimeError, fn ->
          capture_io(fn -> Release.telegram_check() end)
        end

      assert error.message =~ ~r/\ATELEGRAM_BOT_CONFIG_MISSING env=test reason=/

      for name <- ~w(TELEGRAM_BOT_TOKEN TELEGRAM_WEBHOOK_SECRET TELEGRAM_BOT_USERNAME) do
        assert error.message =~ name
      end

      assert Repo.aggregate(BotConfig, :count) == 0
    end
  end

  describe "telegram_register_webhook/0" do
    setup :telegram_environment

    setup do
      for key <- [:telegram_webhook_registration_req_options, :telegram_webhook_info_req_options] do
        Application.put_env(:alethea, key, plug: {Req.Test, __MODULE__})
      end

      :ok
    end

    test "registers the configured URL with the stored secret and prints a secret-free line" do
      capture_io(fn -> Release.telegram_bootstrap() end)
      Application.put_env(:alethea, :telegram_webhook_url, @webhook_url)

      expect_webhook_info(%{"url" => "", "pending_update_count" => 0})

      Req.Test.expect(__MODULE__, fn conn ->
        assert conn.request_path == "/bot#{@bot_token}/setWebhook"
        {:ok, body, _conn} = Plug.Conn.read_body(conn)

        assert Jason.decode!(body) == %{
                 "url" => @webhook_url,
                 "secret_token" => @secret_token,
                 "allowed_updates" => ["message"]
               }

        Req.Test.json(conn, %{"ok" => true, "result" => true})
      end)

      expect_webhook_info(%{
        "url" => @webhook_url,
        "pending_update_count" => 1,
        "allowed_updates" => ["message"]
      })

      {output, log} =
        with_log(fn ->
          capture_io(fn -> assert Release.telegram_register_webhook() == :ok end)
        end)

      assert output ==
               "TELEGRAM_WEBHOOK env=test status=registered url=#{@webhook_url} " <>
                 "allowed_updates=message pending_update_count=1\n"

      refute log =~ @bot_token
      refute log =~ @secret_token
      Req.Test.verify!(__MODULE__)
    end

    test "raises without the token when Telegram rejects the registration" do
      capture_io(fn -> Release.telegram_bootstrap() end)
      Application.put_env(:alethea, :telegram_webhook_url, @webhook_url)

      expect_webhook_info(%{"url" => "", "pending_update_count" => 0})

      Req.Test.expect(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_status(429)
        |> Req.Test.json(%{
          "ok" => false,
          "error_code" => 429,
          "description" => "Too Many Requests for /bot#{@bot_token}/setWebhook",
          "parameters" => %{"retry_after" => 9}
        })
      end)

      error =
        assert_raise RuntimeError, fn ->
          capture_io(fn -> Release.telegram_register_webhook() end)
        end

      assert error.message ==
               "TELEGRAM_WEBHOOK_REGISTRATION_FAILED env=test reason=Telegram rate limited " <>
                 "the request; retry after 9 seconds"
    end

    test "refuses to call Telegram without a configured public URL" do
      capture_io(fn -> Release.telegram_bootstrap() end)

      assert_raise RuntimeError, ~r/reason=no public webhook URL is configured/, fn ->
        capture_io(fn -> Release.telegram_register_webhook() end)
      end

      Req.Test.verify!(__MODULE__)
    end

    test "refuses to call Telegram before the bootstrap wrote the row" do
      Application.put_env(:alethea, :telegram_webhook_url, @webhook_url)

      assert_raise RuntimeError, ~r/reason=no Telegram bot configuration is stored/, fn ->
        capture_io(fn -> Release.telegram_register_webhook() end)
      end

      Req.Test.verify!(__MODULE__)
    end
  end

  describe "release overlays" do
    for script <- ~w(server migrate release telegram_bootstrap) do
      test "rel/overlays/bin/#{script} is an executable POSIX sh script" do
        path = Path.join("rel/overlays/bin", unquote(script))
        %File.Stat{mode: mode} = File.stat!(path)

        assert Bitwise.band(mode, 0o111) == 0o111
        assert String.starts_with?(File.read!(path), "#!/bin/sh\n")
      end
    end

    test "bin/server enables the endpoint and bin/migrate runs only migrations" do
      assert File.read!("rel/overlays/bin/server") =~ "PHX_SERVER=true exec ./alethea start"

      migrate = File.read!("rel/overlays/bin/migrate")
      assert migrate =~ "exec ./alethea eval Alethea.Release.migrate"
      refute migrate =~ "seed"
    end

    test "bin/telegram_bootstrap only registers the webhook when asked by name" do
      assert run_with_stub_release([]) == {"eval Alethea.Release.telegram_bootstrap\n", 0}

      assert run_with_stub_release(["register-webhook"]) ==
               {"eval Alethea.Release.telegram_register_webhook\n", 0}

      assert run_with_stub_release(["check"]) == {"eval Alethea.Release.telegram_check\n", 0}

      for args <- [
            ["register"],
            ["--register-webhook"],
            ["register-webhook", "extra"],
            ["check", "register-webhook"],
            [""]
          ] do
        assert {output, 64} = run_with_stub_release(args)
        assert output =~ "usage: telegram_bootstrap [check|register-webhook]"
        refute output =~ "eval"
      end
    end

    test "bin/release bootstraps when the token is set" do
      assert run_release_with_stubs(%{"TELEGRAM_BOT_TOKEN" => @bot_token}, 0) ==
               {"migrate\ntelegram_bootstrap\n", 0}
    end

    test "bin/release keeps the stored row when the token is absent or empty" do
      for env <- [%{}, %{"TELEGRAM_BOT_TOKEN" => ""}] do
        assert {output, 0} = run_release_with_stubs(env, 0)

        assert output ==
                 "migrate\ntelegram_bootstrap check\n" <>
                   "TELEGRAM_BOOTSTRAP skipped: TELEGRAM_BOT_TOKEN is not set; " <>
                   "the stored BotConfig row is kept\n"
      end
    end

    test "bin/release fails after migrating when no usable row is stored" do
      assert {output, 1} = run_release_with_stubs(%{}, 1)

      assert String.starts_with?(output, "migrate\ntelegram_bootstrap check\nRELEASE_FAILED: ")

      for name <- ~w(TELEGRAM_BOT_TOKEN TELEGRAM_WEBHOOK_SECRET TELEGRAM_BOT_USERNAME) do
        assert output =~ name
      end

      refute output =~ "register-webhook"
      refute output =~ "skipped"
    end
  end

  # Runs a copy of `bin/release` next to stubs of the two scripts it calls.
  # Each stub prints its own name and arguments; the `telegram_bootstrap`
  # stub exits with `check_status` for the `check` argument.
  defp run_release_with_stubs(env, check_status) do
    dir = Path.join(System.tmp_dir!(), "alethea-release-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    try do
      script = Path.join(dir, "release")
      File.cp!("rel/overlays/bin/release", script)

      stubs = %{
        "migrate" => "#!/bin/sh\necho migrate\n",
        "telegram_bootstrap" => """
        #!/bin/sh
        echo "telegram_bootstrap${1:+ $1}"
        if [ "${1:-}" = "check" ]; then exit #{check_status}; fi
        """
      }

      for {name, body} <- stubs do
        path = Path.join(dir, name)
        File.write!(path, body)
        File.chmod!(path, 0o755)
      end

      # `env -i` gives the script exactly the variables in `env`.
      assignments = Enum.map(env, fn {name, value} -> "#{name}=#{value}" end)

      System.cmd("/usr/bin/env", ["-i"] ++ assignments ++ ["/bin/sh", script],
        stderr_to_stdout: true
      )
    after
      File.rm_rf!(dir)
    end
  end

  # Runs a copy of the script next to a stub `alethea` that prints its
  # arguments, so the test observes which release function would be evaluated
  # without a release and without any side effect.
  defp run_with_stub_release(args) do
    dir = Path.join(System.tmp_dir!(), "alethea-script-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    try do
      script = Path.join(dir, "telegram_bootstrap")
      stub = Path.join(dir, "alethea")

      File.cp!("rel/overlays/bin/telegram_bootstrap", script)
      File.write!(stub, "#!/bin/sh\necho \"$@\"\n")
      File.chmod!(stub, 0o755)

      System.cmd("/bin/sh", [script | args], stderr_to_stdout: true)
    after
      File.rm_rf!(dir)
    end
  end

  defp telegram_environment(_context) do
    previous_vars = Map.new(@telegram_vars, fn {name, _value} -> {name, System.get_env(name)} end)
    previous_app_env = Map.new(@app_env_keys, &{&1, Application.fetch_env(:alethea, &1)})

    Enum.each(@telegram_vars, fn {name, value} -> System.put_env(name, value) end)
    Application.delete_env(:alethea, :telegram_webhook_url)
    Repo.delete_all(BotConfig)

    on_exit(fn ->
      Enum.each(previous_vars, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)

      Enum.each(previous_app_env, fn
        {key, {:ok, value}} -> Application.put_env(:alethea, key, value)
        {key, :error} -> Application.delete_env(:alethea, key)
      end)
    end)

    :ok
  end

  defp expect_webhook_info(result) do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/bot#{@bot_token}/getWebhookInfo"
      Req.Test.json(conn, %{"ok" => true, "result" => result})
    end)
  end
end
