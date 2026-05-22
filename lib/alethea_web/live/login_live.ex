defmodule AletheaWeb.LoginLive do
  use AletheaWeb, :live_view

  def mount(_params, _session, socket) do
    form = to_form(%{"email" => "", "password" => ""}, as: :professional)
    {:ok, assign(socket, form: form), temporary_assigns: [form: nil]}
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="mx-auto max-w-sm">
        <h1 class="text-2xl font-bold mb-6">Iniciar sesión</h1>

        <.form for={@form} action={~p"/login"} method="post">
          <.input field={@form[:email]} type="email" label="Correo electrónico" required />
          <.input field={@form[:password]} type="password" label="Contraseña" required />
          <.button type="submit" class="w-full mt-4">Ingresar</.button>
        </.form>
      </div>
    </Layouts.app>
    """
  end
end
