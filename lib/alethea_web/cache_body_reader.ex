defmodule AletheaWeb.CacheBodyReader do
  @moduledoc """
  Lee y guarda el raw body de la request en `conn.assigns.raw_body`.
  Es necesario para validar la firma HMAC-SHA256 de Meta (WhatsApp).
  """

  @doc """
  Implementación del body reader para Plug.Parsers.
  """
  def read_body(conn, opts) do
    {:ok, body, conn} = Plug.Conn.read_body(conn, opts)
    conn = Plug.Conn.assign(conn, :raw_body, body)
    {:ok, body, conn}
  end
end
