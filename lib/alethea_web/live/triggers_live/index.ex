defmodule AletheaWeb.TriggersLive.Index do
  @moduledoc """
  Patient-scoped triggers management page (Issue #440, S1-S10).
  Allows the owning professional to view active triggers, generate clinically neutral
  previews, approve/schedule one-shot triggers, and inspect firing history.
  """
  use AletheaWeb, :live_view

  alias Alethea.Accounts
  alias Alethea.Triggers

  @impl true
  def mount(%{"patient_id" => patient_id}, _session, socket) do
    professional = socket.assigns.current_professional

    with {:ok, valid_patient_id} <- Ecto.UUID.cast(patient_id),
         %Accounts.Patient{} = patient <-
           Accounts.get_patient_for_professional(professional.id, valid_patient_id) do
      with {:ok, active_triggers} <- Triggers.list_active_triggers(professional, patient.id),
           {:ok, firings} <- Triggers.list_firings(professional, patient.id) do
        socket =
          socket
          |> assign(:page_title, "Triggers · #{patient.alias}")
          |> assign(:patient, patient)
          |> assign(:active_tab, "active")
          |> assign(:preview_draft, nil)
          |> assign(:preview_instruction, nil)
          |> assign(:approving, false)
          |> assign(
            :form,
            to_form(
              %{
                "instruction" => "",
                "schedule_type" => "once",
                "date" => "",
                "time" => "",
                "weekdays" => [],
                "end_date" => ""
              },
              as: "trigger"
            )
          )
          |> assign(:active_triggers_empty?, active_triggers == [])
          |> assign(:firings_empty?, firings == [])
          |> stream(:active_triggers, active_triggers)
          |> stream(:firings, firings)

        {:ok, socket}
      else
        {:error, :unauthorized} ->
          {:ok,
           socket
           |> put_flash(:error, "No estás autorizado para acceder a este paciente.")
           |> push_navigate(to: ~p"/patients")}
      end
    else
      _ ->
        {:ok,
         socket
         |> put_flash(:error, "No estás autorizado para acceder a este paciente.")
         |> push_navigate(to: ~p"/patients")}
    end
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) when tab in ["active", "history"] do
    {:noreply, assign(socket, :active_tab, tab)}
  end

  def handle_event("validate", %{"trigger" => params}, socket) do
    new_instruction = Map.get(params, "instruction", "") |> String.trim()
    preview_instruction = socket.assigns[:preview_instruction]

    # B2: Invalidate displayed/server-owned preview if instruction has changed
    socket =
      if preview_instruction != nil and preview_instruction != new_instruction do
        socket
        |> assign(:preview_draft, nil)
        |> assign(:preview_instruction, nil)
      else
        socket
      end

    {:noreply, assign(socket, :form, to_form(params, as: "trigger"))}
  end

  def handle_event("generate_preview", %{"trigger" => params}, socket) do
    instruction = Map.get(params, "instruction", "") |> String.trim()

    if instruction == "" do
      {:noreply,
       socket
       |> assign(:preview_draft, nil)
       |> assign(:preview_instruction, nil)
       |> put_flash(:error, "La instrucción no puede estar vacía.")
       |> assign(:form, to_form(params, as: "trigger"))}
    else
      professional = socket.assigns.current_professional
      patient = socket.assigns.patient

      case Triggers.generate_preview(professional, patient.id, instruction) do
        {:ok, %{draft: draft}} ->
          {:noreply,
           socket
           |> assign(:preview_draft, draft)
           |> assign(:preview_instruction, instruction)
           |> assign(:form, to_form(params, as: "trigger"))
           |> put_flash(:info, "Vista previa generada.")}

        {:error, :unauthorized} ->
          {:noreply,
           socket
           |> assign(:preview_draft, nil)
           |> assign(:preview_instruction, nil)
           |> put_flash(:error, "No estás autorizado para generar vistas previas.")}

        {:error, _reason} ->
          {:noreply,
           socket
           |> assign(:preview_draft, nil)
           |> assign(:preview_instruction, nil)
           |> put_flash(:error, "No se pudo generar la vista previa. Inténtalo nuevamente.")}
      end
    end
  end

  def handle_event("generate_preview", _params, socket) do
    params = socket.assigns.form.params || %{}
    handle_event("generate_preview", %{"trigger" => params}, socket)
  end

  def handle_event("approve_trigger", _params, socket) do
    if socket.assigns[:approving] do
      {:noreply, socket}
    else
      preview_draft = socket.assigns.preview_draft
      preview_instruction = socket.assigns[:preview_instruction]
      params = socket.assigns.form.params || %{}
      instruction = Map.get(params, "instruction", "") |> String.trim()
      schedule_type = Map.get(params, "schedule_type", "once")
      date = Map.get(params, "date", "")
      time = Map.get(params, "time", "")
      weekdays = Map.get(params, "weekdays", [])
      end_date = Map.get(params, "end_date", "")

      cond do
        is_nil(preview_draft) or String.trim(preview_draft) == "" ->
          {:noreply,
           put_flash(socket, :error, "Debes generar una vista previa antes de aprobar.")}

        is_nil(preview_instruction) or preview_instruction != instruction ->
          {:noreply,
           socket
           |> assign(:preview_draft, nil)
           |> assign(:preview_instruction, nil)
           |> put_flash(
             :error,
             "La instrucción cambió. Debes generar una nueva vista previa antes de aprobar."
           )}

        instruction == "" ->
          {:noreply, put_flash(socket, :error, "La instrucción no puede estar vacía.")}

        schedule_type == "once" and (date == "" or time == "") ->
          {:noreply, put_flash(socket, :error, "Debes especificar fecha y hora.")}

        schedule_type in ["daily", "weekly"] and time == "" ->
          {:noreply, put_flash(socket, :error, "Debes especificar la hora de envío.")}

        schedule_type == "weekly" and (is_nil(weekdays) or weekdays == []) ->
          {:noreply, put_flash(socket, :error, "Debes seleccionar al menos un día de la semana.")}

        true ->
          professional = socket.assigns.current_professional
          patient = socket.assigns.patient

          attrs = %{
            "instruction" => instruction,
            "draft_message" => preview_draft,
            "approved_text" => preview_draft,
            "schedule_type" => schedule_type,
            "date" => date,
            "time" => time,
            "weekdays" => weekdays,
            "end_date" => end_date
          }

          socket = assign(socket, :approving, true)

          case Triggers.create_and_approve_trigger(professional, patient.id, attrs) do
            {:ok, trigger} ->
              {:noreply,
               socket
               |> assign(:approving, false)
               |> stream_insert(:active_triggers, trigger, at: 0)
               |> assign(:active_triggers_empty?, false)
               |> assign(:preview_draft, nil)
               |> assign(:preview_instruction, nil)
               |> assign(
                 :form,
                 to_form(
                   %{
                     "instruction" => "",
                     "schedule_type" => "once",
                     "date" => "",
                     "time" => "",
                     "weekdays" => [],
                     "end_date" => ""
                   },
                   as: "trigger"
                 )
               )
               |> put_flash(:info, "Trigger programado exitosamente.")}

            {:error, {:gap, msg}} ->
              {:noreply, socket |> assign(:approving, false) |> put_flash(:error, msg)}

            {:error, {:ambiguous, msg}} ->
              {:noreply, socket |> assign(:approving, false) |> put_flash(:error, msg)}

            {:error, {:invalid_end_date, msg}} ->
              {:noreply, socket |> assign(:approving, false) |> put_flash(:error, msg)}

            {:error, :invalid_end_date} ->
              {:noreply,
               socket
               |> assign(:approving, false)
               |> put_flash(
                 :error,
                 "La fecha de fin no puede ser anterior al primer envío."
               )}

            {:error, {:empty_weekdays, msg}} ->
              {:noreply, socket |> assign(:approving, false) |> put_flash(:error, msg)}

            {:error, :empty_weekdays} ->
              {:noreply,
               socket
               |> assign(:approving, false)
               |> put_flash(:error, "Debes seleccionar al menos un día de la semana.")}

            {:error, :past_schedule} ->
              {:noreply,
               socket
               |> assign(:approving, false)
               |> put_flash(:error, "La fecha y hora programada debe ser en el futuro.")}

            {:error, :empty_instruction} ->
              {:noreply,
               socket
               |> assign(:approving, false)
               |> put_flash(:error, "La instrucción no puede estar vacía.")}

            {:error, :empty_approved_text} ->
              {:noreply,
               socket
               |> assign(:approving, false)
               |> put_flash(:error, "El texto aprobado no puede estar vacío.")}

            {:error, _reason} ->
              {:noreply,
               socket
               |> assign(:approving, false)
               |> put_flash(
                 :error,
                 "No se pudo programar el trigger. Revisa los datos e inténtalo nuevamente."
               )}
          end
      end
    end
  end

  defp format_datetime(%DateTime{} = dt) do
    Calendar.strftime(dt, "%d/%m/%Y %H:%M UTC")
  end

  defp format_datetime(nil), do: ""

  defp format_date(%Date{} = d) do
    Calendar.strftime(d, "%d/%m/%Y")
  end

  defp format_date(_), do: ""

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id="triggers-page"
      class="triggers-container"
      style="max-width: 840px; margin: 0 auto; padding: 24px;"
    >
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
          <h1 class="pt-h1">Triggers · {@patient.alias}</h1>
          <p class="pt-muted">Programación de mensajes proactivos aprobados.</p>
        </div>
      </div>

      <%!-- Navegación de pestañas --%>
      <div
        class="tabs"
        style="display: flex; gap: 8px; margin-bottom: 24px; border-bottom: 1px solid var(--color-border);"
      >
        <button
          type="button"
          id="tab-active"
          phx-click="switch_tab"
          phx-value-tab="active"
          class={[
            "button-tab",
            @active_tab == "active" && "button-tab--active font-bold border-b-2 border-primary"
          ]}
          style="padding: 8px 16px; cursor: pointer;"
        >
          Activos
        </button>
        <button
          type="button"
          id="tab-history"
          phx-click="switch_tab"
          phx-value-tab="history"
          class={[
            "button-tab",
            @active_tab == "history" && "button-tab--active font-bold border-b-2 border-primary"
          ]}
          style="padding: 8px 16px; cursor: pointer;"
        >
          Historial
        </button>
      </div>

      <%!-- Panel de Pestaña Activos --%>
      <div id="active-tab-panel" class={@active_tab != "active" && "hidden"}>
        <%!-- Formulario de Creación de Trigger --%>
        <div class="pt-card" style="margin-bottom: 28px;">
          <div class="pt-card__head">
            <span class="pt-h2">Nuevo trigger activo</span>
          </div>
          <div class="pt-card__body">
            <.form for={@form} id="trigger-form" phx-change="validate" phx-submit="generate_preview">
              <.input
                id="trigger-instruction-input"
                field={@form[:instruction]}
                type="textarea"
                label="Instrucción terapéutica"
                placeholder="Escribe la instrucción en lenguaje clínico (ej. Preguntar cómo se sintió con el ejercicio de respiración)..."
                rows="3"
                required
              />

              <div style="margin-top: 12px;">
                <.input
                  id="trigger-schedule-type-select"
                  field={@form[:schedule_type]}
                  type="select"
                  label="Frecuencia"
                  options={[
                    {"Una sola vez", "once"},
                    {"Diario", "daily"},
                    {"Semanal", "weekly"}
                  ]}
                />
              </div>

              <%= if (@form[:schedule_type].value || "once") == "weekly" do %>
                <div id="trigger-weekdays-selector" style="margin-top: 12px;">
                  <label class="block text-sm font-semibold leading-6 mb-1">Días de la semana</label>
                  <div style="display: flex; gap: 8px; flex-wrap: wrap;">
                    <%= for {day_name, day_num} <- [{"Lun", 1}, {"Mar", 2}, {"Mié", 3}, {"Jue", 4}, {"Vie", 5}, {"Sáb", 6}, {"Dom", 7}] do %>
                      <label
                        class="pt-weekday-checkbox"
                        style="display: inline-flex; align-items: center; gap: 4px; padding: 6px 10px; border: 1px solid var(--color-border); border-radius: 6px; cursor: pointer; font-size: 0.9em;"
                      >
                        <input
                          type="checkbox"
                          id={"trigger-weekday-#{day_num}"}
                          name="trigger[weekdays][]"
                          value={to_string(day_num)}
                          checked={
                            to_string(day_num) in (List.wrap(@form[:weekdays].value)
                                                   |> Enum.map(&to_string/1))
                          }
                        />
                        <span>{day_name}</span>
                      </label>
                    <% end %>
                  </div>
                </div>
              <% end %>

              <%= if (@form[:schedule_type].value || "once") == "once" do %>
                <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 16px; margin-top: 12px;">
                  <.input
                    id="trigger-date-input"
                    field={@form[:date]}
                    type="date"
                    label="Fecha de envío"
                    required
                  />
                  <.input
                    id="trigger-time-input"
                    field={@form[:time]}
                    type="time"
                    label={"Hora de envío (#{@patient.timezone || "America/Santiago"})"}
                    required
                  />
                </div>
              <% else %>
                <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 16px; margin-top: 12px;">
                  <.input
                    id="trigger-time-input"
                    field={@form[:time]}
                    type="time"
                    label={"Hora de envío (#{@patient.timezone || "America/Santiago"})"}
                    required
                  />
                  <.input
                    id="trigger-end-date-input"
                    field={@form[:end_date]}
                    type="date"
                    label="Fecha de fin (opcional)"
                  />
                </div>
              <% end %>

              <div class="form-actions" style="margin-top: 16px; display: flex; gap: 8px;">
                <button
                  type="submit"
                  id="generate-preview-button"
                  phx-click="generate_preview"
                  class="button-secondary button-secondary--sm"
                >
                  <.icon name="hero-sparkles" class="size-4" style="margin-right: 4px;" />
                  Generar vista previa
                </button>
              </div>
            </.form>

            <%!-- Card de Vista Previa Aprobatoria --%>
            <%= if @preview_draft do %>
              <div
                id="trigger-preview-card"
                class="pt-card"
                style="margin-top: 20px; border-left: 4px solid var(--color-primary); background: var(--color-surface-subtle);"
              >
                <div class="pt-card__head">
                  <span class="pt-h3">Vista previa del mensaje para el paciente</span>
                </div>
                <div class="pt-card__body">
                  <p
                    id="trigger-preview-draft"
                    style="font-size: 1.1em; line-height: 1.5; margin-bottom: 16px;"
                  >
                    {@preview_draft}
                  </p>
                  <button
                    type="button"
                    id="approve-trigger-button"
                    phx-click="approve_trigger"
                    phx-disable-with="Programando..."
                    class="button-primary button-primary--sm"
                  >
                    <.icon name="hero-check" class="size-4" style="margin-right: 4px;" />
                    Aprobar y programar
                  </button>
                </div>
              </div>
            <% end %>
          </div>
        </div>

        <%!-- Lista de Triggers Activos --%>
        <div>
          <h2 class="pt-h2" style="margin-bottom: 16px;">Triggers programados</h2>

          <div :if={@active_triggers_empty?} id="active-triggers-empty" class="pt-empty-state">
            <p class="pt-muted">No hay triggers activos programados para este paciente.</p>
          </div>

          <div
            id="active-triggers"
            phx-update="stream"
            style="display: flex; flex-direction: column; gap: 12px;"
          >
            <div
              :for={{id, trigger} <- @streams.active_triggers}
              id={id}
              class="pt-card"
              style="padding: 16px;"
            >
              <div id={"active-trigger-#{trigger.id}"}>
                <div style="display: flex; justify-content: space-between; align-items: flex-start; margin-bottom: 8px;">
                  <div>
                    <span class="pt-pill pt-pill--active">Activo</span>
                    <span
                      id={"trigger-schedule-badge-#{trigger.id}"}
                      class="pt-pill"
                      style="margin-left: 6px; font-size: 0.85em; background: var(--color-surface-subtle);"
                    >
                      {Triggers.schedule_badge(trigger)}
                    </span>
                    <span class="pt-muted" style="margin-left: 8px; font-size: 0.85em;">
                      Próximo envío: {format_datetime(trigger.scheduled_at)}
                    </span>
                    <%= if trigger.end_date do %>
                      <span
                        id={"trigger-end-date-#{trigger.id}"}
                        class="pt-muted"
                        style="margin-left: 8px; font-size: 0.85em;"
                      >
                        · Hasta: {format_date(trigger.end_date)}
                      </span>
                    <% end %>
                  </div>
                </div>
                <p style="font-size: 1em; margin-bottom: 6px;">
                  <strong>Mensaje aprobado:</strong> {trigger.decrypted_approved_text || "(Cifrado)"}
                </p>
                <p class="pt-muted" style="font-size: 0.85em;">
                  <em>Instrucción original:</em> {trigger.decrypted_instruction || "(Cifrada)"}
                </p>
              </div>
            </div>
          </div>
        </div>
      </div>

      <%!-- Panel de Pestaña Historial --%>
      <div id="history-tab-panel" class={@active_tab != "history" && "hidden"}>
        <div>
          <h2 class="pt-h2" style="margin-bottom: 16px;">Historial de envíos</h2>

          <div :if={@firings_empty?} id="trigger-firings-empty" class="pt-empty-state">
            <p class="pt-muted">No hay envíos en el historial.</p>
          </div>

          <div
            id="trigger-firings"
            phx-update="stream"
            style="display: flex; flex-direction: column; gap: 12px;"
          >
            <div
              :for={{id, firing} <- @streams.firings}
              id={id}
              class="pt-card"
              style="padding: 16px; display: flex; justify-content: space-between; align-items: center;"
            >
              <div id={"firing-#{firing.id}"}>
                <div style="margin-bottom: 4px;">
                  <%= if firing.message && firing.message.delivery_state == "sent" do %>
                    <span class="pt-pill pt-pill--sent">Enviado</span>
                  <% else %>
                    <span class="pt-pill pt-pill--queued">En cola</span>
                  <% end %>
                  <span class="pt-muted" style="margin-left: 8px; font-size: 0.85em;">
                    Disparado el: {format_datetime(firing.fired_at)}
                  </span>
                </div>
                <p class="pt-muted" style="font-size: 0.85em;">
                  ID del trigger: {firing.trigger_id}
                </p>
              </div>

              <div>
                <.link
                  id={"firing-message-link-#{firing.id}"}
                  navigate={~p"/patients/#{@patient.id}/triggers/messages/#{firing.message_id}"}
                  class="button-secondary button-secondary--sm"
                >
                  Ver mensaje
                </.link>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
