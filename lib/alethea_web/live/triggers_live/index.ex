defmodule AletheaWeb.TriggersLive.Index do
  @moduledoc """
  Patient-scoped triggers management page (Issue #440, #442).
  Allows the owning professional to view active/inactive/fired triggers, generate clinically
  neutral previews, approve/schedule triggers, edit instructions with server-owned reapproval,
  activate/deactivate triggers, and inspect firing history.
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
      with {:ok, triggers} <- Triggers.list_triggers(professional, patient.id),
           {:ok, firings} <- Triggers.list_firings(professional, patient.id) do
        socket =
          socket
          |> assign(:page_title, "Triggers · #{patient.alias}")
          |> assign(:patient, patient)
          |> assign(:active_tab, "active")
          |> assign(:preview_draft, nil)
          |> assign(:preview_instruction, nil)
          |> assign(:approving, false)
          |> assign(:editing_trigger_id, nil)
          |> assign(:edit_form, nil)
          |> assign(:edit_preview_draft, nil)
          |> assign(:edit_preview_revision, nil)
          |> assign(:edit_preview_instruction, nil)
          |> assign(:edit_preview_trigger_id, nil)
          |> assign(:edit_approving, false)
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
          |> assign(:active_triggers_empty?, triggers == [])
          |> assign(:firings_empty?, firings == [])
          |> stream(:active_triggers, triggers)
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
      preview_instruction = socket.assigns.preview_instruction
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

  def handle_event("deactivate_trigger", %{"id" => trigger_id}, socket) do
    professional = socket.assigns.current_professional
    patient = socket.assigns.patient

    case Triggers.deactivate_trigger(professional, patient.id, trigger_id) do
      {:ok, updated_trigger} ->
        {:noreply,
         socket
         |> stream_insert(:active_triggers, updated_trigger)
         |> put_flash(:info, "Trigger desactivado.")}

      {:error, :already_fired} ->
        {:noreply,
         put_flash(socket, :error, "El trigger ya fue ejecutado y no puede ser modificado.")}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "No estás autorizado para modificar este trigger.")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Trigger no encontrado.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "No se pudo desactivar el trigger.")}
    end
  end

  def handle_event("activate_trigger", %{"id" => trigger_id}, socket) do
    professional = socket.assigns.current_professional
    patient = socket.assigns.patient

    case Triggers.activate_trigger(professional, patient.id, trigger_id) do
      {:ok, updated_trigger} ->
        {:noreply,
         socket
         |> stream_insert(:active_triggers, updated_trigger)
         |> put_flash(:info, "Trigger activado exitosamente.")}

      {:error, :unapproved} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "No se puede activar un trigger sin mensaje aprobado. Genera y aprueba una vista previa primero."
         )}

      {:error, {:expired_schedule, msg}} ->
        {:noreply, put_flash(socket, :error, msg)}

      {:error, {:end_date_passed, msg}} ->
        {:noreply, put_flash(socket, :error, msg)}

      {:error, :already_fired} ->
        {:noreply,
         put_flash(socket, :error, "El trigger ya fue ejecutado y no puede ser modificado.")}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "No estás autorizado para modificar este trigger.")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Trigger no encontrado.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "No se pudo activar el trigger.")}
    end
  end

  def handle_event("resume_trigger", %{"id" => trigger_id}, socket) do
    professional = socket.assigns.current_professional
    patient = socket.assigns.patient

    case Triggers.resume_trigger(professional, patient.id, trigger_id) do
      {:ok, updated_trigger} ->
        {:noreply,
         socket
         |> stream_insert(:active_triggers, updated_trigger)
         |> put_flash(:info, "Trigger reanudado exitosamente.")}

      {:error, :unapproved} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "No se puede reanudar un trigger sin mensaje aprobado. Genera y aprueba una vista previa primero."
         )}

      {:error, {:expired_schedule, msg}} ->
        {:noreply, put_flash(socket, :error, msg)}

      {:error, {:end_date_passed, msg}} ->
        {:noreply, put_flash(socket, :error, msg)}

      {:error, :already_fired} ->
        {:noreply,
         put_flash(socket, :error, "El trigger ya fue ejecutado y no puede ser modificado.")}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "No estás autorizado para modificar este trigger.")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Trigger no encontrado.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "No se pudo reanudar el trigger.")}
    end
  end

  def handle_event("edit_trigger", %{"id" => trigger_id}, socket) do
    professional = socket.assigns.current_professional
    patient = socket.assigns.patient
    previous_id = socket.assigns[:editing_trigger_id]

    case Triggers.get_trigger(professional, patient.id, trigger_id) do
      {:ok, trigger} ->
        socket =
          if previous_id != nil and previous_id != trigger_id do
            case Triggers.get_trigger(professional, patient.id, previous_id) do
              {:ok, prev_trigger} -> stream_insert(socket, :active_triggers, prev_trigger)
              _ -> socket
            end
          else
            socket
          end

        form =
          to_form(
            %{"instruction" => trigger.decrypted_instruction || ""},
            as: "edit_trigger"
          )

        {:noreply,
         socket
         |> assign(:editing_trigger_id, trigger.id)
         |> assign(:edit_form, form)
         |> assign(:edit_preview_draft, nil)
         |> assign(:edit_preview_revision, nil)
         |> assign(:edit_preview_instruction, nil)
         |> assign(:edit_preview_trigger_id, nil)
         |> assign(:edit_approving, false)
         |> stream_insert(:active_triggers, trigger)}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "No estás autorizado para modificar este trigger.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Trigger no encontrado.")}
    end
  end

  def handle_event("cancel_edit", %{"id" => trigger_id}, socket) do
    professional = socket.assigns.current_professional
    patient = socket.assigns.patient

    socket =
      socket
      |> assign(:editing_trigger_id, nil)
      |> assign(:edit_form, nil)
      |> assign(:edit_preview_draft, nil)
      |> assign(:edit_preview_revision, nil)
      |> assign(:edit_preview_instruction, nil)
      |> assign(:edit_preview_trigger_id, nil)
      |> assign(:edit_approving, false)

    case Triggers.get_trigger(professional, patient.id, trigger_id) do
      {:ok, trigger} ->
        {:noreply, stream_insert(socket, :active_triggers, trigger)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("validate_edit", %{"edit_trigger" => params}, socket) do
    new_instruction = Map.get(params, "instruction", "") |> String.trim()
    preview_instruction = socket.assigns[:edit_preview_instruction]
    trigger_id = socket.assigns[:editing_trigger_id]
    professional = socket.assigns.current_professional
    patient = socket.assigns.patient

    # Invalidate displayed preview if instruction differs from preview snapshot
    socket =
      if preview_instruction != nil and preview_instruction != new_instruction do
        s =
          socket
          |> assign(:edit_preview_draft, nil)
          |> assign(:edit_preview_revision, nil)
          |> assign(:edit_preview_instruction, nil)
          |> assign(:edit_preview_trigger_id, nil)

        case Triggers.get_trigger(professional, patient.id, trigger_id) do
          {:ok, trigger} -> stream_insert(s, :active_triggers, trigger)
          _ -> s
        end
      else
        socket
      end

    {:noreply, assign(socket, :edit_form, to_form(params, as: "edit_trigger"))}
  end

  def handle_event("save_and_preview_edit", params, socket) do
    trigger_id =
      Map.get(params, "trigger_id") ||
        Map.get(params, "id") ||
        socket.assigns[:editing_trigger_id]

    edit_params = Map.get(params, "edit_trigger") || %{}
    new_instruction = Map.get(edit_params, "instruction", "") |> String.trim()

    cond do
      is_nil(trigger_id) ->
        {:noreply, socket}

      new_instruction == "" ->
        {:noreply,
         socket
         |> put_flash(:error, "La instrucción no puede estar vacía.")
         |> assign(:edit_form, to_form(edit_params, as: "edit_trigger"))}

      true ->
        professional = socket.assigns.current_professional
        patient = socket.assigns.patient

        # Security guarantee: Persist instruction edit FIRST in DB
        # Clears old approval, increments approval_revision, deletes pending scheduled jobs
        case Triggers.update_trigger_instruction(
               professional,
               patient.id,
               trigger_id,
               new_instruction
             ) do
          {:ok, updated_trigger} ->
            socket =
              socket
              |> stream_insert(:active_triggers, updated_trigger)
              |> assign(:edit_form, to_form(edit_params, as: "edit_trigger"))

            # Step 2: Preview generation uses current server-fetched instruction and its positive approval_revision snapshot
            case Triggers.generate_preview(
                   professional,
                   patient.id,
                   updated_trigger.decrypted_instruction
                 ) do
              {:ok, %{draft: draft}} ->
                {:noreply,
                 socket
                 |> assign(:edit_preview_draft, draft)
                 |> assign(:edit_preview_revision, updated_trigger.approval_revision)
                 |> assign(:edit_preview_instruction, updated_trigger.decrypted_instruction)
                 |> assign(:edit_preview_trigger_id, updated_trigger.id)
                 |> put_flash(:info, "Vista previa generada.")}

              {:error, :unauthorized} ->
                {:noreply,
                 socket
                 |> assign(:edit_preview_draft, nil)
                 |> assign(:edit_preview_revision, nil)
                 |> assign(:edit_preview_instruction, nil)
                 |> assign(:edit_preview_trigger_id, nil)
                 |> put_flash(:error, "No estás autorizado para generar vistas previas.")}

              {:error, _reason} ->
                {:noreply,
                 socket
                 |> assign(:edit_preview_draft, nil)
                 |> assign(:edit_preview_revision, nil)
                 |> assign(:edit_preview_instruction, nil)
                 |> assign(:edit_preview_trigger_id, nil)
                 |> put_flash(
                   :error,
                   "No se pudo generar la vista previa. La instrucción fue guardada, pero requiere aprobación antes de enviar."
                 )}
            end

          {:error, :empty_instruction} ->
            {:noreply, put_flash(socket, :error, "La instrucción no puede estar vacía.")}

          {:error, :already_fired} ->
            {:noreply,
             put_flash(socket, :error, "El trigger ya fue ejecutado y no puede ser modificado.")}

          {:error, :unauthorized} ->
            {:noreply,
             put_flash(socket, :error, "No estás autorizado para modificar este trigger.")}

          {:error, :not_found} ->
            {:noreply, put_flash(socket, :error, "Trigger no encontrado.")}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, "No se pudo actualizar la instrucción.")}
        end
    end
  end

  def handle_event("approve_edit", params, socket) do
    trigger_id =
      Map.get(params, "id") ||
        Map.get(params, "trigger_id") ||
        socket.assigns[:editing_trigger_id]

    if socket.assigns[:edit_approving] do
      {:noreply, socket}
    else
      preview_draft = socket.assigns[:edit_preview_draft]
      preview_revision = socket.assigns[:edit_preview_revision]
      preview_instruction = socket.assigns[:edit_preview_instruction]
      preview_trigger_id = socket.assigns[:edit_preview_trigger_id]

      cond do
        is_nil(trigger_id) ->
          {:noreply, socket}

        is_nil(preview_draft) or String.trim(preview_draft) == "" or
          is_nil(preview_revision) or preview_trigger_id != trigger_id ->
          {:noreply,
           put_flash(socket, :error, "Debes generar una vista previa antes de aprobar.")}

        true ->
          professional = socket.assigns.current_professional
          patient = socket.assigns.patient

          # Bind expected_revision and expected_instruction strictly from server-owned state
          # Never trust client approved_text/expected_revision params
          attrs = %{
            "expected_revision" => preview_revision,
            "expected_instruction" => preview_instruction,
            "approved_text" => preview_draft,
            "draft_message" => preview_draft
          }

          socket = assign(socket, :edit_approving, true)

          case Triggers.reapprove_trigger(professional, patient.id, trigger_id, attrs) do
            {:ok, reapproved_trigger} ->
              {:noreply,
               socket
               |> assign(:edit_approving, false)
               |> assign(:editing_trigger_id, nil)
               |> assign(:edit_form, nil)
               |> assign(:edit_preview_draft, nil)
               |> assign(:edit_preview_revision, nil)
               |> assign(:edit_preview_instruction, nil)
               |> assign(:edit_preview_trigger_id, nil)
               |> stream_insert(:active_triggers, reapproved_trigger)
               |> put_flash(:info, "Trigger actualizado y aprobado exitosamente.")}

            {:error, :stale_revision} ->
              socket =
                socket
                |> assign(:edit_approving, false)
                |> assign(:edit_preview_draft, nil)
                |> assign(:edit_preview_revision, nil)
                |> assign(:edit_preview_instruction, nil)
                |> assign(:edit_preview_trigger_id, nil)
                |> put_flash(
                  :error,
                  "El trigger fue modificado concurrentemente. Debes generar una nueva vista previa antes de aprobar."
                )

              case Triggers.get_trigger(professional, patient.id, trigger_id) do
                {:ok, trigger} -> {:noreply, stream_insert(socket, :active_triggers, trigger)}
                _ -> {:noreply, socket}
              end

            {:error, :stale_instruction} ->
              socket =
                socket
                |> assign(:edit_approving, false)
                |> assign(:edit_preview_draft, nil)
                |> assign(:edit_preview_revision, nil)
                |> assign(:edit_preview_instruction, nil)
                |> assign(:edit_preview_trigger_id, nil)
                |> put_flash(
                  :error,
                  "La instrucción del trigger cambió. Debes generar una nueva vista previa antes de aprobar."
                )

              case Triggers.get_trigger(professional, patient.id, trigger_id) do
                {:ok, trigger} -> {:noreply, stream_insert(socket, :active_triggers, trigger)}
                _ -> {:noreply, socket}
              end

            {:error, {:expired_schedule, msg}} ->
              {:noreply, socket |> assign(:edit_approving, false) |> put_flash(:error, msg)}

            {:error, {:end_date_passed, msg}} ->
              {:noreply, socket |> assign(:edit_approving, false) |> put_flash(:error, msg)}

            {:error, :missing_expected_revision} ->
              {:noreply,
               socket
               |> assign(:edit_approving, false)
               |> put_flash(
                 :error,
                 "Falta la revisión de vista previa. Genera una nueva vista previa antes de aprobar."
               )}

            {:error, :empty_approved_text} ->
              {:noreply,
               socket
               |> assign(:edit_approving, false)
               |> put_flash(:error, "El texto aprobado no puede estar vacío.")}

            {:error, :already_fired} ->
              {:noreply,
               socket
               |> assign(:edit_approving, false)
               |> put_flash(
                 :error,
                 "El trigger ya fue ejecutado y no puede ser modificado."
               )}

            {:error, :unauthorized} ->
              {:noreply,
               socket
               |> assign(:edit_approving, false)
               |> put_flash(
                 :error,
                 "No estás autorizado para modificar este trigger."
               )}

            {:error, :not_found} ->
              {:noreply,
               socket
               |> assign(:edit_approving, false)
               |> put_flash(:error, "Trigger no encontrado.")}

            {:error, _reason} ->
              {:noreply,
               socket
               |> assign(:edit_approving, false)
               |> put_flash(
                 :error,
                 "No se pudo aprobar el trigger. Inténtalo nuevamente."
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

        <%!-- Lista de Triggers Activos / Gestionables --%>
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
                  <div style="display: flex; align-items: center; flex-wrap: wrap; gap: 6px;">
                    <%= cond do %>
                      <% trigger.status == "active" -> %>
                        <span
                          id={"trigger-status-badge-#{trigger.id}"}
                          class="pt-pill pt-pill--active"
                        >
                          Activo
                        </span>
                      <% trigger.status == "inactive" -> %>
                        <span
                          id={"trigger-status-badge-#{trigger.id}"}
                          class="pt-pill pt-pill--inactive"
                        >
                          Inactivo
                        </span>
                      <% trigger.status == "paused_by_crisis" -> %>
                        <span
                          id={"trigger-status-badge-#{trigger.id}"}
                          class="pt-pill pt-pill--risk"
                        >
                          Pausado por crisis
                        </span>
                      <% trigger.status == "paused_by_delivery_failures" -> %>
                        <span
                          id={"trigger-status-badge-#{trigger.id}"}
                          class="pt-pill pt-pill--risk"
                        >
                          Pausado por fallas de entrega
                        </span>
                      <% trigger.status == "fired" -> %>
                        <span id={"trigger-status-badge-#{trigger.id}"} class="pt-pill">
                          Finalizado
                        </span>
                      <% true -> %>
                        <span id={"trigger-status-badge-#{trigger.id}"} class="pt-pill">
                          {trigger.status}
                        </span>
                    <% end %>

                    <%= if is_nil(trigger.approved_text) do %>
                      <span
                        id={"trigger-approval-badge-#{trigger.id}"}
                        class="pt-pill pt-pill--warning"
                      >
                        Requiere aprobación
                      </span>
                    <% end %>

                    <span
                      id={"trigger-schedule-badge-#{trigger.id}"}
                      class="pt-pill"
                      style="font-size: 0.85em; background: var(--color-surface-subtle);"
                    >
                      {Triggers.schedule_badge(trigger)}
                    </span>
                    <span class="pt-muted" style="margin-left: 4px; font-size: 0.85em;">
                      Próximo envío: {format_datetime(trigger.scheduled_at)}
                    </span>
                    <%= if trigger.end_date do %>
                      <span
                        id={"trigger-end-date-#{trigger.id}"}
                        class="pt-muted"
                        style="font-size: 0.85em;"
                      >
                        · Hasta: {format_date(trigger.end_date)}
                      </span>
                    <% end %>
                  </div>

                  <%!-- Acciones sobre el trigger --%>
                  <div class="trigger-actions" style="display: flex; gap: 6px; align-items: center;">
                    <%= if trigger.status != "fired" do %>
                      <%= if @editing_trigger_id != trigger.id do %>
                        <button
                          type="button"
                          id={"edit-trigger-button-#{trigger.id}"}
                          phx-click="edit_trigger"
                          phx-value-id={trigger.id}
                          class="button-secondary button-secondary--sm"
                        >
                          Editar
                        </button>

                        <%= cond do %>
                          <% trigger.status == "active" -> %>
                            <button
                              type="button"
                              id={"deactivate-trigger-button-#{trigger.id}"}
                              phx-click="deactivate_trigger"
                              phx-value-id={trigger.id}
                              class="button-secondary button-secondary--sm text-amber-600 hover:text-amber-700"
                            >
                              Desactivar
                            </button>
                          <% trigger.status in ["paused_by_crisis", "paused_by_delivery_failures"] -> %>
                            <button
                              type="button"
                              id={"resume-trigger-button-#{trigger.id}"}
                              phx-click="resume_trigger"
                              phx-value-id={trigger.id}
                              class="button-secondary button-secondary--sm text-emerald-600 hover:text-emerald-700"
                            >
                              Reanudar
                            </button>
                          <% true -> %>
                            <button
                              type="button"
                              id={"activate-trigger-button-#{trigger.id}"}
                              phx-click="activate_trigger"
                              phx-value-id={trigger.id}
                              class="button-secondary button-secondary--sm text-emerald-600 hover:text-emerald-700"
                            >
                              Activar
                            </button>
                        <% end %>
                      <% end %>
                    <% end %>
                  </div>
                </div>

                <p style="font-size: 1em; margin-bottom: 6px;">
                  <strong>Mensaje aprobado:</strong>
                  <%= if trigger.decrypted_approved_text do %>
                    {trigger.decrypted_approved_text}
                  <% else %>
                    <span class="pt-muted italic">Pendiente de aprobación</span>
                  <% end %>
                </p>
                <p class="pt-muted" style="font-size: 0.85em;">
                  <em>Instrucción original:</em> {trigger.decrypted_instruction || "(Cifrada)"}
                </p>

                <%= if trigger.status == "paused_by_delivery_failures" do %>
                  <div
                    id={"trigger-pause-reason-#{trigger.id}"}
                    class="pt-alert pt-alert--warning"
                    style="margin-top: 8px; margin-bottom: 8px; padding: 8px 12px; border-radius: 6px; font-size: 0.9em; background: var(--color-surface-subtle); border-left: 3px solid #f59e0b;"
                  >
                    Pausado automáticamente tras 3 fallas consecutivas de entrega. Puedes reanudarlo cuando el canal esté disponible.
                  </div>
                <% end %>

                <%!-- Formulario de edición inline cuando @editing_trigger_id == trigger.id --%>
                <%= if @editing_trigger_id == trigger.id and @edit_form do %>
                  <div
                    id={"edit-trigger-section-#{trigger.id}"}
                    style="margin-top: 16px; padding-top: 16px; border-top: 1px solid var(--color-border);"
                  >
                    <.form
                      for={@edit_form}
                      id={"edit-trigger-form-#{trigger.id}"}
                      phx-change="validate_edit"
                      phx-submit="save_and_preview_edit"
                    >
                      <input type="hidden" name="trigger_id" value={trigger.id} />
                      <.input
                        id={"edit-instruction-input-#{trigger.id}"}
                        field={@edit_form[:instruction]}
                        type="textarea"
                        label="Instrucción terapéutica"
                        rows="3"
                        required
                      />

                      <div class="form-actions" style="margin-top: 12px; display: flex; gap: 8px;">
                        <button
                          type="submit"
                          id={"generate-edit-preview-button-#{trigger.id}"}
                          class="button-secondary button-secondary--sm"
                        >
                          <.icon name="hero-sparkles" class="size-4" style="margin-right: 4px;" />
                          Generar vista previa
                        </button>
                        <button
                          type="button"
                          id={"cancel-edit-button-#{trigger.id}"}
                          phx-click="cancel_edit"
                          phx-value-id={trigger.id}
                          class="button-secondary button-secondary--sm"
                        >
                          Cancelar
                        </button>
                      </div>
                    </.form>

                    <%!-- Card de Vista Previa Aprobatoria para Edit --%>
                    <%= if @edit_preview_trigger_id == trigger.id and @edit_preview_draft do %>
                      <div
                        id={"edit-preview-card-#{trigger.id}"}
                        class="pt-card"
                        style="margin-top: 16px; border-left: 4px solid var(--color-primary); background: var(--color-surface-subtle); padding: 12px;"
                      >
                        <div class="pt-card__head" style="margin-bottom: 8px;">
                          <span class="pt-h3">Nueva vista previa del mensaje</span>
                        </div>
                        <div class="pt-card__body">
                          <p
                            id={"edit-preview-draft-#{trigger.id}"}
                            style="font-size: 1.05em; line-height: 1.5; margin-bottom: 12px;"
                          >
                            {@edit_preview_draft}
                          </p>
                          <button
                            type="button"
                            id={"approve-edit-button-#{trigger.id}"}
                            phx-click="approve_edit"
                            phx-value-id={trigger.id}
                            phx-disable-with="Aprobando..."
                            class="button-primary button-primary--sm"
                          >
                            <.icon name="hero-check" class="size-4" style="margin-right: 4px;" />
                            Aprobar cambio
                          </button>
                        </div>
                      </div>
                    <% end %>
                  </div>
                <% end %>
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
                  <%= cond do %>
                    <% firing.status == "skipped" -> %>
                      <span id={"firing-status-#{firing.id}"} class="pt-pill pt-pill--neutral">
                        Omitido
                      </span>
                    <% firing.status == "not_delivered" or (firing.message && firing.message.delivery_state == "failed") -> %>
                      <span id={"firing-status-#{firing.id}"} class="pt-pill pt-pill--risk">
                        No entregado
                      </span>
                    <% firing.message && firing.message.delivery_state == "sent" -> %>
                      <span id={"firing-status-#{firing.id}"} class="pt-pill pt-pill--sent">
                        Enviado
                      </span>
                    <% true -> %>
                      <span id={"firing-status-#{firing.id}"} class="pt-pill pt-pill--queued">
                        En cola
                      </span>
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
                <%= if firing.message_id do %>
                  <.link
                    id={"firing-message-link-#{firing.id}"}
                    navigate={~p"/patients/#{@patient.id}/triggers/messages/#{firing.message_id}"}
                    class="button-secondary button-secondary--sm"
                  >
                    Ver mensaje
                  </.link>
                <% end %>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
