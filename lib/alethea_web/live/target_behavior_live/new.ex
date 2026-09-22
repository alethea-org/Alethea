defmodule AletheaWeb.TargetBehaviorLive.New do
  @moduledoc """
  Patient-scoped form for creating a target behavior and continuing to its
  functional-analysis workbench.
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
         |> put_flash(
           :error,
           "No estás autorizado para crear conductas objetivo para este paciente."
         )
         |> push_navigate(to: ~p"/patients")}

      patient ->
        {:ok,
         socket
         |> assign(:page_title, "Nueva conducta objetivo · #{patient.alias}")
         |> assign(:patient, patient)
         |> assign(:form, target_behavior_form())}
    end
  end

  @impl true
  def handle_event(
        "save",
        %{"target_behavior" => %{"description" => description}},
        socket
      ) do
    description = String.trim(description)

    if description == "" do
      {:noreply,
       socket
       |> assign(:form, target_behavior_form(description))
       |> put_flash(:error, "La descripción de la conducta objetivo no puede estar vacía.")}
    else
      create_target_behavior(socket, description)
    end
  end

  defp create_target_behavior(socket, description) do
    professional = socket.assigns.current_professional
    patient = socket.assigns.patient

    case ClinicalRecord.create_target_behavior(professional, patient.id, description) do
      {:ok, target_behavior} ->
        {:noreply,
         socket
         |> put_flash(:info, "Conducta objetivo creada exitosamente.")
         |> push_navigate(
           to: ~p"/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review"
         )}

      {:error, :unauthorized} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           "No estás autorizado para crear conductas objetivo para este paciente."
         )
         |> push_navigate(to: ~p"/patients")}

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(:form, target_behavior_form(description))
         |> put_flash(:error, "No se pudo crear la conducta objetivo.")}
    end
  end

  defp target_behavior_form(description \\ "") do
    to_form(%{"description" => description}, as: "target_behavior")
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="new-target-behavior-page" style="max-width: 720px; margin: 0 auto; padding: 24px;">
      <div style="margin-bottom: 20px;">
        <p class="pt-eyebrow">Registro clínico · {@patient.alias}</p>
        <h1 class="pt-h1">Nueva conducta objetivo</h1>
        <p class="pt-muted">
          Describí una conducta observable para iniciar su análisis funcional.
        </p>
      </div>

      <div class="pt-card">
        <div class="pt-card__head">
          <span class="pt-h2">Conducta de {@patient.alias}</span>
        </div>
        <div class="pt-card__body">
          <.form for={@form} id="target-behavior-form" phx-submit="save">
            <.input
              id="target-behavior-description-input"
              field={@form[:description]}
              type="textarea"
              label="Descripción"
              placeholder="Describí qué hace el paciente y en qué contexto..."
              rows="4"
              required
            />

            <div class="form-actions" style="display:flex; gap:8px; margin-top:12px;">
              <button
                id="save-target-behavior-button"
                type="submit"
                class="button-primary button-primary--sm"
              >
                Crear y continuar
              </button>
              <.link
                id="cancel-target-behavior-link"
                navigate={~p"/dashboard/patients/#{@patient.id}"}
                class="button-secondary button-secondary--sm"
              >
                Cancelar
              </.link>
            </div>
          </.form>
        </div>
      </div>
    </div>
    """
  end
end
