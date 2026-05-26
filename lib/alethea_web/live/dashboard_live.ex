defmodule AletheaWeb.DashboardLive do
  use AletheaWeb, :live_view

  alias Alethea.Accounts

  def mount(_params, %{"professional_id" => id}, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Alethea.PubSub, "crisis:alerts")
    end

    professional = Accounts.get_professional!(id)

    socket =
      socket
      |> assign(:current_professional, professional)
      |> assign(:page_title, "Centro de Control")
      |> assign(:patients, Accounts.list_patients(professional.id))
      |> assign(:critical_patients, Accounts.list_critical_patients(professional.id))

    {:ok, socket}
  end

  def handle_info({:crisis_detected, patient_id, level, _triggers}, socket) do
    professional = socket.assigns.current_professional

    case Accounts.get_patient_for_professional(professional.id, patient_id) do
      nil ->
        {:noreply, socket}

      patient ->
        patient = %{patient | urgent_intervention: true}

        socket =
          socket
          |> put_flash(
            :error,
            "Alerta Critica: El paciente #{patient.alias} ha entrado en crisis (Nivel: #{level})"
          )
          |> assign(:critical_patients, upsert_critical_patient(socket.assigns.critical_patients, patient))
          |> assign(:patients, upsert_dashboard_patient(socket.assigns.patients, patient))

        {:noreply, socket}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp upsert_critical_patient(patients, patient) do
    patients
    |> reject_patient(patient.id)
    |> then(&[patient | &1])
  end

  defp upsert_dashboard_patient(patients, patient) do
    patients
    |> reject_patient(patient.id)
    |> then(&[patient | &1])
    |> Enum.sort_by(&{not &1.urgent_intervention, String.downcase(&1.alias || "")})
  end

  defp reject_patient(patients, patient_id) do
    Enum.reject(patients, &(&1.id == patient_id))
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
