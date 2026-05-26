defmodule AletheaWeb.PatientLive.Index do
  use AletheaWeb, :live_view

  alias Alethea.Accounts
  alias Alethea.Accounts.Patient

  @impl true
  def mount(_params, _session, socket) do
    # Usamos streams para el listado de pacientes
    patients = Accounts.list_patients(socket.assigns.current_professional.id)
    {:ok, stream(socket, :patients, patients)}
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
    patient_params = Map.put(patient_params, "professional_id", socket.assigns.current_professional.id)

    case Accounts.create_patient(patient_params, socket.assigns.professional_kek) do
      {:ok, patient} ->
        {:noreply,
         socket
         |> put_flash(:info, "Paciente registrado exitosamente.")
         |> stream_insert(:patients, patient)
         |> push_patch(to: ~p"/patients")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :changeset, changeset)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.header>
      Listado de Pacientes
      <:actions>
        <.link patch={~p"/patients/new"}>
          <.button>Nuevo Paciente</.button>
        </.link>
      </:actions>
    </.header>

    <.table
      id="patients"
      rows={@streams.patients}
      row_click={fn {_id, patient} -> JS.navigate(~p"/dashboard?patient_id=#{patient.id}") end}
    >
      <:col :let={{_id, patient}} label="Alias"><%= patient.alias %></:col>
      <:col :let={{_id, patient}} label="Estado">
        <.badge color={if patient.status == "active", do: :green, else: :gray}>
          <%= patient.status %>
        </.badge>
      </:col>
      <:action :let={{_id, patient}}>
        <.link
          phx-click={JS.push("delete", value: %{id: patient.id}) |> hide("##{patient.id}")}
          data-confirm="¿Estás seguro?"
        >
          Borrar
        </.link>
      </:action>
    </.table>

    <.modal :if={@live_action in [:new]} id="patient-modal" show on_cancel={JS.patch(~p"/patients")}>
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
    """
  end
end
