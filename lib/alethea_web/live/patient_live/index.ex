defmodule AletheaWeb.PatientLive.Index do
  use AletheaWeb, :live_view

  alias Alethea.Accounts
  alias Alethea.Accounts.Patient

  @impl true
  def mount(_params, _session, socket) do
    patients = Accounts.list_patients(socket.assigns.current_professional.id)

    socket =
      socket
      |> assign(:patients_empty?, Enum.empty?(patients))
      |> stream(:patients, patients)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Pacientes")
    |> assign(:patient, nil)
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:page_title, "Registrar Paciente")
    |> assign(:patient, %Patient{})
  end

  @impl true
  def handle_event("delete", %{"id" => _id}, socket) do
    # Lógica de borrado (opcional para esta issue)
    {:noreply, socket}
  end

  @impl true
  def handle_event("save_patient", %{"patient" => patient_params}, socket) do
    # Añadir el ID del profesional al params
    patient_params =
      Map.put(patient_params, "professional_id", socket.assigns.current_professional.id)

    case Accounts.create_patient(patient_params, socket.assigns.professional_kek) do
      {:ok, patient} ->
        {:noreply,
         socket
         |> put_flash(:info, "Paciente registrado exitosamente.")
         |> assign(:patients_empty?, false)
         |> stream_insert(:patients, patient)
         |> push_patch(to: ~p"/patients")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :changeset, changeset)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <.header>
        Mis Pacientes
        <:subtitle>Gestión de bóvedas y llaves de cifrado.</:subtitle>
        <:actions>
          <.button phx-click={JS.patch(~p"/patients/new")} class="btn btn-primary">
            <.icon name="hero-user-plus" class="mr-2" /> Nuevo Paciente
          </.button>
        </:actions>
      </.header>

      <div
        :if={@patients_empty?}
        class="hero bg-base-100 rounded-box border border-dashed border-base-300 py-12"
      >
        <div class="hero-content text-center">
          <div class="max-w-md">
            <div class="bg-base-200 w-16 h-16 rounded-full flex items-center justify-center mx-auto mb-4 text-base-content/30">
              <.icon name="hero-users" class="size-8" />
            </div>
            <h2 class="text-xl font-bold">Sin pacientes registrados</h2>
            <p class="py-4 text-base-content/60">
              Aún no tienes pacientes en tu lista. Registra uno nuevo para comenzar el seguimiento clínico con cifrado soberano.
            </p>
            <.button phx-click={JS.patch(~p"/patients/new")} class="btn btn-primary btn-sm">
              Registrar primer paciente
            </.button>
          </div>
        </div>
      </div>

      <div
        :if={!@patients_empty?}
        class="card bg-base-100 shadow-sm border border-base-300 overflow-hidden"
      >
        <.table
          id="patients"
          rows={@streams.patients}
          row_click={fn {_id, patient} -> JS.navigate(~p"/dashboard?patient_id=#{patient.id}") end}
        >
          <:col :let={{_id, patient}} label="Alias">
            <div class="font-bold">{patient.alias}</div>
            <div class="text-xs opacity-50 uppercase tracking-tighter">
              ID: {String.slice(patient.id, 0, 8)}
            </div>
          </:col>
          <:col :let={{_id, patient}} label="Estado">
            <.badge color={if patient.status == "active", do: :green, else: :gray}>
              {String.capitalize(patient.status)}
            </.badge>
          </:col>
          <:col :let={{_id, patient}} label="Alertas">
            <div :if={patient.urgent_intervention} class="badge badge-error gap-2 text-xs font-bold">
              <div class="w-2 h-2 rounded-full bg-error-content animate-pulse"></div>
              URGENTE
            </div>
            <span :if={!patient.urgent_intervention} class="opacity-30">-</span>
          </:col>
          <:action :let={{_id, patient}}>
            <div class="dropdown dropdown-end">
              <div tabindex="0" role="button" class="btn btn-ghost btn-xs">
                <.icon name="hero-ellipsis-horizontal" />
              </div>
              <ul
                tabindex="0"
                class="dropdown-content menu p-2 shadow bg-base-100 rounded-box w-52 z-10"
              >
                <li>
                  <.link navigate={~p"/dashboard?patient_id=#{patient.id}"}>
                    <.icon name="hero-presentation-chart-line" /> Ver Dashboard
                  </.link>
                </li>
                <li>
                  <.link
                    phx-click={JS.push("delete", value: %{id: patient.id}) |> hide("##{patient.id}")}
                    data-confirm="¿Estás seguro de que quieres borrar este paciente? Esta acción es irreversible."
                    class="text-error"
                  >
                    <.icon name="hero-trash" /> Borrar Paciente
                  </.link>
                </li>
              </ul>
            </div>
          </:action>
        </.table>
      </div>

      <.modal
        :if={@live_action in [:new]}
        id="patient-modal"
        show
        on_cancel={JS.patch(~p"/patients")}
      >
        <.live_component
          module={AletheaWeb.PatientLive.FormComponent}
          id={@patient.id || :new}
          title={@page_title}
          action={@live_action}
          patient={@patient}
          professional_kek={@professional_kek}
          current_professional={@current_professional}
          patch={~p"/patients"}
        />
      </.modal>
    </div>
    """
  end
end
