defmodule AletheaWeb.DashboardLive.Components.NotificationCenter do
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
    <div style="position:relative;">
      <%!-- Bell button --%>
      <button
        phx-click="toggle_panel"
        phx-target={@myself}
        style={
          "position:relative; display:flex; align-items:center; justify-content:center; width:36px; height:36px; border-radius:10px; border:1px solid #e2e8f0; background:#fff; cursor:pointer; transition:background .15s;" <>
          if(@show_panel, do: "background:#eef2ff; border-color:#818cf8;", else: "")
        }
        aria-label="Notificaciones"
      >
        <.icon name="hero-bell" style="width:20px; height:20px; color:#4b5563;" />
        <span
          :if={@unread_count > 0}
          style="position:absolute; top:-4px; right:-4px; min-width:16px; height:16px; border-radius:8px; background:#ef4444; color:#fff; font-size:9px; font-weight:700; display:flex; align-items:center; justify-content:center; padding:0 3px; border:1.5px solid #fff;"
        >
          {min(@unread_count, 99)}
        </span>
      </button>
      <%!-- Dropdown panel --%>
      <div
        :if={@show_panel}
        id={"#{@id}-panel"}
        style="position:absolute; right:0; top:calc(100% + 6px); z-index:50; width:320px; border:1px solid #e2e8f0; border-radius:16px; background:#fff; box-shadow:0 8px 24px rgba(0,0,0,.10); overflow:hidden;"
      >
        <%!-- Panel header --%>
        <div style="display:flex; align-items:center; justify-content:space-between; padding:10px 14px; border-bottom:1px solid #f1f5f9; background:#fafbfc;">
          <div style="display:flex; align-items:center; gap:6px;">
            <.icon name="hero-bell" style="width:13px; height:13px; color:#6366f1;" />
            <span style="font-size:11px; font-weight:700; color:#1e293b;">Notificaciones</span>
            <span
              :if={@unread_count > 0}
              class="badge badge-error"
              style="font-size:9px; font-weight:700; min-width:18px;"
            >
              {@unread_count}
            </span>
          </div>

          <div style="display:flex; align-items:center; gap:6px;">
            <button
              :if={@unread_count > 0}
              phx-click="mark_all_read"
              phx-target={@myself}
              style="font-size:10px; color:#6366f1; font-weight:600; background:none; border:none; cursor:pointer; padding:2px 6px; border-radius:6px;"
            >
              Leer todo
            </button>
            <button
              phx-click="close_panel"
              phx-target={@myself}
              style="display:flex; align-items:center; justify-content:center; width:22px; height:22px; border-radius:6px; border:none; background:none; cursor:pointer; color:#94a3b8;"
            >
              <.icon name="hero-x-mark" style="width:13px; height:13px;" />
            </button>
          </div>
        </div>
        <%!-- Empty state --%>
        <div :if={@page_items == []} style="padding:32px 16px; text-align:center;">
          <.icon
            name="hero-bell-slash"
            style="width:24px; height:24px; color:#cbd5e1; margin:0 auto 8px; display:block;"
          />
          <p style="font-size:12px; color:#94a3b8;">Sin notificaciones</p>
        </div>
        <%!-- Notification list --%>
        <div :if={@page_items != []}>
          <%= for notif <- @page_items do %>
            <div
              id={"notif-#{notif.id}"}
              style={
                "display:flex; align-items:flex-start; gap:10px; padding:10px 14px; border-bottom:1px solid #f8fafc; transition:background .12s;" <>
                if(notif.read, do: "", else: "background:rgba(99,102,241,.03);")
              }
            >
              <%!-- Severity dot --%>
              <div style="flex-shrink:0; padding-top:2px;">
                <span style={"width:8px; height:8px; border-radius:50%; display:block; background:#{severity_color(notif.severity)};"}>
                </span>
              </div>
              <%!-- Content --%>
              <div style="flex:1; min-width:0;">
                <p style={"font-size:12px; line-height:1.4; color:#334155; " <> if(notif.read, do: "", else: "font-weight:500;")}>
                  {notif.message}
                </p>

                <p style="font-size:10px; color:#94a3b8; margin-top:2px;">
                  {relative_time(notif.inserted_at)}
                </p>
              </div>
              <%!-- Mark read --%>
              <button
                :if={!notif.read}
                phx-click="mark_read"
                phx-value-id={notif.id}
                phx-target={@myself}
                title="Marcar como leído"
                style="flex-shrink:0; padding-top:2px; background:none; border:none; cursor:pointer; color:#94a3b8; display:flex; align-items:center;"
              >
                <.icon name="hero-check" style="width:13px; height:13px;" />
              </button>
            </div>
          <% end %>
        </div>
        <%!-- Pagination --%>
        <div
          :if={@total_pages > 1}
          style="display:flex; align-items:center; justify-content:space-between; padding:8px 14px; border-top:1px solid #f1f5f9; background:#fafbfc;"
        >
          <button
            phx-click="prev_page"
            phx-target={@myself}
            disabled={@current_page == 1}
            style={"display:flex; align-items:center; gap:3px; font-size:10px; color:#64748b; background:none; border:none; cursor:pointer; " <> if(@current_page == 1, do: "opacity:0.4; cursor:default;", else: "")}
          >
            <.icon name="hero-chevron-left" style="width:12px; height:12px;" /> Anterior
          </button>
          <span style="font-size:10px; color:#94a3b8; font-variant-numeric:tabular-nums;">
            {@current_page} / {@total_pages}
          </span>
          <button
            phx-click="next_page"
            phx-target={@myself}
            disabled={@current_page == @total_pages}
            style={"display:flex; align-items:center; gap:3px; font-size:10px; color:#64748b; background:none; border:none; cursor:pointer; " <> if(@current_page == @total_pages, do: "opacity:0.4; cursor:default;", else: "")}
          >
            Siguiente <.icon name="hero-chevron-right" style="width:12px; height:12px;" />
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

  defp severity_color(:critical), do: "#ef4444"
  defp severity_color(:warning), do: "#f59e0b"
  defp severity_color(:info), do: "#3b82f6"

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
