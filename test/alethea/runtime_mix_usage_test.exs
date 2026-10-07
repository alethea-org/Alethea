defmodule Alethea.RuntimeMixUsageTest do
  @moduledoc """
  Guards the release boot path: `Mix` is not part of a release, so any
  `Mix.env()` call that runs after compilation raises `UndefinedFunctionError`
  in production.

  The environment is exposed as `Application.fetch_env!(:alethea, :env)`
  (set from `config_env()` in `config/config.exs`). Mix tasks under
  `lib/mix/` only ever run with Mix loaded and are out of scope.
  """

  use ExUnit.Case, async: true

  # Calls evaluated while the module body compiles, never at runtime.
  # Each entry is the exact number of `Mix.env()` calls allowed in that file.
  @compile_time_allowlist %{
    # `if Mix.env() == :dev do ... end` wrapping the Tidewave plug.
    "lib/alethea_web/endpoint.ex" => 1
  }

  test "no file under lib/ outside lib/mix/ calls Mix.env() at runtime" do
    offenders =
      "lib/**/*.ex"
      |> Path.wildcard()
      |> Enum.reject(&String.starts_with?(&1, "lib/mix/"))
      |> Enum.map(&{&1, mix_env_call_lines(&1)})
      |> Enum.reject(fn {path, lines} ->
        length(lines) == Map.get(@compile_time_allowlist, path, 0)
      end)
      |> Enum.sort()

    assert offenders == [],
           "Mix.env() is unavailable in a release. Read " <>
             "Application.fetch_env!(:alethea, :env) instead in: " <>
             inspect(offenders)
  end

  defp mix_env_call_lines(path) do
    {_ast, lines} =
      path
      |> File.read!()
      |> Code.string_to_quoted!(file: path)
      |> Macro.prewalk([], fn
        {{:., meta, [{:__aliases__, _, [:Mix]}, :env]}, _, []} = node, acc ->
          {node, [Keyword.get(meta, :line) | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(lines)
  end
end
