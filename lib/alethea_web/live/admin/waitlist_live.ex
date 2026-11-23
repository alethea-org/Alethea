defmodule AletheaWeb.Admin.WaitlistLive do
  @moduledoc """
  Operator view of the launch waitlist (`/admin/waitlist`): who signed up
  from the landing page, newest first, with a CSV download.
  """
  use AletheaWeb, :live_view

  alias Alethea.Waitlist

  @impl true
  def mount(_params, _session, socket) do
    entries = Waitlist.list_entries()

    {:ok,
     socket
     |> assign(:page_title, "Lista de espera")
     |> assign(:count, length(entries))
     |> stream(:entries, entries)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="pt ptd-wrap">
      <div class="ptd-head">
        <div>
          <p class="pt-eyebrow">Lanzamiento</p>
          <h1 class="pt-h1">Lista de espera</h1>
          <p class="pt-muted">{people(@count)}</p>
        </div>
        <div class="page-head__actions">
          <a
            id="waitlist-export"
            href={~p"/admin/waitlist.csv"}
            class="button-primary button-primary--sm"
          >
            Descargar CSV
          </a>
        </div>
      </div>

      <p :if={@count == 0} id="waitlist-empty" class="pt-muted">
        Todavía no se anotó nadie.
      </p>

      <table :if={@count > 0} class="data-table">
        <thead>
          <tr>
            <th>Nombre</th>
            <th>Email</th>
            <th>Fecha</th>
          </tr>
        </thead>
        <tbody id="waitlist-entries" phx-update="stream">
          <tr :for={{dom_id, entry} <- @streams.entries} id={dom_id}>
            <td>{entry.name}</td>
            <td><a href={"mailto:#{entry.email}"}>{entry.email}</a></td>
            <td>{Calendar.strftime(entry.inserted_at, "%d/%m/%Y %H:%M")} UTC</td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  defp people(1), do: "1 persona"
  defp people(count), do: "#{count} personas"
end
