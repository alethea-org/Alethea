defmodule Alethea.RuntimeEnv do
  @moduledoc false

  @spec load_dotenv(Path.t()) :: :ok
  def load_dotenv(path) do
    if File.regular?(path) do
      path
      |> File.stream!()
      |> Enum.each(&load_dotenv_line/1)
    end

    :ok
  end

  defp load_dotenv_line(line) do
    case Regex.run(~r/^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)\s*$/, line) do
      [_, key, value] ->
        if is_nil(System.get_env(key)), do: System.put_env(key, normalize_value(value))

      _other ->
        :ok
    end
  end

  defp normalize_value(value) do
    value = String.trim(value)

    case value do
      <<quote, rest::binary>> when quote in [?", ?'] ->
        if String.ends_with?(rest, <<quote>>),
          do: binary_part(rest, 0, byte_size(rest) - 1),
          else: value

      _other ->
        value
    end
  end
end
