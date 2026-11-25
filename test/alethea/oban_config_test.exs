defmodule Alethea.ObanConfigTest do
  @moduledoc """
  Oban configuration contracts (odd/tasks/security-audit-run-1.md, S4):
  completed, cancelled and discarded jobs are pruned, so job args do not
  stay in `oban_jobs` forever.
  """

  use ExUnit.Case, async: true

  test "Oban.Plugins.Pruner is configured with a bounded max_age" do
    plugins = Application.fetch_env!(:alethea, Oban)[:plugins]

    assert {Oban.Plugins.Pruner, opts} = List.keyfind(plugins, Oban.Plugins.Pruner, 0)
    assert opts[:max_age] == 7 * 24 * 60 * 60
  end

  test "the pre-existing Cron plugin is still configured" do
    plugins = Application.fetch_env!(:alethea, Oban)[:plugins]

    assert {Oban.Plugins.Cron, opts} = List.keyfind(plugins, Oban.Plugins.Cron, 0)
    assert opts[:crontab] != []
  end
end
