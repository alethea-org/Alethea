defmodule AletheaWeb.ProfessionalRegistrationLive do
  use AletheaWeb, :live_view

  alias Alethea.Accounts
  alias Alethea.Accounts.Professional

  def mount(_params, _session, socket) do
    changeset = Professional.changeset(%Professional{}, %{})

    socket =
      socket
      |> assign(page_title: "Registrarse")
      |> assign(check_errors: false)
      |> assign_form(changeset)

    {:ok, socket, temporary_assigns: [form: nil]}
  end

  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-sm">
      <.header class="text-center">
        Registrar cuenta profesional
        <:subtitle>
          ¿Ya tenés cuenta?
          <.link navigate={~p"/login"} class="font-semibold text-primary hover:underline">
            Iniciá sesión
          </.link>
          acá.
        </:subtitle>
      </.header>

      <.simple_form
        for={@form}
        id="registration_form"
        phx-submit="save"
        phx-change="validate"
        phx-trigger-action={@trigger_submit}
        action={~p"/login?_action=registered"}
        method="post"
      >
        <.error :if={@check_errors}>
          Oops, algo salió mal! Por favor revisá los errores abajo.
        </.error>

        <.input field={@form[:email]} type="email" label="Correo electrónico" required />
        <.input field={@form[:full_name]} type="text" label="Nombre completo" required />
        <.input field={@form[:password]} type="password" label="Contraseña" required />
        <p class="text-xs text-base-content/60 px-1">
          La contraseña debe tener al menos 12 caracteres.
        </p>

        <:actions>
          <.button phx-disable-with="Creando cuenta..." class="w-full">Crear cuenta</.button>
        </:actions>
      </.simple_form>
    </div>
    """
  end

  def handle_event("validate", %{"professional" => professional_params}, socket) do
    changeset = Professional.changeset(%Professional{}, professional_params)
    {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
  end

  def handle_event("save", %{"professional" => professional_params}, socket) do
    case Accounts.create_professional(professional_params) do
      {:ok, _professional} ->
        {:noreply,
         socket
         |> put_flash(:info, "Cuenta creada con éxito. Ahora podés iniciar sesión.")
         |> assign(trigger_submit: true)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, socket |> assign_form(changeset) |> assign(check_errors: true)}
    end
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    form = to_form(changeset, as: "professional")

    if changeset.valid? do
      assign(socket, form: form, check_errors: false, trigger_submit: false)
    else
      assign(socket, form: form, trigger_submit: false)
    end
  end
end
