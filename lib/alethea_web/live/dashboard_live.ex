defmodule AletheaWeb.DashboardLive do
  use AletheaWeb, :live_view
  import Ecto.Query

  alias Alethea.Accounts
  alias Alethea.Clinical.{MockData, Message}
  alias Alethea.Encryption.PatientVault

  def mount(_params, %{"professional_id" => id}, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Alethea.PubSub, "crisis:alerts")
    end

    professional = Accounts.get_professional!(id)
    use_mock? = Application.get_env(:alethea, :use_mock_data, false)

    patients =
      if use_mock?,
        do: MockData.list_mock_patients(professional.id),
        else: Accounts.list_patients(professional.id)

    critical_patients =
      if use_mock?,
        do: Enum.filter(patients, & &1.urgent_intervention),
        else: Accounts.list_critical_patients(professional.id)

    socket =
      socket
      |> assign(:current_professional, professional)
      |> assign(:page_title, "Centro de Control")
      |> assign(:use_mock_data, use_mock?)
      |> assign(:patients, patients)
      |> assign(:critical_patients, critical_patients)
      |> assign(:selected_patient, nil)
      |> assign(:weekly_summary, nil)
      |> assign(:session_summaries, [])
      |> assign(:emotion_rows, [])
      |> assign(:mood_signal, default_mood_signal())
      |> assign(:decrypted_messages, [])

    {:ok, socket, temporary_assigns: [decrypted_messages: []]}
  end

  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:selected_patient, nil)
    |> assign(:decrypted_messages, [])
  end

  defp apply_action(socket, :show, %{"id" => id}) do
    patient = find_patient(socket, id)

    if patient do
      # Auditoría de visualización de perfil
      Accounts.log_action(%{
        action: "VIEW_PATIENT_PROFILE",
        resource_type: "Patient",
        resource_id: patient.id,
        professional_id: socket.assigns.current_professional.id
      })

      socket
      |> assign(:decrypted_messages, [])
      |> load_patient_details(patient)
    else
      socket
      |> put_flash(:error, "Paciente no encontrado o no autorizado.")
      |> push_patch(to: ~p"/dashboard")
    end
  end

  def handle_event("decrypt_chat", _params, socket) do
    patient = socket.assigns.selected_patient
    professional_kek = socket.assigns.professional_kek

    # Auditoría de descifrado
    Accounts.log_action(%{
      action: "VIEW_CHAT_HISTORY",
      resource_type: "Patient",
      resource_id: patient.id,
      professional_id: socket.assigns.current_professional.id
    })

    decrypted_messages =
      if socket.assigns.use_mock_data do
        MockData.list_mock_messages(patient.id)
        |> Enum.map(fn msg ->
          %{msg | encrypted_content: "CONTENIDO DESCIFRADO (MOCK): " <> msg.encrypted_content}
        end)
      else
        decrypt_real_messages(patient, professional_kek)
      end

    {:noreply, assign(socket, :decrypted_messages, decrypted_messages)}
  end

  def handle_event("save_session_schedule", %{"day" => day, "time" => time}, socket) do
    patient = socket.assigns.selected_patient
    day = String.to_integer(day)
    time = Time.from_iso8601!(time <> ":00")

    case Accounts.update_patient_session_schedule(patient, day, time) do
      {:ok, updated_patient} ->
        # Actualizar la lista de pacientes en el sidebar si no estamos en mocks
        patients =
          if socket.assigns.use_mock_data do
            socket.assigns.patients
            |> Enum.map(fn p -> if p.id == patient.id, do: updated_patient, else: p end)
          else
            Accounts.list_patients(socket.assigns.current_professional.id)
          end

        socket =
          socket
          |> put_flash(:info, "Horario de sesión actualizado correctamente.")
          |> assign(:selected_patient, updated_patient)
          |> assign(:patients, patients)

        {:noreply, socket}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "No se pudo actualizar el horario.")}
    end
  end

  defp decrypt_real_messages(patient, professional_kek) do
    key_record = Accounts.get_encryption_key_for_patient(patient.id)

    with {:ok, dek_bytes} <- PatientVault.decrypt(key_record.encrypted_key, professional_kek) do
      # Cargar últimos 50 mensajes
      messages =
        Alethea.Repo.all(
          Ecto.Query.from(m in Message,
            where: m.patient_id == ^patient.id,
            order_by: [desc: m.timestamp],
            limit: 50
          )
        )

      # Descifrar contenido
      Enum.map(messages, fn msg ->
        case PatientVault.decrypt(msg.encrypted_content, dek_bytes) do
          {:ok, plain_text} -> %{msg | encrypted_content: plain_text}
          _ -> %{msg | encrypted_content: "[Error al descifrar]"}
        end
      end)
    else
      _ -> []
    end
  end

  defp find_patient(socket, id) do
    if socket.assigns.use_mock_data do
      Enum.find(socket.assigns.patients, &(&1.id == id))
    else
      Accounts.get_patient_for_professional(socket.assigns.current_professional.id, id)
    end
  end

  defp load_patient_details(socket, patient) do
    use_mock? = socket.assigns.use_mock_data

    weekly_summary =
      if use_mock?,
        do: List.first(MockData.list_mock_summaries(patient.id, "weekly")),
        else: nil

    session_summaries =
      if use_mock?,
        do: MockData.list_mock_summaries(patient.id, "session"),
        else: []

    trends =
      if use_mock?,
        do: MockData.list_mock_trends(patient.id),
        else: []

    emotion_rows = format_emotion_trends(trends)

    socket
    |> assign(:selected_patient, patient)
    |> assign(:weekly_summary, weekly_summary)
    |> assign(:session_summaries, session_summaries)
    |> assign(:emotion_rows, emotion_rows)
    |> assign(:mood_signal, calculate_mood_signal(trends, patient))
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

  defp format_emotion_trends(trends) do
    trends
    |> Enum.map(fn trend ->
      %{
        key: trend.indicator_name,
        label: format_emotion_label(trend.indicator_name),
        percent: round(trend.score * 100),
        progress_class: emotion_progress_class(trend.indicator_name)
      }
    end)
    |> Enum.sort_by(& &1.percent, :desc)
  end

  defp format_emotion_label("joy"), do: "Alegría"
  defp format_emotion_label("sadness"), do: "Tristeza"
  defp format_emotion_label("anger"), do: "Ira"
  defp format_emotion_label("fear"), do: "Miedo"
  defp format_emotion_label("neutral"), do: "Neutro"
  defp format_emotion_label(other), do: String.capitalize(other)

  defp emotion_progress_class("joy"), do: "progress-success"
  defp emotion_progress_class("sadness"), do: "progress-info"
  defp emotion_progress_class("anger"), do: "progress-error"
  defp emotion_progress_class("fear"), do: "progress-warning"
  defp emotion_progress_class("neutral"), do: "progress-ghost"
  defp emotion_progress_class(_), do: ""

  defp calculate_mood_signal(trends, patient) do
    predominant =
      trends
      |> Enum.max_by(& &1.score, fn -> nil end)
      |> case do
        nil -> nil
        trend -> trend.indicator_name
      end

    cond do
      patient.urgent_intervention or predominant == "anger" ->
        %{
          label:
            if(patient.urgent_intervention, do: "Intervención prioritaria", else: "Riesgo: Ira alta"),
          dot_class: "bg-error",
          ring_class: "ring-error/30",
          badge_class: "badge-error"
        }

      predominant in ["sadness", "fear"] ->
        %{
          label: "Atención: #{format_emotion_label(predominant)}",
          dot_class: "bg-warning",
          ring_class: "ring-warning/30",
          badge_class: "badge-warning"
        }

      true ->
        %{
          label: "Estable",
          dot_class: "bg-success",
          ring_class: "ring-success/30",
          badge_class: "badge-success"
        }
    end
  end

  defp default_mood_signal do
    %{
      label: "Sin datos",
      dot_class: "bg-base-300",
      ring_class: "ring-base-300/30",
      badge_class: "badge-ghost"
    }
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
