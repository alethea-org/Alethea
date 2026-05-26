defmodule AletheaWeb.DashboardLive do
  use AletheaWeb, :live_view

  alias Alethea.Accounts

  def mount(_params, %{"professional_id" => id}, socket) do
    professional = Accounts.get_professional!(id)
    {:ok, assign(socket, current_professional: professional, page_title: "Centro de Control")}
  end

  defp format_session_day(nil), do: "-"
  defp format_session_day(1), do: "Lunes"
  defp format_session_day(2), do: "Martes"
  defp format_session_day(3), do: "Miercoles"
  defp format_session_day(4), do: "Jueves"
  defp format_session_day(5), do: "Viernes"
  defp format_session_day(6), do: "Sabado"
  defp format_session_day(7), do: "Domingo"
  defp format_session_day(_day), do: "-"

  defp format_session_time(nil), do: "-"

  defp format_session_time(%Time{} = time) do
    time
    |> Time.truncate(:minute)
    |> Time.to_string()
  end

  defp format_summary_date(nil), do: "-"

  defp format_summary_date(%DateTime{} = date_time) do
    Calendar.strftime(date_time, "%d/%m/%Y")
  end
end
