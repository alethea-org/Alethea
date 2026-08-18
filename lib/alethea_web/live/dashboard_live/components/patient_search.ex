defmodule AletheaWeb.DashboardLive.Components.PatientSearch do
  @moduledoc """
  The caseload picker at the top of the dashboard.

  The controls sit in a single horizontal command bar and the
  caseload renders as a card grid underneath. The previous layout
  stacked the panel title, the search box, three filter chips and a
  sort select as five rows inside a narrow scrolling column, so a
  professional with one patient read five rows of chrome before
  reaching the only card that mattered.

  Filters are progressive disclosure: the chips live in a popover
  whose trigger carries the active count, so an untouched filter set
  costs one control instead of a row.
  """
  use AletheaWeb, :live_component

  @valid_filters ~w(active needs_attention archived)
  @valid_sorts ~w(urgent_intervention last_activity alias)

  @filter_labels %{
    "active" => "Activo",
    "needs_attention" => "Atención",
    "archived" => "Archivado"
  }

  @sort_labels %{
    "urgent_intervention" => "Urgencia",
    "last_activity" => "Actividad",
    "alias" => "Nombre"
  }

  def mount(socket) do
    {:ok,
     socket
     |> assign(:query, "")
     |> assign(:active_filters, MapSet.new())
     |> assign(:sort, "urgent_intervention")}
  end

  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(:id, assigns.id)
     |> assign(:patients, assigns.patients)
     |> assign(:selected_patient_id, Map.get(assigns, :selected_patient_id))}
  end

  def handle_event("search", %{"q" => query}, socket) do
    {:noreply, assign(socket, :query, String.trim(query))}
  end

  def handle_event("toggle_filter", %{"filter" => f}, socket) when f in @valid_filters do
    filters = socket.assigns.active_filters

    updated =
      if MapSet.member?(filters, f),
        do: MapSet.delete(filters, f),
        else: MapSet.put(filters, f)

    {:noreply, assign(socket, :active_filters, updated)}
  end

  def handle_event("toggle_filter", _, socket), do: {:noreply, socket}

  def handle_event("set_sort", %{"sort" => s}, socket) when s in @valid_sorts do
    {:noreply, assign(socket, :sort, s)}
  end

  def handle_event("set_sort", _, socket), do: {:noreply, socket}

  def render(assigns) do
    filtered =
      assigns.patients
      |> filter_by_query(assigns.query)
      |> filter_by_chips(assigns.active_filters)
      |> sort_patients(assigns.sort)

    assigns =
      assigns
      |> assign(:filtered, filtered)
      |> assign(:filter_labels, @filter_labels)
      |> assign(:sort_labels, @sort_labels)
      |> assign(:active_filter_count, MapSet.size(assigns.active_filters))

    ~H"""
    <div>
      <%!-- ── Command bar — one row for every control ── --%>
      <div class="cmdbar">
        <div class="cmdbar__search">
          <.icon name="hero-magnifying-glass" class="cmdbar__search-icon" />
          <input
            type="text"
            name="q"
            value={@query}
            placeholder="Buscar por alias…"
            phx-change="search"
            phx-target={@myself}
            phx-debounce="300"
            autocomplete="off"
            aria-label="Buscar paciente por alias"
            class="text-input"
          />
        </div>
        <span class="cmdbar__count">{length(@filtered)} de {length(@patients)}</span>
        <div class="cmdbar__divider"></div>

        <details class="filter-menu" id={"#{@id}-filters"}>
          <summary>
            Filtros
            <span :if={@active_filter_count > 0} class="filter-badge">{@active_filter_count}</span>
          </summary>

          <div class="filter-menu__panel">
            <p class="filter-menu__title">Estado del paciente</p>

            <div class="filter-menu__chips">
              <button
                :for={{key, label} <- @filter_labels}
                type="button"
                phx-click="toggle_filter"
                phx-value-filter={key}
                phx-target={@myself}
                aria-pressed={to_string(MapSet.member?(@active_filters, key))}
                class={[
                  "filter-chip",
                  MapSet.member?(@active_filters, key) && "filter-chip--on"
                ]}
              >
                {label}
              </button>
            </div>
          </div>
        </details>

        <div class="cmdbar__sort">
          <label for={"#{@id}-sort"}>Ordenar</label>
          <select
            id={"#{@id}-sort"}
            name="sort"
            phx-change="set_sort"
            phx-target={@myself}
            class="text-input"
          >
            <option :for={{key, label} <- @sort_labels} value={key} selected={@sort == key}>
              {label}
            </option>
          </select>
        </div>
      </div>
      <%!-- ── Caseload grid ── --%>
      <div :if={@filtered == []} class="empty-state">
        <.icon name="hero-magnifying-glass" class="empty-state__icon" />
        <p class="empty-state__title">Sin resultados</p>

        <p class="empty-state__text">
          Ningún paciente coincide con la búsqueda o los filtros activos.
        </p>
      </div>

      <nav :if={@filtered != []} id={"#{@id}-results"} class="patient-grid">
        <.link
          :for={patient <- @filtered}
          patch={~p"/dashboard/patients/#{patient.id}"}
          id={"ps-patient-#{patient.id}"}
          class={[
            "patient-card",
            @selected_patient_id == patient.id && "patient-card--on",
            patient.urgent_intervention && "patient-card--risk"
          ]}
        >
          <div class="patient-card__head">
            <span class={[
              "pt-avatar patient-card__avatar",
              patient.urgent_intervention && "pt-avatar--risk"
            ]}>
              {initials(patient.alias)}
            </span>
            <div style="min-width:0;">
              <div class="patient-card__name">{patient.alias}</div>

              <div class="patient-card__meta">{schedule_label(patient)}</div>
            </div>
          </div>

          <div class="patient-card__foot">
            <span style="display:flex; align-items:center; gap:6px; font-size:12px;">
              <span class={"status-dot " <> status_dot(patient)}></span> {status_label(patient)}
            </span>
            <span :if={@selected_patient_id == patient.id} class="pt-pill pt-pill--neutral">
              En briefing
            </span>
          </div>
        </.link>
        <.link navigate={~p"/patients/new"} class="patient-card patient-card--new">
          <.icon name="hero-user-plus" class="size-5" /> <strong>Nuevo paciente</strong>
          <span style="font-size:12px;">Se crea con su propia clave de cifrado.</span>
        </.link>
      </nav>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Filter + sort logic (pure functions — no DB, no user input in HTML)
  # ---------------------------------------------------------------------------

  defp filter_by_query(patients, ""), do: patients

  defp filter_by_query(patients, query) do
    q = String.downcase(query)
    Enum.filter(patients, fn p -> p.alias && String.contains?(String.downcase(p.alias), q) end)
  end

  defp filter_by_chips(patients, filters) when map_size(filters) == 0, do: patients

  defp filter_by_chips(patients, filters) do
    Enum.filter(patients, fn p -> Enum.all?(filters, &matches_filter?(p, &1)) end)
  end

  defp matches_filter?(p, "active"), do: (p.status || "active") == "active"
  defp matches_filter?(p, "needs_attention"), do: p.urgent_intervention == true
  defp matches_filter?(p, "archived"), do: p.status == "archived"
  defp matches_filter?(_, _), do: false

  defp sort_patients(patients, "urgent_intervention") do
    Enum.sort_by(patients, fn p ->
      {if(p.urgent_intervention, do: 0, else: 1), String.downcase(p.alias || "")}
    end)
  end

  defp sort_patients(patients, "last_activity") do
    epoch = ~U[1970-01-01 00:00:00Z]
    Enum.sort_by(patients, fn p -> p.updated_at || epoch end, {:desc, DateTime})
  end

  defp sort_patients(patients, "alias") do
    Enum.sort_by(patients, fn p -> String.downcase(p.alias || "") end)
  end

  defp sort_patients(patients, _), do: patients

  # ---------------------------------------------------------------------------
  # Presentation helpers
  # ---------------------------------------------------------------------------

  defp initials(alias_name) when is_binary(alias_name) do
    alias_name
    |> String.split()
    |> Enum.map(&String.first/1)
    |> Enum.take(2)
    |> Enum.join()
    |> String.upcase()
  end

  defp initials(_), do: "?"

  # The card splits what the old single line conflated: when the next
  # session lands is a schedule fact, how the patient is doing is a
  # clinical one. They now read on separate lines.
  defp schedule_label(%{session_day_of_week: d, session_time: t}) when not is_nil(d),
    do: "#{format_day(d)} · #{format_time(t)}"

  defp schedule_label(_), do: "Sin horario"

  defp status_label(%{urgent_intervention: true}), do: "Intervención urgente"
  defp status_label(%{status: "archived"}), do: "Archivado"
  defp status_label(_), do: "En seguimiento"

  defp status_dot(%{urgent_intervention: true}), do: "status-dot--risk"
  defp status_dot(%{status: "archived"}), do: "status-dot"
  defp status_dot(_), do: "status-dot--ok"

  defp format_day(1), do: "Lun"
  defp format_day(2), do: "Mar"
  defp format_day(3), do: "Mié"
  defp format_day(4), do: "Jue"
  defp format_day(5), do: "Vie"
  defp format_day(6), do: "Sáb"
  defp format_day(7), do: "Dom"
  defp format_day(_), do: "-"

  defp format_time(%Time{} = t), do: Calendar.strftime(t, "%H:%M")
  defp format_time(_), do: "-"
end
