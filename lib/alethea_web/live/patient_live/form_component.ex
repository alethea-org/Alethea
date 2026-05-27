defmodule AletheaWeb.PatientLive.FormComponent do
  use AletheaWeb, :live_component

  alias Alethea.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.header>
        {@title}
        <:subtitle>Ingresa los datos básicos para crear la boveda cifrada.</:subtitle>
      </.header>

      <.simple_form
        for={@form}
        id="patient-form"
        phx-target={@myself}
        phx-change="validate"
        phx-submit="save"
        class="mt-8"
      >
        <div class="card bg-base-200 p-4 border border-base-300 mb-6">
          <div class="flex items-start gap-3">
            <.icon name="hero-shield-check" class="size-6 text-primary shrink-0 mt-1" />
            <div>
              <p class="text-sm font-bold">Privacidad de grado clínico</p>
              <p class="text-xs text-base-content/60">
                El número de WhatsApp se cifrará con una DEK única y nunca será visible en texto plano en la base de datos.
              </p>
            </div>
          </div>
        </div>

        <.input field={@form[:alias]} type="text" label="Alias del paciente" placeholder="Ej. Juan P." />

        <div class="space-y-1">
          <.input
            field={@form[:whatsapp_number]}
            type="text"
            label="Número de WhatsApp"
            placeholder="Ej. +56 9 1234 5678"
          />
          <p class="text-[10px] uppercase tracking-widest font-bold text-base-content/40 px-1">
            Formato internacional recomendado (E.164)
          </p>
        </div>

        <:actions>
          <.button phx-disable-with="Cifrando y guardando..." class="btn btn-primary w-full mt-4">
            <.icon name="hero-lock-closed" class="mr-2" /> Registrar Paciente
          </.button>
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
