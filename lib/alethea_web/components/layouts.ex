defmodule AletheaWeb.Layouts do
  @moduledoc """
  Application layouts.

  - `root.html.heex` — HTML document shell (fonts, CDN links, body)
  - `auth.html.heex` — Minimal centered layout for login/register
  - `app.html.heex` — Sidebar + topbar shell for authenticated pages

  All positioning uses CSS classes defined in `app.css`.
  Component styling uses FlyonUI semantic classes from CDN.
  """
  use AletheaWeb, :html

  embed_templates("layouts/*")

  # ── App shell ──────────────────────────────────────────────────────
  # Full sidebar + topbar layout for authenticated pages (dashboard, patients, etc.)

  attr(:current_professional, :any, default: nil)
  attr(:flash, :map, required: true)
  slot(:inner_block)

  def app(assigns) do
    ~H"""
    <div id="app-shell" class="app-shell">
      <%!-- ═══ SIDEBAR ═══ --%>
      <aside id="app-sidebar" class="app-sidebar" role="navigation" aria-label="Main navigation">
        <div class="app-sidebar__header">
          <div class="app-sidebar__logo"><img src={~p"/images/logo.svg"} alt="" width="18" /></div>
          
          <div>
            <div class="app-sidebar__brand-name">Alethea</div>
            
            <div class="app-sidebar__brand-sub">Centro de Control</div>
          </div>
        </div>
        
        <nav class="app-sidebar__nav">
          <p class="app-sidebar__section-title">Principal</p>
          
          <%= for item <- nav_items() do %>
            <.link
              navigate={item.path}
              id={"nav-#{item.id}"}
              class={[
                "app-sidebar__link",
                active?(assigns, item.view) && "app-sidebar__link--active"
              ]}
            >
              <.icon name={item.icon} class="size-4" /> <span>{item.label}</span>
            </.link>
          <% end %>
        </nav>
        
        <div class="app-sidebar__footer">
          <div class="app-sidebar__user">
            <div class="app-sidebar__avatar">{initials(assigns)}</div>
            
            <div style="min-width:0; flex:1; overflow:hidden;">
              <div class="app-sidebar__user-name">{name(assigns)}</div>
              
              <div class="app-sidebar__user-role">Psicólogo Clínico</div>
            </div>
            
            <.link
              href={~p"/logout"}
              method="delete"
              class="app-sidebar__logout"
              title="Cerrar sesión"
            >
              <.icon name="hero-arrow-left-on-rectangle" class="size-4" />
            </.link>
          </div>
        </div>
      </aside>
       <%!-- Mobile overlay — closes sidebar --%>
      <div
        id="sidebar-overlay"
        class="sidebar-overlay"
        phx-click={JS.remove_class("app-shell--sidebar-open", to: "#app-shell")}
      >
      </div>
       <%!-- ═══ MAIN ═══ --%>
      <div class="app-main">
        <%!-- Topbar --%>
        <header class="app-topbar">
          <button
            type="button"
            class="sidebar-hamburger"
            aria-label="Toggle sidebar"
            phx-click={JS.toggle_class("app-shell--sidebar-open", to: "#app-shell")}
          >
            <.icon name="hero-bars-3" class="size-5" />
          </button>
          <div class="app-topbar__spacer"></div>
           <%!-- User dropdown — opens downward, closes on second click --%>
          <details id="user-menu" class="app-usermenu">
            <summary class="app-topbar__avatar app-usermenu__trigger">{initials(assigns)}</summary>
            
            <ul id="user-menu-list" class="app-usermenu__panel">
              <li class="app-usermenu__head">
                <div class="app-usermenu__name">{name(assigns)}</div>
                
                <div class="app-usermenu__email">
                  {assigns[:current_professional] && assigns[:current_professional].email}
                </div>
              </li>
              
              <li>
                <.link navigate={~p"/dashboard"} class="app-usermenu__item">
                  <.icon name="hero-presentation-chart-line" class="size-4" /> Dashboard
                </.link>
              </li>
              
              <li>
                <.link navigate={~p"/patients"} class="app-usermenu__item">
                  <.icon name="hero-users" class="size-4" /> Mis Pacientes
                </.link>
              </li>
              
              <li class="app-usermenu__foot">
                <.link
                  href={~p"/logout"}
                  method="delete"
                  class="app-usermenu__item app-usermenu__item--danger"
                >
                  <.icon name="hero-arrow-left-on-rectangle" class="size-4" /> Cerrar sesión
                </.link>
              </li>
            </ul>
          </details>
        </header>
         <%!-- Page content --%>
        <main class="app-content">{@inner_content}</main>
      </div>
    </div>
     <.flash_group flash={@flash} />
    """
  end

  # ── Flash group ────────────────────────────────────────────────────

  attr(:flash, :map, required: true)
  attr(:id, :string, default: "flash-group")

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} /> <.flash kind={:error} flash={@flash} />
    </div>
    """
  end

  # ── Helpers ────────────────────────────────────────────────────────

  defp nav_items do
    [
      %{
        id: "dashboard",
        label: "Dashboard",
        path: ~p"/dashboard",
        icon: "hero-presentation-chart-line",
        view: AletheaWeb.DashboardLive
      },
      %{
        id: "patients",
        label: "Mis Pacientes",
        path: ~p"/patients",
        icon: "hero-users",
        view: AletheaWeb.PatientLive.Index
      }
    ]
  end

  defp active?(assigns, view) do
    case assigns[:socket] do
      nil -> false
      socket -> socket.view == view
    end
  end

  defp name(assigns) do
    user = assigns[:current_professional]

    cond do
      is_nil(user) -> "Invitado"
      is_binary(user.full_name) and user.full_name != "" -> user.full_name
      is_binary(user.email) -> user.email
      true -> "Usuario"
    end
  end

  defp initials(assigns) do
    name(assigns)
    |> String.split(~r/\s+/, trim: true)
    |> Enum.take(2)
    |> Enum.map(&(String.first(&1) |> String.upcase()))
    |> Enum.join()
    |> case do
      "" -> "U"
      s -> s
    end
  end
end
