defmodule AletheaWeb.PatientLive.Index do
  @moduledoc """
  The caseload management page.

  Same editorial vocabulary as the dashboard: an editorial page head,
  a hairline stat strip, and the caseload as a card grid. Registering
  a patient opens an inline card above the grid instead of a second
  column, so the page keeps one reading order at every width.
  """
  use AletheaWeb, :live_view

  alias Alethea.Accounts
  alias Alethea.Accounts.Patient

  @impl true
  def mount(_params, _session, socket) do
    topic = "patients:#{socket.assigns.current_professional.id}"

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Alethea.PubSub, "psychologist:alerts")
      Phoenix.PubSub.subscribe(Alethea.PubSub, topic)
    end

    patients = Accounts.list_patients(socket.assigns.current_professional.id)

    socket =
      socket
      |> assign(:patients, patients)
      |> assign(:selected_patient, nil)
      |> stream(:patients, patients)

    {:ok, socket}
  end

  @impl true
  def handle_info({:crisis_detected, %{patient_id: patient_id}}, socket) do
    patient = Accounts.get_patient!(patient_id)

    if patient.professional_id == socket.assigns.current_professional.id do
      {:noreply, stream_insert(socket, :patients, patient)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:patient_created, patient}, socket) do
    if patient.professional_id == socket.assigns.current_professional.id do
      patients = Accounts.list_patients(socket.assigns.current_professional.id)

      {:noreply,
       socket
       |> assign(:patients, patients)
       |> stream(:patients, patients, reset: true)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Mis Pacientes")
    |> assign(:patient, nil)
  end

  defp apply_action(socket, :new, _params) do
    changeset = Patient.changeset(%Patient{}, %{})

    socket
    |> assign(:page_title, "Registrar Paciente")
    |> assign(:patient, %Patient{})
    |> assign(:selected_patient, nil)
    |> assign(:form, to_form(changeset))
  end

  @impl true
  def handle_event("validate", %{"patient" => patient_params}, socket) do
    changeset =
      %Patient{}
      |> Patient.changeset(patient_params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  @impl true
  def handle_event("save", %{"patient" => patient_params}, socket) do
    patient_params =
      Map.put(patient_params, "professional_id", socket.assigns.current_professional.id)

    case Accounts.create_patient(patient_params, socket.assigns.professional_kek) do
      {:ok, _patient} ->
        patients = Accounts.list_patients(socket.assigns.current_professional.id)

        {:noreply,
         socket
         |> put_flash(:info, "Paciente registrado exitosamente.")
         |> assign(:patients, patients)
         |> stream(:patients, patients, reset: true)
         |> push_patch(to: ~p"/patients")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Error al cifrar datos: #{inspect(reason)}")}
    end
  end

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns, :urgent_count, Enum.count(assigns.patients, & &1.urgent_intervention))

    ~H"""
    <div class="pt ptd-wrap">
      <%!-- ── Header ── --%>
      <div class="ptd-head">
        <div>
          <p class="pt-eyebrow">Gestión de pacientes</p>

          <h1 class="pt-h1">{@current_professional.full_name || "Profesional Clínico"}</h1>
        </div>

        <div :if={@live_action != :new} class="page-head__actions">
          <.link patch={~p"/patients/new"} class="button-primary button-primary--sm">
            <.icon name="hero-plus" class="size-4" style="margin-right:6px;" /> Registrar paciente
          </.link>
        </div>
      </div>
      <%!-- ── Caseload counters ── --%>
      <div class="stat-strip" style="margin-bottom:24px;">
        <div class="stat-tile">
          <div class="stat-tile__label">Pacientes</div>

          <div class="stat-tile__value">{length(@patients)}</div>

          <div class="stat-tile__desc">En seguimiento</div>
        </div>

        <div class="stat-tile">
          <div class="stat-tile__label">Bóvedas</div>

          <div class="stat-tile__value">{length(@patients)}</div>

          <div class="stat-tile__desc">Una clave por paciente</div>
        </div>

        <div class="stat-tile">
          <div class="stat-tile__label">Atención</div>

          <div class="stat-tile__value">{@urgent_count}</div>

          <div class="stat-tile__desc">Intervención urgente</div>
        </div>
      </div>
      <%!-- ── New patient form (inline, above the grid) ── --%>
      <div :if={@live_action == :new} class="pt-card" style="margin-bottom:24px;">
        <div class="pt-card__head">
          <span class="pt-h2">Registrar nuevo paciente</span>
          <.link patch={~p"/patients"} class="link-button">Cancelar</.link>
        </div>

        <div class="pt-card__body">
          <div class="notice notice--success">
            <.icon name="hero-shield-check" class="notice__icon" />
            <span>Los datos clínicos se cifran con una DEK única por paciente y nunca
              son visibles en texto plano.</span>
          </div>

          <.form for={@form} id="patient-form" phx-change="validate" phx-submit="save">
            <div class="field">
              <label for="patient-alias" class="field__label">Alias del paciente</label>
              <input
                type="text"
                id="patient-alias"
                name="patient[alias]"
                value={@form[:alias].value || ""}
                placeholder="Ej. Juan P."
                autocomplete="off"
                class={[
                  "text-input",
                  @form[:alias].errors != [] && "text-input--error"
                ]}
              />
              <%!-- The changeset carries `{message, opts}` tuples, so the
                   message has to be translated before it can be printed. --%>
              <p :for={error <- @form[:alias].errors} class="field__error">
                <.icon name="hero-exclamation-circle" class="size-3" />{translate_error(error)}
              </p>

              <p :if={@form[:alias].errors == []} class="field__hint">
                El alias es lo único que Alethea muestra en claro. No uses el
                nombre legal del paciente.
              </p>
            </div>

            <div class="form-actions">
              <button type="submit" class="button-primary button-primary--sm">
                <.icon name="hero-lock-closed" class="size-4" style="margin-right:6px;" />
                Registrar paciente
              </button>
              <.link patch={~p"/patients"} class="button-secondary button-secondary--sm">
                Cancelar
              </.link>
            </div>
          </.form>
        </div>
      </div>
      <%!-- ── Caseload grid ── --%>
      <div :if={@patients == []} class="empty-state">
        <.icon name="hero-user-plus" class="empty-state__icon" />
        <p class="empty-state__title">Todavía no hay pacientes</p>

        <p class="empty-state__text">Registrá al primero para generar su bóveda cifrada y su enlace de
          Telegram.</p>

        <.link patch={~p"/patients/new"} class="button-primary button-primary--sm">
          Registrar paciente
        </.link>
      </div>

      <nav :if={@patients != []} id="patients-list" phx-update="stream" class="patient-grid">
        <.link
          :for={{dom_id, patient} <- @streams.patients}
          id={dom_id}
          navigate={~p"/dashboard?patient_id=#{patient.id}"}
          class={["patient-card", patient.urgent_intervention && "patient-card--risk"]}
        >
          <div class="patient-card__head">
            <span class={[
              "pt-avatar patient-card__avatar",
              patient.urgent_intervention && "pt-avatar--risk"
            ]}>
              {initials(patient.alias)}
            </span>
            <div style="min-width:0;">
              <div class="patient-card__name">{patient.alias}</div>

              <div class="patient-card__meta">{schedule_label(patient)}</div>
            </div>
          </div>

          <div class="patient-card__foot">
            <span style="display:flex; align-items:center; gap:6px; font-size:12px;">
              <span class={[
                "status-dot",
                if(patient.urgent_intervention, do: "status-dot--risk", else: "status-dot--ok")
              ]}>
              </span> {if patient.urgent_intervention,
                do: "Intervención urgente",
                else: "En seguimiento"}
            </span>
          </div>
        </.link>
      </nav>
    </div>
    """
  end

  defp initials(patient_alias) when is_binary(patient_alias) do
    patient_alias
    |> String.split()
    |> Enum.map(&String.first/1)
    |> Enum.take(2)
    |> Enum.join()
    |> String.upcase()
  end

  defp initials(_), do: "?"

  # One line, not two halves: without a scheduled day there is no time
  # to print either, so the card says "Sin horario" instead of
  # "Sin horario · sin hora".
  defp schedule_label(%{session_day_of_week: day, session_time: time}) when not is_nil(day) do
    "#{format_session_day(day)} · #{format_session_time(time)}"
  end

  defp schedule_label(_), do: "Sin horario"

  defp format_session_day(day) do
    days = ["", "Lun", "Mar", "Mié", "Jue", "Vie", "Sáb", "Dom"]
    Enum.at(days, day, "Sin día")
  end

  defp format_session_time(nil), do: "sin hora"

  defp format_session_time(time) do
    Calendar.strftime(time, "%H:%M")
  end
end
