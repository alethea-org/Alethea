defmodule AletheaWeb.DashboardLive.Components.PatientSearch do
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

    ~H"""
    <div style="border-radius:16px; overflow:hidden; border:1px solid #e2e8f0; background:#fff;">
      <%!-- Search + controls bar --%>
      <div style="padding:10px 14px; border-bottom:1px solid #f1f5f9; background:#fafbfc; display:flex; flex-direction:column; gap:8px;">
        <%!-- Header row --%>
        <div style="display:flex; align-items:center; gap:8px;">
          <.icon name="hero-users" style="width:14px; height:14px; color:#94a3b8; flex-shrink:0;" />
          <span style="font-size:10px; font-weight:700; text-transform:uppercase; letter-spacing:0.06em; color:#64748b; flex:1;">
            Mis Pacientes
          </span>
          <span style="font-size:10px; color:#94a3b8; font-variant-numeric:tabular-nums;">
            {length(@filtered)}/{length(@patients)}
          </span>
        </div>
        <%!-- Search input --%>
        <div style="position:relative;">
          <.icon
            name="hero-magnifying-glass"
            style="position:absolute; left:8px; top:50%; transform:translateY(-50%); width:13px; height:13px; color:#94a3b8; pointer-events:none;"
          />
          <input
            type="text"
            name="q"
            value={@query}
            placeholder="Buscar por alias…"
            phx-change="search"
            phx-target={@myself}
            phx-debounce="300"
            autocomplete="off"
            style="width:100%; padding:6px 10px 6px 28px; border:1px solid #e2e8f0; border-radius:8px; font-size:12px; background:#fff; color:#334155; outline:none; box-sizing:border-box;"
          />
        </div>
        <%!-- Filter chips — AND logic --%>
        <div style="display:flex; gap:4px; flex-wrap:wrap;">
          <%= for {key, label} <- @filter_labels do %>
            <button
              phx-click="toggle_filter"
              phx-value-filter={key}
              phx-target={@myself}
              style={chip_style(MapSet.member?(@active_filters, key))}
            >
              {label}
            </button>
          <% end %>
        </div>
        <%!-- Sort select --%>
        <div style="display:flex; align-items:center; gap:6px;">
          <span style="font-size:10px; color:#94a3b8; white-space:nowrap;">Ordenar:</span>
          <select
            name="sort"
            phx-change="set_sort"
            phx-target={@myself}
            style="flex:1; padding:4px 8px; border:1px solid #e2e8f0; border-radius:6px; font-size:11px; background:#fff; color:#334155; cursor:pointer;"
          >
            <%= for {key, label} <- @sort_labels do %>
              <option value={key} selected={@sort == key}>{label}</option>
            <% end %>
          </select>
        </div>
      </div>
      <%!-- Patient list --%>
      <nav id={"#{@id}-results"}>
        <div :if={@filtered == []} style="padding:32px 16px; text-align:center;">
          <.icon
            name="hero-magnifying-glass"
            style="width:24px; height:24px; color:#cbd5e1; margin:0 auto 8px; display:block;"
          />
          <p style="font-size:12px; color:#94a3b8;">Sin resultados</p>
        </div>

        <%= for patient <- @filtered do %>
          <.link
            patch={~p"/dashboard/patients/#{patient.id}"}
            id={"ps-patient-#{patient.id}"}
            style={patient_row_style(@selected_patient_id == patient.id)}
          >
            <div style={avatar_style(@selected_patient_id == patient.id)}>
              <span style={avatar_text_style(@selected_patient_id == patient.id)}>
                {patient.alias
                |> String.split()
                |> Enum.map(&String.first/1)
                |> Enum.take(2)
                |> Enum.join()
                |> String.upcase()}
              </span>
            </div>

            <div style="min-width:0; flex:1;">
              <div style="font-size:13px; font-weight:600; color:#1e293b; overflow:hidden; text-overflow:ellipsis; white-space:nowrap;">
                {patient.alias}
              </div>

              <div style="font-size:10px; color:#94a3b8; margin-top:1px;">
                {status_label(patient)}
              </div>
            </div>

            <span
              :if={patient.urgent_intervention}
              style="width:8px; height:8px; border-radius:50%; background:#ef4444; flex-shrink:0;"
              class="animate-pulse-dot"
            >
            </span>
          </.link>
        <% end %>
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
  # Style helpers (keep interpolation out of template for readability)
  # ---------------------------------------------------------------------------

  defp chip_style(true),
    do:
      "padding:3px 8px; border-radius:6px; font-size:10px; font-weight:600; cursor:pointer; border:1px solid #6366f1; background:#eef2ff; color:#6366f1;"

  defp chip_style(false),
    do:
      "padding:3px 8px; border-radius:6px; font-size:10px; font-weight:600; cursor:pointer; border:1px solid #e2e8f0; background:#fff; color:#64748b;"

  defp patient_row_style(true),
    do:
      "display:flex; align-items:center; gap:10px; padding:10px 14px; text-decoration:none; transition:background .15s; border-bottom:1px solid #f8fafc; background:#eef2ff; border-left:3px solid #6366f1;"

  defp patient_row_style(false),
    do:
      "display:flex; align-items:center; gap:10px; padding:10px 14px; text-decoration:none; transition:background .15s; border-bottom:1px solid #f8fafc; border-left:3px solid transparent;"

  defp avatar_style(true),
    do:
      "width:32px; height:32px; border-radius:50%; display:flex; align-items:center; justify-content:center; flex-shrink:0; background:rgba(99,102,241,.12);"

  defp avatar_style(false),
    do:
      "width:32px; height:32px; border-radius:50%; display:flex; align-items:center; justify-content:center; flex-shrink:0; background:#f1f5f9;"

  defp avatar_text_style(true), do: "font-size:10px; font-weight:700; color:#6366f1;"
  defp avatar_text_style(false), do: "font-size:10px; font-weight:700; color:#64748b;"

  defp status_label(%{urgent_intervention: true}), do: "Intervención urgente"
  defp status_label(%{status: "archived"}), do: "Archivado"

  defp status_label(%{session_day_of_week: d, session_time: t}) when not is_nil(d),
    do: "#{format_day(d)} · #{format_time(t)}"

  defp status_label(_), do: "Sin horario"

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
