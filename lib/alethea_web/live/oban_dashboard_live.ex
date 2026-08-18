defmodule AletheaWeb.ObanDashboardLive do
  @moduledoc """
  Oban Dashboard LiveView for authenticated professionals.

  Shows job queues, states, and allows cancel/retry operations.

  The page used to be written in Tailwind utility classes, which the
  app does not compile — every `bg-gray-50`, `rounded-lg` and
  `text-xs` on it resolved to nothing, so the operational surface
  rendered as an unstyled HTML table. It now speaks the editorial
  system's data-table, stat-strip and pill components.
  """

  use AletheaWeb, :live_view

  import Ecto.Query, only: [where: 2, where: 3, order_by: 2, limit: 2]

  alias Oban.Job
  alias Alethea.Repo

  @queues [
    :default,
    :sessions,
    :schedulers,
    :reports,
    :ai_analysis
  ]

  @states [
    :available,
    :scheduled,
    :executing,
    :retryable,
    :completed,
    :discarded
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Oban Dashboard")
     |> assign(:queues, @queues)
     |> assign(:states, @states)
     # Without this the first render raises: `render/1` reads
     # `@selected_job` before any `view_job` event can assign it.
     |> assign(:selected_job, nil)
     |> assign(:selected_queue, "all")
     |> assign(:selected_state, "all")
     |> stream(:jobs, [])
     |> load_jobs()}
  end

  @impl true
  def handle_params(params, _url, socket) do
    selected_queue = Map.get(params, "queue", "all")
    selected_state = Map.get(params, "state", "all")

    {:noreply,
     socket
     |> assign(:selected_queue, selected_queue)
     |> assign(:selected_state, selected_state)
     |> load_jobs()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="pt ptd-wrap">
      <%!-- ── Header ── --%>
      <div class="ptd-head">
        <div>
          <p class="pt-eyebrow">Operaciones</p>

          <h1 class="pt-h1">Cola de trabajos</h1>
        </div>

        <div class="page-head__actions">
          <button type="button" phx-click="refresh" class="button-secondary button-secondary--sm">
            <.icon name="hero-arrow-path" class="size-4" style="margin-right:6px;" /> Actualizar
          </button>
        </div>
      </div>
      <%!-- ── Queue counters (available + scheduled + executing) ── --%>
      <div class="stat-strip" style="margin-bottom:24px;">
        <div :for={queue <- @queues} class="stat-tile">
          <div class="stat-tile__label">{queue}</div>

          <div class="stat-tile__value">{get_queue_count(@queue_stats, queue)}</div>

          <div class="stat-tile__desc">Pendientes</div>
        </div>
      </div>
      <%!-- ── Filters ── --%>
      <div class="cmdbar">
        <div class="cmdbar__sort">
          <label for="filter-queue">Cola</label>
          <select id="filter-queue" name="queue" phx-change="filter_queue" class="text-input">
            <option value="all" selected={@selected_queue == "all"}>Todas</option>

            <option :for={queue <- @queues} value={queue} selected={@selected_queue == "#{queue}"}>
              {queue}
            </option>
          </select>
        </div>

        <div class="cmdbar__divider"></div>

        <div class="cmdbar__sort">
          <label for="filter-state">Estado</label>
          <select id="filter-state" name="state" phx-change="filter_state" class="text-input">
            <option value="all" selected={@selected_state == "all"}>Todos</option>

            <option :for={state <- @states} value={state} selected={@selected_state == "#{state}"}>
              {state}
            </option>
          </select>
        </div>
      </div>
      <%!-- ── Job list ── --%>
      <div class="data-table-wrap">
        <table class="data-table">
          <thead>
            <tr>
              <th>ID</th>

              <th>Cola</th>

              <th>Worker</th>

              <th>Estado</th>

              <th>Args</th>

              <th>Intentos</th>

              <th><span class="sr-only">Acciones</span></th>
            </tr>
          </thead>

          <tbody id="jobs" phx-update="stream">
            <tr :for={{dom_id, job} <- @streams.jobs} id={dom_id}>
              <td style="font-variant-numeric:tabular-nums;">{job.id}</td>

              <td>{job.queue}</td>

              <td>{job.worker}</td>

              <td><span class={"pt-pill " <> state_pill(job.state)}>{job.state}</span></td>

              <td class="data-table__mono">{inspect(job.args)}</td>

              <td style="font-variant-numeric:tabular-nums;">
                {job.attempt}{if job.max_attempts, do: "/#{job.max_attempts}"}
              </td>

              <td>
                <div class="data-table__actions">
                  <button
                    type="button"
                    class="link-button"
                    phx-click="view_job"
                    phx-value-job_id={job.id}
                  >
                    Ver
                  </button>
                  <button
                    :if={job.state in ["available", "scheduled", "retryable"]}
                    type="button"
                    class="link-button link-button--danger"
                    phx-click="cancel_job"
                    phx-value-job_id={job.id}
                  >
                    Cancelar
                  </button>
                  <button
                    :if={job.state == "discarded"}
                    type="button"
                    class="link-button link-button--ok"
                    phx-click="retry_job"
                    phx-value-job_id={job.id}
                  >
                    Reintentar
                  </button>
                </div>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
      <%!-- ── Job details ── --%>
      <dialog :if={@selected_job} id="job-details" open class="pta-modal">
        <div class="pta-modal__head">
          <h3 class="pta-modal__title">Trabajo #{@selected_job.id}</h3>

          <button
            type="button"
            phx-click="close_job_details"
            aria-label="Cerrar"
            class="pta-modal__close"
          >
            <.icon name="hero-x-mark" class="size-4" />
          </button>
        </div>

        <div class="pta-modal__body">
          <.list>
            <:item title="Worker">{@selected_job.worker}</:item>

            <:item title="Cola">{@selected_job.queue}</:item>

            <:item title="Estado">{@selected_job.state}</:item>

            <:item title="Intentos">{@selected_job.attempt}/{@selected_job.max_attempts}</:item>

            <:item title="Args">{inspect(@selected_job.args, pretty: true)}</:item>

            <:item title="Meta">{inspect(@selected_job.meta, pretty: true)}</:item>
          </.list>

          <p :if={@selected_job.attempted_by} class="pta-hint" style="margin-top:12px;">
            Ejecutado por {@selected_job.attempted_by}
          </p>

          <p :if={@selected_job.completed_at} class="pta-hint">
            Completado el {@selected_job.completed_at}
          </p>
        </div>
      </dialog>
    </div>
    """
  end

  @impl true
  def handle_event("filter_queue", %{"queue" => queue}, socket) do
    params = %{"queue" => queue, "state" => socket.assigns.selected_state}
    {:noreply, push_patch(socket, to: path_with_params(socket, params))}
  end

  def handle_event("filter_state", %{"state" => state}, socket) do
    params = %{"queue" => socket.assigns.selected_queue, "state" => state}
    {:noreply, push_patch(socket, to: path_with_params(socket, params))}
  end

  def handle_event("refresh", _params, socket) do
    {:noreply, load_jobs(socket)}
  end

  def handle_event("close_job_details", _params, socket) do
    {:noreply, assign(socket, :selected_job, nil)}
  end

  def handle_event("view_job", %{"job_id" => job_id}, socket) do
    job = Repo.get!(Job, String.to_integer(job_id))
    {:noreply, assign(socket, :selected_job, job)}
  end

  def handle_event("cancel_job", %{"job_id" => job_id}, socket) do
    job_id = String.to_integer(job_id)

    # Oban.cancel_job/1 is specced to always return :ok; assert it so a
    # contract change surfaces loudly instead of being silently swallowed.
    :ok = Oban.cancel_job(job_id)

    {:noreply,
     socket
     |> assign(:selected_job, nil)
     |> put_flash(:info, "Trabajo cancelado")
     |> load_jobs()}
  end

  def handle_event("retry_job", %{"job_id" => job_id}, socket) do
    job_id = String.to_integer(job_id)

    case Oban.retry_job(job_id) do
      :ok ->
        {:noreply,
         socket
         |> assign(:selected_job, nil)
         |> put_flash(:info, "Trabajo reencolado")
         |> load_jobs()}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "No se pudo reintentar el trabajo: #{inspect(reason)}")}
    end
  end

  # Private functions

  defp load_jobs(socket) do
    jobs =
      Job
      |> maybe_filter_by_queue(socket.assigns.selected_queue)
      |> maybe_filter_by_state(socket.assigns.selected_state)
      |> order_by(desc: :id)
      |> limit(100)
      |> Repo.all()

    # `oban_jobs.queue` and `.state` are string columns. Passing the
    # atoms from @queues / @states straight into the query raised
    # `Ecto.Query.CastError` on mount, so the page never rendered at
    # all — the restyle only made the crash visible sooner.
    queue_stats =
      @queues
      |> Enum.map(fn q ->
        count =
          Job
          |> where(queue: ^to_string(q))
          |> where([j], j.state in ["available", "scheduled", "executing"])
          |> Repo.aggregate(:count)

        {q, count}
      end)
      |> Map.new()

    # `stream/3` wants the structs themselves and derives each DOM id
    # from `:id`. The list used to be mapped to `{id, job}` tuples
    # first, which `stream/3` rejects — the page raised on mount.
    socket
    |> stream(:jobs, jobs, reset: true)
    |> assign(:queue_stats, queue_stats)
  end

  defp maybe_filter_by_queue(query, "all"), do: query
  defp maybe_filter_by_queue(query, queue), do: where(query, queue: ^queue)

  defp maybe_filter_by_state(query, "all"), do: query
  defp maybe_filter_by_state(query, state), do: where(query, state: ^state)

  defp path_with_params(_socket, params) do
    query =
      params
      |> Enum.reject(fn {_, v} -> v == "all" end)
      |> URI.encode_query()

    "/admin/oban-dashboard#{if query != "", do: "?#{query}"}"
  end

  defp get_queue_count(stats, queue) do
    Map.get(stats, queue, 0)
  end

  # Oban stores `state` as a string column, so the clauses match
  # strings — the previous atom clauses never matched and every job
  # fell through to the neutral tone.
  defp state_pill("available"), do: "pt-pill--ok"
  defp state_pill("executing"), do: "pt-pill--warn"
  defp state_pill("retryable"), do: "pt-pill--warn"
  defp state_pill("discarded"), do: "pt-pill--danger"
  defp state_pill(_), do: "pt-pill--neutral"
end
