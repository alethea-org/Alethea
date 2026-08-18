defmodule AletheaWeb.DashboardLive.Components.NotificationCenter do
  @moduledoc """
  The dashboard's notification bell and its dropdown panel.

  Severity is carried by a dot in one of the documented semantic
  roles (`status-dot--risk` / `--warn` / `--info`) rather than by a
  bespoke hex, so a new alert level is a role decision, not a color
  decision.
  """
  use AletheaWeb, :live_component

  @page_size 10
  @max_notifications 100

  def mount(socket) do
    {:ok,
     socket
     |> assign(:notifications, [])
     |> assign(:page, 1)
     |> assign(:show_panel, false)}
  end

  def update(assigns, socket) do
    socket = assign(socket, :id, assigns.id)

    case Map.get(assigns, :new_notification) do
      nil ->
        {:ok, socket}

      notif ->
        notifications =
          [notif | socket.assigns.notifications]
          |> Enum.take(@max_notifications)

        {:ok, assign(socket, :notifications, notifications)}
    end
  end

  def handle_event("toggle_panel", _, socket) do
    {:noreply, update(socket, :show_panel, &(!&1))}
  end

  def handle_event("close_panel", _, socket) do
    {:noreply, assign(socket, :show_panel, false)}
  end

  def handle_event("mark_read", %{"id" => id}, socket) do
    id = String.to_integer(id)

    notifications =
      Enum.map(socket.assigns.notifications, fn n ->
        if n.id == id, do: %{n | read: true}, else: n
      end)

    {:noreply, assign(socket, :notifications, notifications)}
  end

  def handle_event("mark_all_read", _, socket) do
    notifications = Enum.map(socket.assigns.notifications, &%{&1 | read: true})
    {:noreply, assign(socket, :notifications, notifications)}
  end

  def handle_event("prev_page", _, socket) do
    {:noreply, update(socket, :page, &max(&1 - 1, 1))}
  end

  def handle_event("next_page", _, socket) do
    pages = total_pages(socket.assigns.notifications)
    {:noreply, update(socket, :page, &min(&1 + 1, pages))}
  end

  def render(assigns) do
    unread = Enum.count(assigns.notifications, &(!&1.read))
    pages = total_pages(assigns.notifications)
    page = min(assigns.page, pages)
    page_items = Enum.slice(assigns.notifications, (page - 1) * @page_size, @page_size)

    assigns =
      assigns
      |> assign(:unread_count, unread)
      |> assign(:total_pages, pages)
      |> assign(:current_page, page)
      |> assign(:page_items, page_items)

    ~H"""
    <div class="notif">
      <button
        type="button"
        phx-click="toggle_panel"
        phx-target={@myself}
        class={["notif__bell", @show_panel && "notif__bell--on"]}
        aria-label="Notificaciones"
        aria-expanded={to_string(@show_panel)}
      >
        <.icon name="hero-bell" class="size-5" />
        <span :if={@unread_count > 0} class="notif__count">{min(@unread_count, 99)}</span>
      </button>
      <div :if={@show_panel} id={"#{@id}-panel"} class="notif__panel">
        <div class="notif__head">
          <span class="pt-eyebrow">Notificaciones</span>
          <div style="display:flex; align-items:center; gap:8px;">
            <button
              :if={@unread_count > 0}
              type="button"
              phx-click="mark_all_read"
              phx-target={@myself}
              class="link-button"
            >
              Leer todo
            </button>
            <button
              type="button"
              phx-click="close_panel"
              phx-target={@myself}
              class="notif__icon-btn"
              aria-label="Cerrar notificaciones"
            >
              <.icon name="hero-x-mark" class="size-4" />
            </button>
          </div>
        </div>

        <div :if={@page_items == []} class="empty-state" style="border:none; padding:32px 16px;">
          <.icon name="hero-bell-slash" class="empty-state__icon" />
          <p class="empty-state__text" style="margin-bottom:0;">Sin notificaciones</p>
        </div>

        <div :if={@page_items != []}>
          <div
            :for={notif <- @page_items}
            id={"notif-#{notif.id}"}
            class={["notif__item", !notif.read && "notif__item--unread"]}
          >
            <span
              class={"status-dot " <> severity_dot(notif.severity)}
              style="margin-top:6px;"
            >
            </span>
            <div style="flex:1; min-width:0;">
              <p class="notif__msg">{notif.message}</p>

              <p class="notif__time">{relative_time(notif.inserted_at)}</p>
            </div>

            <button
              :if={!notif.read}
              type="button"
              phx-click="mark_read"
              phx-value-id={notif.id}
              phx-target={@myself}
              title="Marcar como leído"
              aria-label="Marcar como leído"
              class="notif__icon-btn"
            >
              <.icon name="hero-check" class="size-4" />
            </button>
          </div>
        </div>

        <div :if={@total_pages > 1} class="notif__foot">
          <button
            type="button"
            phx-click="prev_page"
            phx-target={@myself}
            disabled={@current_page == 1}
            class="link-button"
            style={@current_page == 1 && "opacity:.4; cursor:default;"}
          >
            Anterior
          </button>
          <span style="font-variant-numeric:tabular-nums;">{@current_page} / {@total_pages}</span>
          <button
            type="button"
            phx-click="next_page"
            phx-target={@myself}
            disabled={@current_page == @total_pages}
            class="link-button"
            style={@current_page == @total_pages && "opacity:.4; cursor:default;"}
          >
            Siguiente
          </button>
        </div>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Public helper — called by DashboardLive.handle_info to build notification maps
  # ---------------------------------------------------------------------------

  def build_notification(type, attrs) do
    %{
      id: System.unique_integer([:positive, :monotonic]),
      type: type,
      severity: notification_severity(type, attrs),
      message: notification_message(type, attrs),
      patient_id: Map.get(attrs, :patient_id),
      read: false,
      inserted_at: DateTime.utc_now()
    }
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp total_pages([]), do: 1
  defp total_pages(list), do: max(div(length(list) - 1, @page_size) + 1, 1)

  defp notification_severity(:crisis_detected, %{level: level})
       when level in ["critical", "high"] do
    :critical
  end

  defp notification_severity(:crisis_detected, _), do: :warning
  defp notification_severity(:patient_created, _), do: :info
  defp notification_severity(_, _), do: :info

  defp notification_message(:crisis_detected, %{patient_alias: alias, level: level})
       when is_binary(alias) do
    "Crisis detectada · #{alias} (nivel: #{level})"
  end

  defp notification_message(:crisis_detected, %{level: level}) do
    "Crisis detectada (nivel: #{level})"
  end

  defp notification_message(:patient_created, %{patient_alias: alias})
       when is_binary(alias) do
    "Nuevo paciente registrado: #{alias}"
  end

  defp notification_message(:patient_created, _), do: "Nuevo paciente registrado"
  defp notification_message(_, _), do: "Nueva notificación"

  defp severity_dot(:critical), do: "status-dot--risk"
  defp severity_dot(:warning), do: "status-dot--warn"
  defp severity_dot(:info), do: "status-dot--info"

  defp relative_time(dt) do
    diff = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      diff < 60 -> "ahora"
      diff < 3600 -> "#{div(diff, 60)}m"
      diff < 86400 -> "#{div(diff, 3600)}h"
      true -> "#{div(diff, 86400)}d"
    end
  end
end
