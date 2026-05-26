defmodule AletheaWeb.Plugs.CacheBodyReader do
  @moduledoc """
  Plug para conservar el raw body en conn.assigns antes de que Plug.Parsers lo consuma.
  """

  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @spec read_body(Plug.Conn.t(), keyword()) :: {:ok, binary(), Plug.Conn.t()} | {:more, binary(), Plug.Conn.t()} | {:error, term()}
  def read_body(conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} ->
        {:ok, body, Plug.Conn.assign(conn, :raw_body, body)}

      {:more, body, conn} ->
        {:more, body, Plug.Conn.assign(conn, :raw_body, body)}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
