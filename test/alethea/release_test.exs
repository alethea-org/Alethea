defmodule Alethea.ReleaseTest do
  use Alethea.DataCase, async: false

  alias Alethea.Release

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

  describe "release overlays" do
    for script <- ~w(server migrate) do
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
  end
end
