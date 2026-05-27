defmodule AletheaWeb.PatientLive.FormComponent do
  use AletheaWeb, :live_component

  alias Alethea.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.header>
        {@title}
      </.header>

      <.simple_form
        for={@form}
        id="patient-form"
        phx-target={@myself}
        phx-change="validate"
        phx-submit="save"
      >
        <.input field={@form[:alias]} type="text" label="Alias" placeholder="Ej. Juan P." />
        <.input
          field={@form[:whatsapp_number]}
          type="text"
          label="Número de WhatsApp (E.164)"
          placeholder="Ej. +56912345678"
        />

        <:actions>
          <.button phx-disable-with="Guardando...">Registrar Paciente</.button>
        </:actions>
      </.simple_form>
    </div>
    """
  end

  @impl true
  def update(%{patient: patient} = assigns, socket) do
    changeset = Accounts.Patient.changeset(patient, %{})

    {:ok,
     socket
     |> assign(assigns)
     |> assign_form(changeset)}
  end

  @impl true
  def handle_event("validate", %{"patient" => patient_params}, socket) do
    changeset =
      socket.assigns.patient
      |> Accounts.Patient.changeset(patient_params)
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("save", %{"patient" => patient_params}, socket) do
    save_patient(socket, socket.assigns.action, patient_params)
  end

  defp save_patient(socket, :new, patient_params) do
    # Añadimos el professional_id
    patient_params =
      Map.put(patient_params, "professional_id", socket.assigns.current_professional.id)

    case Accounts.create_patient(patient_params, socket.assigns.professional_kek) do
      {:ok, _patient} ->
        {:noreply,
         socket
         |> put_flash(:info, "Paciente registrado exitosamente.")
         |> push_patch(to: socket.assigns.patch)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Error al cifrar datos: #{inspect(reason)}")}
    end
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    assign(socket, :form, to_form(changeset))
  end
end
