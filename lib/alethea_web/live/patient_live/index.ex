defmodule AletheaWeb.PatientLive.Index do
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
    ~H"""
    <%!-- ── Header + stats ── --%>
    <div style="margin-bottom:24px;">
      <div style="margin-bottom:12px;">
        <p style="font-size:10px; font-weight:600; text-transform:uppercase; letter-spacing:0.1em; color:#94a3b8;">
          Alethea · Gestión de Pacientes
        </p>
        <h1 style="font-size:22px; font-weight:800; color:#1e293b; letter-spacing:-0.02em; margin-top:2px;">
          {@current_professional.full_name || "Profesional Clínico"}
        </h1>
      </div>

      <%!-- Stats --%>
      <div class="stats" style="border:1px solid #e2e8f0; border-radius:16px; background:#fff; box-shadow:0 1px 3px rgba(0,0,0,.04); display:inline-flex;">
        <div class="stat" style="padding:16px 24px;">
          <div class="stat-figure" style="color:#6366f1;">
            <.icon name="hero-users" style="width:28px; height:28px;" />
          </div>
          <div class="stat-title" style="font-size:10px; font-weight:700; text-transform:uppercase; letter-spacing:0.06em;">Pacientes</div>
          <div class="stat-value" style="font-size:22px; font-weight:800;">{length(@patients)}</div>
          <div class="stat-desc" style="font-size:11px; color:#94a3b8;">En seguimiento</div>
        </div>
        <div class="stat" style="padding:16px 24px;">
          <div class="stat-figure" style="color:#6366f1;">
            <.icon name="hero-lock-closed" style="width:28px; height:28px;" />
          </div>
          <div class="stat-title" style="font-size:10px; font-weight:700; text-transform:uppercase; letter-spacing:0.06em;">Bóvedas</div>
          <div class="stat-value" style="font-size:22px; font-weight:800;">{length(@patients)}</div>
          <div class="stat-desc" style="font-size:11px; color:#94a3b8;">Cifradas E2E</div>
        </div>
      </div>
    </div>

    <%!-- Two-column layout --%>
    <div style="display:grid; grid-template-columns:320px 1fr; gap:20px; min-height:400px;">

      <%!-- ──── LEFT: Patient list ──── --%>
      <div style="border-radius:16px; overflow:hidden; border:1px solid #e2e8f0; background:#fff; align-self:start;">
        <div style="display:flex; align-items:center; justify-content:space-between; padding:10px 14px; border-bottom:1px solid #f1f5f9; background:#fafbfc;">
          <div style="display:flex; align-items:center; gap:8px;">
            <.icon name="hero-users" style="width:14px; height:14px; color:#94a3b8;" />
            <span style="font-size:10px; font-weight:700; text-transform:uppercase; letter-spacing:0.06em; color:#64748b;">
              Pacientes
            </span>
          </div>
          <.button phx-click={JS.patch(~p"/patients/new")} class="btn btn-primary btn-sm" style="height:28px; font-size:11px;">
            <.icon name="hero-plus" class="mr-1" style="width:12px; height:12px;" /> Nuevo
          </.button>
        </div>

        <nav id="patients-list">
          <%= if @patients == [] do %>
            <div style="padding:40px 16px; text-align:center;">
              <.icon name="hero-user-plus" style="width:28px; height:28px; color:#cbd5e1; margin:0 auto 8px; display:block;" />
              <p style="font-size:12px; color:#94a3b8; margin-bottom:12px;">No hay pacientes aún</p>
              <.button phx-click={JS.patch(~p"/patients/new")} class="btn btn-primary btn-sm">
                Registrar paciente
              </.button>
            </div>
          <% end %>

          <%= for {_id, patient} <- @streams.patients do %>
            <.link
              navigate={~p"/dashboard?patient_id=#{patient.id}"}
              style={
                "display:flex; align-items:center; gap:10px; padding:10px 14px; text-decoration:none; transition:background .15s; border-bottom:1px solid #f8fafc;" <>
                if(@selected_patient && @selected_patient.id == patient.id,
                  do: "background:#eef2ff; border-left:3px solid #6366f1;",
                  else: "border-left:3px solid transparent;")
              }
            >
              <%!-- Avatar --%>
              <div style={
                "width:36px; height:36px; border-radius:50%; display:flex; align-items:center; justify-content:center; flex-shrink:0;" <>
                if(@selected_patient && @selected_patient.id == patient.id,
                  do: "background:rgba(99,102,241,.12);",
                  else: "background:#f1f5f9;")
              }>
                <span style={
                  "font-size:11px; font-weight:700;" <>
                  if(@selected_patient && @selected_patient.id == patient.id,
                    do: "color:#6366f1;",
                    else: "color:#64748b;")
                }>
                  {initials(patient.alias)}
                </span>
              </div>

              <div style="min-width:0; flex:1;">
                <div style="font-size:13px; font-weight:600; color:#1e293b;" class="truncate">{patient.alias}</div>
                <div style="font-size:10px; color:#94a3b8;">
                  {format_session_day(patient.session_day_of_week)} · {format_session_time(patient.session_time)}
                </div>
              </div>

              <%= if patient.urgent_intervention do %>
                <span style="width:8px; height:8px; border-radius:50%; background:#ef4444; flex-shrink:0;" class="animate-pulse"></span>
              <% end %>
            </.link>
          <% end %>
        </nav>
      </div>

      <%!-- ──── RIGHT: Content ──── --%>
      <div>
        <%= if @live_action == :new do %>
          <%!-- New patient form --%>
          <div style="border:1px solid #e2e8f0; border-radius:16px; background:#fff; overflow:hidden;">
            <div style="background:rgba(99,102,241,.06); border-bottom:1px solid rgba(99,102,241,.12); padding:14px 20px;">
              <div style="display:flex; align-items:center; gap:8px;">
                <.icon name="hero-user-plus" style="width:16px; height:16px; color:#6366f1;" />
                <span style="font-size:12px; font-weight:700; color:#6366f1; text-transform:uppercase; letter-spacing:0.04em;">
                  Registrar Nuevo Paciente
                </span>
              </div>
            </div>

            <div style="padding:20px;">
              <.simple_form
                for={@form}
                id="patient-form"
                phx-change="validate"
                phx-submit="save"
              >
                <div style="border:1px solid rgba(34,197,94,.2); border-radius:12px; background:rgba(34,197,94,.04); padding:12px 14px; margin-bottom:20px; display:flex; align-items:start; gap:10px;">
                  <.icon name="hero-shield-check" style="width:18px; height:18px; color:#22c55e; flex-shrink:0; margin-top:2px;" />
                  <div>
                    <p style="font-size:12px; font-weight:700; color:#166534; margin-bottom:2px;">Privacidad de grado clínico</p>
                    <p style="font-size:11px; color:#15803d;">
                      El número de WhatsApp se cifrará con una DEK única y nunca será visible en texto plano.
                    </p>
                  </div>
                </div>

                <div style="margin-bottom:16px;">
                  <label style="font-size:11px; font-weight:700; color:#475569; text-transform:uppercase; letter-spacing:0.04em; display:block; margin-bottom:6px;">
                    Alias del Paciente
                  </label>
                  <input
                    type="text"
                    name="patient[alias]"
                    value={@form[:alias].value || ""}
                    placeholder="Ej. Juan P."
                    style="width:100%; padding:10px 14px; border:1px solid #e2e8f0; border-radius:10px; font-size:14px; background:#fff; color:#334155;"
                  />
                  <%= for error <- Keyword.get_values(@form[:alias].errors, :message) do %>
                    <p style="font-size:11px; color:#ef4444; margin-top:4px;">{error}</p>
                  <% end %>
                </div>

                <div style="margin-bottom:20px;">
                  <label style="font-size:11px; font-weight:700; color:#475569; text-transform:uppercase; letter-spacing:0.04em; display:block; margin-bottom:6px;">
                    Número de WhatsApp
                  </label>
                  <input
                    type="text"
                    name="patient[whatsapp_number]"
                    value={@form[:whatsapp_number].value || ""}
                    placeholder="+56 9 1234 5678"
                    style="width:100%; padding:10px 14px; border:1px solid #e2e8f0; border-radius:10px; font-size:14px; background:#fff; color:#334155;"
                  />
                  <p style="font-size:10px; color:#94a3b8; margin-top:4px; text-transform:uppercase; letter-spacing:0.03em;">Formato E.164</p>
                  <%= for error <- Keyword.get_values(@form[:whatsapp_number].errors, :message) do %>
                    <p style="font-size:11px; color:#ef4444; margin-top:4px;">{error}</p>
                  <% end %>
                </div>

                <div style="display:flex; gap:10px;">
                  <button type="submit" class="btn btn-primary" style="flex:1; height:44px; border-radius:10px; font-weight:600;">
                    <.icon name="hero-lock-closed" class="mr-2" style="width:14px; height:14px;" /> Registrar Paciente
                  </button>
                  <.button type="button" phx-click={JS.patch(~p"/patients")} class="btn btn-ghost" style="height:44px; border-radius:10px;">
                    Cancelar
                  </.button>
                </div>
              </.simple_form>
            </div>
          </div>
        <% else %>
          <%!-- Empty state --%>
          <div style="border:2px dashed #e2e8f0; border-radius:16px; background:#fff; min-height:320px; display:flex; align-items:center; justify-content:center;">
            <div style="text-align:center; padding:40px;">
              <div style="width:56px; height:56px; border-radius:16px; background:#eef2ff; display:flex; align-items:center; justify-content:center; margin:0 auto 14px;">
                <.icon name="hero-user-circle" style="width:28px; height:28px; color:#818cf8;" />
              </div>
              <h2 style="font-size:15px; font-weight:700; color:#64748b; margin-bottom:4px;">Gestión de Pacientes</h2>
              <p style="font-size:13px; color:#94a3b8; margin-bottom:16px;">Seleccioná un paciente para ver su detalle en el dashboard.</p>
              <.button phx-click={JS.patch(~p"/patients/new")} class="btn btn-primary">
                <.icon name="hero-plus" class="mr-2" style="width:14px; height:14px;" /> Registrar Paciente
              </.button>
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp initials(alias) when is_binary(alias) do
    alias
    |> String.split()
    |> Enum.map(&String.first/1)
    |> Enum.take(2)
    |> Enum.join()
    |> String.upcase()
  end

  defp format_session_day(nil), do: "Sin horario"

  defp format_session_day(day) do
    days = ["", "Lun", "Mar", "Mié", "Jue", "Vie", "Sáb", "Dom"]
    Enum.at(days, day, "Sin día")
  end

  defp format_session_time(nil), do: ""

  defp format_session_time(time) do
    Calendar.strftime(time, "%H:%M")
  end
end
