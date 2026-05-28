defmodule AletheaWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use AletheaWeb, :html

  embed_templates "layouts/*"

  @doc """
  Renders your app layout.
  """
  attr :current_professional, :any, default: nil
  attr :flash, :map, required: true
  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="min-h-screen bg-slate-50 text-slate-800">
      <header class="navbar bg-white border-b border-slate-200/80 shadow-sm px-4 sm:px-6 lg:px-8 sticky top-0 z-40">
        <div class="flex-1">
          <.link navigate={~p"/"} class="flex items-center gap-2 font-bold text-xl tracking-tighter">
            <img src={~p"/images/logo.svg"} width="32" class="rounded-lg" /> Alethea
          </.link>
        </div>
        <div class="flex-none gap-2">
          <ul :if={!@current_professional} class="menu menu-horizontal px-1 gap-2">
            <li><.link navigate={~p"/login"} class="btn btn-ghost btn-sm">Ingresar</.link></li>
            <li>
              <.link navigate={~p"/register"} class="btn btn-primary btn-sm">Registrarse</.link>
            </li>
          </ul>

          <div :if={@current_professional} class="dropdown dropdown-end">
            <div tabindex="0" role="button" class="btn btn-ghost btn-circle avatar placeholder">
              <div class="bg-primary text-primary-content rounded-full w-10">
                <span class="text-xs">{String.at(@current_professional.full_name, 0)}</span>
              </div>
            </div>
            <ul
              tabindex="0"
              class="menu menu-sm dropdown-content mt-3 z-[1] p-2 shadow-lg border border-slate-100 bg-white rounded-box w-52"
            >
              <li class="menu-title text-xs opacity-50 px-4 py-2">
                {@current_professional.full_name}
              </li>
              <li><.link navigate={~p"/dashboard"}>Dashboard</.link></li>
              <li><.link navigate={~p"/patients"}>Mis Pacientes</.link></li>
              <li class="divider my-0"></li>
              <li>
                <.link href={~p"/logout"} method="delete" class="text-error">
                  Cerrar sesión
                </.link>
              </li>
            </ul>
          </div>
        </div>
      </header>

      <main class="container mx-auto px-4 py-8 sm:px-6 lg:px-8">
        <div class="mx-auto max-w-4xl">
          {@inner_content}
        </div>
      </main>

      <.flash_group flash={@flash} />
    </div>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.
  """
  attr :flash, :map, required: true
  attr :id, :string, default: "flash-group"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />
    </div>
    """
  end
end
