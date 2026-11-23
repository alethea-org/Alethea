defmodule AletheaWeb.AdminWaitlistController do
  @moduledoc """
  CSV download of the launch waitlist (`GET /admin/waitlist.csv`).
  Admin-only: the `:require_admin` pipeline runs first.
  """
  use AletheaWeb, :controller

  alias Alethea.Waitlist

  def export(conn, _params) do
    rows =
      Enum.map(Waitlist.list_entries(), fn entry ->
        [entry.name, entry.email, DateTime.to_iso8601(entry.inserted_at)]
      end)

    body = Enum.map_join([["nombre", "email", "fecha"] | rows], &csv_line/1)
    filename = "lista-de-espera-#{Date.utc_today()}.csv"

    conn
    |> put_resp_content_type("text/csv")
    |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
    |> send_resp(200, body)
  end

  defp csv_line(cells), do: Enum.map_join(cells, ",", &csv_cell/1) <> "\r\n"

  # Quotes cells that need it and neutralises leading formula characters,
  # so opening the file in a spreadsheet never runs what someone typed.
  defp csv_cell(value) do
    value = to_string(value)

    value =
      if String.starts_with?(value, ["=", "+", "-", "@", "\t", "\r"]),
        do: "'" <> value,
        else: value

    if String.contains?(value, [",", "\"", "\n", "\r", "'"]) do
      ~s(") <> String.replace(value, ~s("), ~s("")) <> ~s(")
    else
      value
    end
  end
end
