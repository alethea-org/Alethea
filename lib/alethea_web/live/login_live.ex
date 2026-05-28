defmodule AletheaWeb.LoginLive do
  use AletheaWeb, :live_view

  def mount(_params, _session, socket) do
    form = to_form(%{"email" => "", "password" => ""}, as: :professional)
    {:ok, assign(socket, form: form), temporary_assigns: [form: nil]}
  end

  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-sm">
      <h1 class="text-3xl font-bold mb-6 text-center">Iniciar sesión</h1>

      <.simple_form for={@form} action={~p"/login"} method="post">
        <.input field={@form[:email]} type="email" label="Correo electrónico" required />
        <.input field={@form[:password]} type="password" label="Contraseña" required />
        <:actions>
          <.button type="submit" class="w-full mt-4">Ingresar</.button>
        </:actions>
      </.simple_form>
    </div>
    """
  end
end
