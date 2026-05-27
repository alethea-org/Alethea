---
applyTo: "lib/alethea_web/live/**"
---

# Instrucciones: LiveViews del Dashboard (Web Adapter)

Estas instrucciones aplican a todos los archivos LiveView dentro de `lib/alethea_web/live/`.

## Regla de Layout (OBLIGATORIA)

**SIEMPRE** inicia los templates LiveView con:

```heex
<Layouts.app flash={@flash} current_scope={@current_scope}>
  <%!-- contenido aquí --%>
</Layouts.app>
```

Si obtienes errores de `current_scope`, verifica que la ruta esté en el `live_session`
correcto con `on_mount` que asigne `current_scope`.

## Diseño Light Mode (OBLIGATORIO)

La interfaz del psicólogo es estrictamente **Light Mode**. No uses fondos oscuros.

| Elemento             | Clase Tailwind                        |
|----------------------|---------------------------------------|
| Fondo de página      | `bg-white` o `bg-slate-50`            |
| Texto principal      | `text-slate-900`                      |
| Texto secundario     | `text-slate-500`                      |
| Bordes               | `border-slate-200`                    |
| Alertas críticas     | `bg-red-50 border-red-200`            |
| Botón primario       | `bg-indigo-600 text-white`            |

## LiveView Streams (OBLIGATORIO para listas)

**SIEMPRE** usa streams para listas de pacientes, mensajes o alertas:

```elixir
# En mount/3
socket = stream(socket, :patients, patients)

# En el template
<div id="patients-list" phx-update="stream">
  <div :for={{id, patient} <- @streams.patients} id={id}>
    ...
  </div>
</div>
```

**NUNCA** asignes listas completas en un assign regular para elementos renderizados en lista.

## PubSub para Tiempo Real

Suscríbete a alertas de crisis en `mount/3`:

```elixir
if connected?(socket) do
  Phoenix.PubSub.subscribe(Alethea.PubSub, "psychologist:alerts")
end
```

Maneja el mensaje en `handle_info/2` y actualiza el stream sin refresh.

## Descifrado On-Demand

El historial de chat del paciente se descifra **solo** al abrir `PatientLive.Show`.
**NUNCA** descifres el historial en la vista de lista (`PatientLive.Index`).

## IDs únicos en elementos clave

**SIEMPRE** asigna `id` únicos a formularios y elementos interactivos clave.
Esto es requerido para tests con `has_element?/2` y para `phx-hook`.

```heex
<.form for={@form} id="patient-form" phx-submit="save">
  <.input field={@form[:alias]} type="text" label="Alias" id="patient-alias-input" />
</.form>
```

## Condicionantes con `cond` (no `else if`)

```heex
<%!-- CORRECTO --%>
<%= cond do %>
  <% @score >= 0.3 -> %> <span class="text-green-600">Estable</span>
  <% @score >= -0.3 -> %> <span class="text-yellow-600">Neutro</span>
  <% true -> %> <span class="text-red-600">En Riesgo</span>
<% end %>
```
