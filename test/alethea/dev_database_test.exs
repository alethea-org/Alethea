defmodule Alethea.DevDatabaseTest do
  # Development environment only: covers the database selection used by
  # config/runtime.exs when the app runs with MIX_ENV=dev.
  use ExUnit.Case, async: true

  alias Alethea.DevDatabase

  @neon "postgresql://user:secret@ep-test.sa-east-1.aws.neon.tech/alethea_dev?ssl=true"
  @local "postgresql://postgres:postgres@db:5432/alethea_dev"

  defp reachable(_host, _port), do: true
  defp unreachable(_host, _port), do: false

  describe "select/2" do
    test "an explicit DATABASE_URL always wins and skips the probe" do
      env = %{"DATABASE_URL" => "postgresql://forced/db", "NEON_DATABASE_URL" => @neon}
      probe = fn _host, _port -> flunk("probe must not run when DATABASE_URL is set") end

      assert DevDatabase.select(env, probe) == {:forced, "postgresql://forced/db"}
    end

    test "uses Neon when its port is reachable" do
      env = %{"NEON_DATABASE_URL" => @neon, "LOCAL_DATABASE_URL" => @local}

      assert DevDatabase.select(env, &reachable/2) == {:neon, @neon}
    end

    test "probes the Neon host and port taken from the URL" do
      env = %{"NEON_DATABASE_URL" => "postgresql://u:p@ep-x.neon.tech:6000/db?ssl=true"}
      test_pid = self()

      probe = fn host, port ->
        send(test_pid, {:probed, host, port})
        true
      end

      DevDatabase.select(env, probe)

      assert_received {:probed, "ep-x.neon.tech", 6000}
    end

    test "defaults the probe port to 5432" do
      test_pid = self()

      probe = fn host, port ->
        send(test_pid, {:probed, host, port})
        true
      end

      DevDatabase.select(%{"NEON_DATABASE_URL" => @neon}, probe)

      assert_received {:probed, "ep-test.sa-east-1.aws.neon.tech", 5432}
    end

    test "falls back to the local database when Neon is unreachable" do
      env = %{"NEON_DATABASE_URL" => @neon, "LOCAL_DATABASE_URL" => @local}

      assert DevDatabase.select(env, &unreachable/2) == {:local, @local}
    end

    test "uses the local database when no Neon URL is configured" do
      probe = fn _host, _port -> flunk("probe must not run without NEON_DATABASE_URL") end

      assert DevDatabase.select(%{"LOCAL_DATABASE_URL" => @local}, probe) == {:local, @local}
    end

    test "defaults the local database to localhost" do
      assert DevDatabase.select(%{}, &unreachable/2) ==
               {:local, "postgresql://postgres:postgres@localhost:5432/alethea_dev"}
    end

    test "treats empty variables as unset" do
      env = %{"DATABASE_URL" => "", "NEON_DATABASE_URL" => "", "LOCAL_DATABASE_URL" => ""}

      assert DevDatabase.select(env, &reachable/2) ==
               {:local, "postgresql://postgres:postgres@localhost:5432/alethea_dev"}
    end
  end

  describe "reachable?/3" do
    test "returns true when a TCP listener accepts the connection" do
      {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
      {:ok, port} = :inet.port(listener)
      on_exit(fn -> :gen_tcp.close(listener) end)

      assert DevDatabase.reachable?("127.0.0.1", port, 1_000)
    end

    test "returns false when nothing listens on the port" do
      {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
      {:ok, port} = :inet.port(listener)
      :ok = :gen_tcp.close(listener)

      refute DevDatabase.reachable?("127.0.0.1", port, 1_000)
    end
  end

  describe "redact/1" do
    test "keeps only scheme, host, and database so credentials never reach the logs" do
      assert DevDatabase.redact(@neon) ==
               "postgresql://ep-test.sa-east-1.aws.neon.tech/alethea_dev"
    end
  end
end
