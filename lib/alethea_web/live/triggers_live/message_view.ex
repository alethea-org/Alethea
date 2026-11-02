defmodule AletheaWeb.TriggersLive.MessageView do
  @moduledoc """
  Patient-scoped view of a produced trigger message (Issue #440, S4/S8).
  Displays the decrypted content and metadata of a message sent as a result of a trigger firing.
  """
  use AletheaWeb, :live_view

  alias Alethea.Accounts
  alias Alethea.Triggers

  @impl true
  def mount(%{"patient_id" => patient_id, "message_id" => message_id}, _session, socket) do
    professional = socket.assigns.current_professional

    with {:ok, valid_patient_id} <- Ecto.UUID.cast(patient_id),
         %Accounts.Patient{} = patient <-
           Accounts.get_patient_for_professional(professional.id, valid_patient_id) do
      case Ecto.UUID.cast(message_id) do
        {:ok, valid_message_id} ->
          case Triggers.get_produced_message(professional, valid_patient_id, valid_message_id) do
            {:ok, message, decrypted_text} ->
              socket =
                socket
                |> assign(:page_title, "Mensaje de trigger · #{patient.alias}")
                |> assign(:patient, patient)
                |> assign(:message, message)
                |> assign(:decrypted_text, decrypted_text)

              {:ok, socket}

            _error ->
              {:ok,
               socket
               |> put_flash(:error, "Mensaje no encontrado o no autorizado.")
               |> push_navigate(to: ~p"/patients/#{patient.id}/triggers")}
          end

        :error ->
          {:ok,
           socket
           |> put_flash(:error, "Mensaje no encontrado o no autorizado.")
           |> push_navigate(to: ~p"/patients/#{patient.id}/triggers")}
      end
    else
      _ ->
        {:ok,
         socket
         |> put_flash(:error, "No estás autorizado para acceder a este paciente.")
         |> push_navigate(to: ~p"/patients")}
    end
  end

  defp format_datetime(%DateTime{} = dt) do
    Calendar.strftime(dt, "%d/%m/%Y %H:%M UTC")
  end

  defp format_datetime(nil), do: ""

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id="produced-message-view"
      class="message-view-container"
      style="max-width: 840px; margin: 0 auto; padding: 24px;"
    >
      <div style="margin-bottom: 20px;">
        <.link
          id="back-to-triggers-link"
          navigate={~p"/patients/#{@patient.id}/triggers"}
          class="button-secondary button-secondary--sm"
          style="margin-bottom: 8px; display: inline-flex; align-items: center; gap: 4px;"
        >
          <.icon name="hero-chevron-left" class="size-4" />
          <span>Volver a triggers</span>
        </.link>
        <h1 class="pt-h1">Mensaje de trigger · {@patient.alias}</h1>
        <p class="pt-muted">Detalles del mensaje producido por el trigger.</p>
      </div>

      <div class="pt-card" style="padding: 24px;">
        <div style="margin-bottom: 16px;">
          <span class="pt-eyebrow">Contenido enviado</span>
          <p id="produced-message-body" style="font-size: 1.15em; line-height: 1.5; margin-top: 8px;">
            {@decrypted_text}
          </p>
        </div>

        <div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 16px; border-top: 1px solid var(--color-border); padding-top: 16px;">
          <div>
            <span class="pt-muted" style="font-size: 0.85em;">Fecha y hora</span>
            <p id="produced-message-timestamp" style="font-weight: 500;">
              {format_datetime(@message.timestamp)}
            </p>
          </div>
          <div>
            <span class="pt-muted" style="font-size: 0.85em;">Estado de entrega</span>
            <p id="produced-message-delivery-state" style="font-weight: 500;">
              {@message.delivery_state || "pendiente"}
            </p>
          </div>
          <div>
            <span class="pt-muted" style="font-size: 0.85em;">ID del Trigger</span>
            <p id="produced-message-trigger-id" style="font-family: monospace; font-size: 0.9em;">
              {@message.trigger_id}
            </p>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
