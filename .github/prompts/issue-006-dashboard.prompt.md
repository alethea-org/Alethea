---
description: "Issue 006 — Dashboard del psicólogo: alertas críticas, Snapshots, semáforo de ánimo (Light Mode)"
---

# Issue 006: Dashboard de Riesgo y Snapshots (Light Mode)

Implementa el "Centro de Control" del psicólogo: interfaz Light Mode con alertas
de crisis en tiempo real, Snapshots clínicos de 4 líneas y semáforo de estado de ánimo.

## Contexto

- **Bloqueado por**: Issues 004 y 005 (Snapshots y alertas deben existir)
- **User Stories**: 2 (centro de control de riesgo) y 3 (Snapshot pre-sesión)
- **Módulos clave**: `AletheaWeb.DashboardLive.Index`, `AletheaWeb.PatientLive.Show`

## Tareas a Implementar

### 1. Light Mode Global

En `assets/css/app.css` o el layout base, asegurar fondo claro:

```css
body {
  @apply bg-slate-50 text-slate-900;
}
```

En `lib/alethea_web/components/layouts/app.html.heex`:
- Remover cualquier clase de fondo oscuro (`bg-gray-900`, `bg-zinc-900`, etc.)
- Usar `bg-white` o `bg-slate-50` como fondo principal

### 2. `DashboardLive.Index` con Alertas Críticas

```elixir
defmodule AletheaWeb.DashboardLive.Index do
  use AletheaWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Alethea.PubSub, "psychologist:alerts")
    end

    psych_id = socket.assigns.current_scope.psychologist_id

    socket =
      socket
      |> stream(:critical_alerts, Alethea.Accounts.list_urgent_patients(psych_id))
      |> stream(:patients, Alethea.Accounts.list_patients(psych_id))

    {:ok, socket}
  end

  @impl true
  def handle_info({:crisis_detected, %{patient_id: pid}}, socket) do
    patient = Alethea.Accounts.get_patient!(pid)
    {:noreply, stream_insert(socket, :critical_alerts, patient, at: 0)}
  end
end
```

### 3. Template del Dashboard (Light Mode)

```heex
<Layouts.app flash={@flash} current_scope={@current_scope}>
  <%!-- Sección de Alertas Críticas --%>
  <section id="critical-alerts" class="mb-6">
    <h2 class="text-lg font-semibold text-red-700 mb-3">🚨 Alertas Críticas</h2>
    <div id="alerts-list" phx-update="stream" class="space-y-2">
      <div :for={{id, patient} <- @streams.critical_alerts} id={id}
           class="flex items-center gap-3 p-3 bg-red-50 border border-red-200 rounded-lg">
        <span class="font-medium text-red-900">{patient.alias}</span>
        <span class="text-sm text-red-600">Intervención urgente requerida</span>
        <.link navigate={~p"/patients/#{patient.id}"} class="ml-auto text-sm text-red-700 underline">
          Ver detalle
        </.link>
      </div>
    </div>
  </section>

  <%!-- Lista de Pacientes --%>
  <section id="patients-section">
    <h2 class="text-lg font-semibold text-slate-800 mb-3">Mis Pacientes</h2>
    <div id="patients-list" phx-update="stream" class="divide-y divide-slate-200">
      <div :for={{id, patient} <- @streams.patients} id={id}
           class="flex items-center gap-4 py-3">
        <span class="font-medium text-slate-900">{patient.alias}</span>
        <.mood_indicator score={patient.latest_sentiment_score || 0.0} />
        <.link navigate={~p"/patients/#{patient.id}"} class="ml-auto text-sm text-indigo-600">
          Ver Snapshot →
        </.link>
      </div>
    </div>
  </section>
</Layouts.app>
```

### 4. Componente `MoodIndicator`

Crear `lib/alethea_web/components/mood_indicator.ex` con semáforo verde/amarillo/rojo.

### 5. `PatientLive.Show` con Snapshot y Historial Descifrado

```elixir
def mount(%{"id" => patient_id}, _session, socket) do
  patient  = Alethea.Accounts.get_patient!(patient_id)
  snapshot = Alethea.Clinical.get_latest_snapshot(patient_id)
  # Descifrado on-demand: SOLO aquí, nunca en la lista
  messages = Alethea.Clinical.decrypt_message_history(patient_id)

  socket =
    socket
    |> assign(:patient, patient)
    |> assign(:snapshot, snapshot)
    |> stream(:messages, messages)

  {:ok, socket}
end
```

## Tests de LiveView

```elixir
test "dashboard muestra sección de alertas críticas", %{conn: conn} do
  {:ok, view, _html} = live(conn, ~p"/dashboard")
  assert has_element?(view, "#critical-alerts")
end

test "nueva alerta aparece en tiempo real via PubSub", %{conn: conn} do
  {:ok, view, _html} = live(conn, ~p"/dashboard")
  Phoenix.PubSub.broadcast(Alethea.PubSub, "psychologist:alerts",
    {:crisis_detected, %{patient_id: patient.id}})
  assert has_element?(view, "#alerts-list [id*='#{patient.id}']")
end

test "snapshot de 4 líneas visible en detalle del paciente", %{conn: conn} do
  {:ok, view, _html} = live(conn, ~p"/patients/#{patient.id}")
  assert has_element?(view, "#snapshot-card")
end
```

## Checklist

- [ ] Light Mode global: sin colores oscuros en ningún elemento
- [ ] Alertas críticas en sección prominente al inicio del dashboard
- [ ] Alertas aparecen en tiempo real via PubSub sin refresh de página
- [ ] Semáforo de estado de ánimo en verde/amarillo/rojo
- [ ] Snapshot de 4 líneas visible en `PatientLive.Show`
- [ ] Historial descifrado SOLO en la vista de detalle (no en lista)
- [ ] LiveView Streams para ambas listas (pacientes y alertas)
- [ ] Tests de LiveView con `has_element?/2` e IDs únicos
- [ ] `mix precommit` pasa limpio
