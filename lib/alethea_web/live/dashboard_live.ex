defmodule AletheaWeb.DashboardLive do
  use AletheaWeb, :live_view

  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <.header>
        Dashboard
        <:subtitle>Bienvenido, {@current_professional.full_name}.</:subtitle>
      </.header>

      <div class="grid grid-cols-1 md:grid-cols-3 gap-4">
        <div class="stats shadow bg-base-100">
          <div class="stat">
            <div class="stat-title text-xs uppercase tracking-widest font-bold">Pacientes</div>
            <div class="stat-value text-primary">--</div>
            <div class="stat-desc">Activos esta semana</div>
          </div>
        </div>

        <div class="stats shadow bg-base-100">
          <div class="stat">
            <div class="stat-title text-xs uppercase tracking-widest font-bold">Alertas</div>
            <div class="stat-value text-error">0</div>
            <div class="stat-desc">Intervenciones urgentes</div>
          </div>
        </div>

        <div class="stats shadow bg-base-100">
          <div class="stat">
            <div class="stat-title text-xs uppercase tracking-widest font-bold">Sesiones</div>
            <div class="stat-value text-secondary">--</div>
            <div class="stat-desc">Procesadas hoy</div>
          </div>
        </div>
      </div>

      <div class="card bg-base-100 shadow-sm border border-base-300">
        <div class="card-body">
          <h2 class="card-title">Resumen de Actividad</h2>
          <p class="text-base-content/60 italic">Próximamente: Visualización de grafos de conducta y tendencias clínicas.</p>
          <div class="card-actions justify-end">
            <.button navigate={~p"/patients"} class="btn btn-sm">Ver Pacientes</.button>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
