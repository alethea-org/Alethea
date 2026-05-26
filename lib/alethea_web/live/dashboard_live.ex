defmodule AletheaWeb.DashboardLive do
  use AletheaWeb, :live_view

  alias Alethea.Accounts

  def mount(_params, %{"professional_id" => id}, socket) do
    professional = Accounts.get_professional!(id)
    {:ok, assign(socket, current_professional: professional)}
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <h1 class="text-2xl font-bold">Dashboard</h1>
      <p>Bienvenido, {@current_professional.full_name}.</p>
    </Layouts.app>
    """
  end
end
