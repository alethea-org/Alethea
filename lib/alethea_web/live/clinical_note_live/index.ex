defmodule AletheaWeb.ClinicalNoteLive.Index do
  @moduledoc """
  Patient-scoped clinical notes view.
  Displays immutable clinical notes in reverse chronological order and provides
  a creation form with an explicit immutability warning.
  """
  use AletheaWeb, :live_view

  alias Alethea.Accounts
  alias Alethea.ClinicalRecord

  @impl true
  def mount(%{"patient_id" => patient_id}, _session, socket) do
    professional = socket.assigns.current_professional

    case Accounts.get_patient_for_professional(professional.id, patient_id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "No estás autorizado para ver las notas clínicas de este paciente.")
         |> push_navigate(to: ~p"/patients")}

      patient ->
        case ClinicalRecord.list_clinical_notes(professional, patient_id) do
          {:ok, notes} ->
            socket =
              socket
              |> assign(:page_title, "Notas clínicas · #{patient.alias}")
              |> assign(:patient, patient)
              |> assign(:form, empty_form())
              |> assign(:notes_empty?, notes == [])
              |> stream(:clinical_notes, notes)

            {:ok, socket}

          {:error, :unauthorized} ->
            {:ok,
             socket
             |> put_flash(
               :error,
               "No estás autorizado para ver las notas clínicas de este paciente."
             )
             |> push_navigate(to: ~p"/patients")}
        end
    end
  end

  @impl true
  def handle_event("save_note", %{"clinical_note" => %{"body" => body} = params}, socket) do
    trimmed_body = String.trim(body)
    risk_change = parse_risk_change(params["risk_change"])

    if trimmed_body == "" do
      {:noreply,
       socket
       |> put_flash(:error, "El contenido de la nota clínica no puede estar vacío.")}
    else
      professional = socket.assigns.current_professional
      patient = socket.assigns.patient

      case ClinicalRecord.create_clinical_note(professional, patient.id, trimmed_body,
             risk_change: risk_change
           ) do
        {:ok, note} ->
          note_with_body = %{note | body: trimmed_body, professional: professional}

          {:noreply,
           socket
           |> assign(:notes_empty?, false)
           |> assign(:form, empty_form())
           |> assign(:patient, apply_risk_flag(patient, risk_change))
           |> stream_insert(:clinical_notes, note_with_body, at: 0)
           |> put_flash(:info, "Nota clínica creada exitosamente.")}

        {:error, :risk_already_active} ->
          {:noreply, put_flash(socket, :error, "El paciente ya tiene un riesgo activo.")}

        {:error, :risk_not_active} ->
          {:noreply, put_flash(socket, :error, "El paciente no tiene un riesgo activo.")}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, "No se pudo crear la nota clínica.")}
      end
    end
  end

  defp empty_form, do: to_form(%{"body" => "", "risk_change" => "none"}, as: "clinical_note")

  defp parse_risk_change("activated"), do: :activated
  defp parse_risk_change("deactivated"), do: :deactivated
  defp parse_risk_change(_), do: nil

  defp apply_risk_flag(patient, :activated), do: %{patient | urgent_intervention: true}
  defp apply_risk_flag(patient, :deactivated), do: %{patient | urgent_intervention: false}
  defp apply_risk_flag(patient, nil), do: patient

  defp risk_change_label("activated"), do: "Riesgo activado"
  defp risk_change_label("deactivated"), do: "Riesgo desactivado"

  defp format_datetime(%DateTime{} = datetime) do
    Calendar.strftime(datetime, "%d/%m/%Y %H:%M")
  end

  defp format_datetime(nil), do: ""

  @impl true
  def render(assigns) do
    ~H"""
    <div class="clinical-notes-container" style="max-width: 840px; margin: 0 auto; padding: 24px;">
      <div style="display: flex; align-items: center; justify-content: space-between; margin-bottom: 20px;">
        <div>
          <.link
            id="back-to-dashboard-link"
            navigate={~p"/dashboard/patients/#{@patient.id}"}
            class="button-secondary button-secondary--sm"
            style="margin-bottom: 8px; display: inline-flex; align-items: center; gap: 4px;"
          >
            <.icon name="hero-chevron-left" class="size-4" />
            <span>Volver al dashboard</span>
          </.link>
          <h1 class="pt-h1">Notas clínicas · {@patient.alias}</h1>
          <p class="pt-muted">Registro canónico de notas clínicas del paciente.</p>
        </div>
        <span
          id="patient-risk-status"
          class={["status-pill", @patient.urgent_intervention && "status-pill--risk"]}
        >
          <span class={[
            "status-dot",
            if(@patient.urgent_intervention, do: "status-dot--risk", else: "status-dot--ok")
          ]}>
          </span>
          {if @patient.urgent_intervention, do: "Riesgo activo", else: "Sin riesgo activo"}
        </span>
      </div>

      <%!-- Card de Creación de Nota --%>
      <div class="pt-card" style="margin-bottom: 28px;">
        <div class="pt-card__head">
          <span class="pt-h2">Nueva nota clínica</span>
        </div>
        <div class="pt-card__body">
          <div
            id="immutability-notice"
            class="flash flash--info"
            style="margin-bottom: 16px;"
          >
            <.icon name="hero-exclamation-triangle" class="flash__icon" />
            <div>
              <p class="flash__title">Nota inmutable</p>
              <p class="flash__msg">
                Una vez guardada, esta nota formará parte del registro clínico permanente y no podrá ser editada ni eliminada.
              </p>
            </div>
          </div>

          <.form for={@form} id="clinical-note-form" phx-submit="save_note">
            <.input
              id="clinical-note-body-input"
              field={@form[:body]}
              type="textarea"
              label="Contenido de la nota"
              placeholder="Describí las observaciones clínicas, evolución o aspectos relevantes..."
              rows="4"
            />
            <fieldset id="risk-change-fieldset" style="margin-top: 12px; border: 0; padding: 0;">
              <legend class="pt-eyebrow" style="margin-bottom: 6px;">Riesgo del paciente</legend>
              <div style="display: flex; flex-wrap: wrap; gap: 16px;">
                <label
                  :for={
                    {value, label} <- [
                      {"none", "Sin cambios"},
                      {"activated", "Activar riesgo"},
                      {"deactivated", "Desactivar riesgo"}
                    ]
                  }
                  for={"risk-change-#{value}"}
                  style="display: inline-flex; align-items: center; gap: 6px; font-size: 14px;"
                >
                  <input
                    type="radio"
                    id={"risk-change-#{value}"}
                    name={@form[:risk_change].name}
                    value={value}
                    checked={@form[:risk_change].value == value}
                  />
                  {label}
                </label>
              </div>
            </fieldset>
            <div class="form-actions" style="margin-top: 12px;">
              <button
                type="submit"
                id="save-clinical-note-button"
                class="button-primary button-primary--sm"
              >
                <.icon name="hero-check" class="size-4" style="margin-right: 4px;" />
                Guardar nota clínica
              </button>
            </div>
          </.form>
        </div>
      </div>

      <%!-- Listado de Notas --%>
      <div>
        <h2 class="pt-h2" style="margin-bottom: 14px;">Historial de notas</h2>

        <div :if={@notes_empty?} id="clinical-notes-empty" class="empty-state">
          <.icon name="hero-chat-bubble-left-right" class="empty-state__icon" />
          <p class="empty-state__title">Sin notas clínicas registradas</p>
          <p class="empty-state__text">
            Este paciente todavía no tiene notas clínicas. Utilizá el formulario superior para registrar la primera nota.
          </p>
        </div>

        <div
          id="clinical-notes-list"
          phx-update="stream"
          style="display: flex; flex-direction: column; gap: 16px;"
        >
          <div
            :for={{dom_id, note} <- @streams.clinical_notes}
            id={dom_id}
            class="pt-card"
          >
            <div
              class="pt-card__head"
              style="display: flex; justify-content: space-between; align-items: center;"
            >
              <div style="display: flex; align-items: center; gap: 8px;">
                <.icon name="hero-user-circle" class="size-4 pt-muted" />
                <strong style="font-size: 14px;">
                  {if note.professional,
                    do: note.professional.full_name || note.professional.email,
                    else: "Profesional"}
                </strong>
                <span
                  :if={note.risk_change}
                  class={[
                    "risk-change-badge status-pill",
                    note.risk_change == "activated" && "status-pill--risk"
                  ]}
                >
                  {risk_change_label(note.risk_change)}
                </span>
              </div>
              <span class="pt-eyebrow" style="margin: 0;">
                {format_datetime(note.inserted_at)}
              </span>
            </div>
            <div class="pt-card__body">
              <p style="white-space: pre-wrap; font-size: 14px; line-height: 1.6; margin: 0;">
                {note.body}
              </p>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
