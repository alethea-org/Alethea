defmodule Alethea.DevDatabase do
  @moduledoc """
  Development environment only: chooses which database a local `MIX_ENV=dev`
  run connects to. Called from `config/runtime.exs`; never used in test or prod.

  Resolution order:

    1. `DATABASE_URL` set → use it as-is (manual override, no probe).
    2. `NEON_DATABASE_URL` set and its host/port accepts a TCP connection →
       use the shared Neon database.
    3. Otherwise → use `LOCAL_DATABASE_URL`, defaulting to the local Docker
       Postgres on `localhost`. Networks that block outbound 5432 (e.g. the
       university wifi) land here.

  Empty variables are treated as unset, so docker compose can pass them through
  without forcing a choice.
  """

  @default_local_url "postgresql://postgres:postgres@localhost:5432/alethea_dev"
  @default_port 5432
  @probe_timeout_ms 2_000

  @type source :: :forced | :neon | :local
  @type probe :: (String.t(), :inet.port_number() -> boolean())

  @spec select(%{optional(String.t()) => String.t()}, probe()) :: {source(), String.t()}
  def select(env, probe \\ &reachable?/2) do
    forced = present(env["DATABASE_URL"])
    neon = present(env["NEON_DATABASE_URL"])
    local = present(env["LOCAL_DATABASE_URL"]) || @default_local_url

    cond do
      forced -> {:forced, forced}
      neon && neon_reachable?(neon, probe) -> {:neon, neon}
      true -> {:local, local}
    end
  end

  @spec reachable?(String.t(), :inet.port_number(), timeout()) :: boolean()
  def reachable?(host, port, timeout \\ @probe_timeout_ms) do
    case :gen_tcp.connect(String.to_charlist(host), port, [:binary, active: false], timeout) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      {:error, _reason} ->
        false
    end
  end

  @doc "Strips credentials and query params so the URL is safe to log."
  @spec redact(String.t()) :: String.t()
  def redact(url) do
    %URI{scheme: scheme, host: host, path: path} = URI.parse(url)
    "#{scheme}://#{host}#{path}"
  end

  defp neon_reachable?(url, probe) do
    %URI{host: host, port: port} = URI.parse(url)
    probe.(host, port || @default_port)
  end

  defp present(nil), do: nil
  defp present(""), do: nil
  defp present(value), do: value
end
