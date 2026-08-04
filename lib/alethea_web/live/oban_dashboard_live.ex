defmodule AletheaWeb.ObanDashboardLive do
  @moduledoc """
  Oban Dashboard LiveView for authenticated professionals.

  Shows job queues, states, and allows cancel/retry operations.
  """

  use AletheaWeb, :live_view

  import Ecto.Query, only: [where: 2, order_by: 2, limit: 2]

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
    <div class="p-6">
      <div class="flex justify-between items-center mb-6">
        <h1 class="text-2xl font-bold">Oban Dashboard</h1>
        <%= if @selected_job do %>
          <button
            type="button"
            class="px-4 py-2 text-sm bg-gray-100 hover:bg-gray-200 rounded"
            phx-click="close_job_details"
          >
            Close Details
          </button>
        <% end %>
      </div>
      
    <!-- Filters -->
      <div class="flex gap-4 mb-6">
        <div>
          <label class="block text-sm font-medium mb-1">Queue</label>
          <select
            class="rounded border-gray-300"
            phx-change="filter_queue"
          >
            <option value="all" selected={@selected_queue == "all"}>All Queues</option>
            <%= for queue <- @queues do %>
              <option value={queue} selected={@selected_queue == queue}>
                {queue}
              </option>
            <% end %>
          </select>
        </div>

        <div>
          <label class="block text-sm font-medium mb-1">State</label>
          <select
            class="rounded border-gray-300"
            phx-change="filter_state"
          >
            <option value="all" selected={@selected_state == "all"}>All States</option>
            <%= for state <- @states do %>
              <option value={state} selected={@selected_state == state}>
                {state}
              </option>
            <% end %>
          </select>
        </div>

        <div class="flex items-end">
          <button
            type="button"
            class="px-4 py-2 bg-blue-600 text-white rounded hover:bg-blue-700"
            phx-click="refresh"
          >
            Refresh
          </button>
        </div>
      </div>
      
    <!-- Queue Stats -->
      <div class="grid grid-cols-6 gap-4 mb-6">
        <%= for queue <- @queues do %>
          <div class="bg-gray-50 rounded-lg p-4">
            <div class="text-sm text-gray-500">{queue}</div>
            <div class="text-2xl font-bold">{get_queue_count(@queue_stats, queue)}</div>
          </div>
        <% end %>
      </div>
      
    <!-- Job List -->
      <div class="bg-white rounded-lg shadow overflow-hidden">
        <table class="w-full">
          <thead class="bg-gray-50">
            <tr>
              <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">ID</th>
              <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">Queue</th>
              <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">Worker</th>
              <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">State</th>
              <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">Args</th>
              <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                Attempts
              </th>
              <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">Actions</th>
            </tr>
          </thead>
          <tbody id="jobs" phx-update="stream" class="divide-y divide-gray-200">
            <%= for {id, job} <- @streams.jobs do %>
              <tr id={id}>
                <td class="px-4 py-3 text-sm">{job.id}</td>
                <td class="px-4 py-3 text-sm">{job.queue}</td>
                <td class="px-4 py-3 text-sm">{job.worker}</td>
                <td class="px-4 py-3">
                  <span class={[
                    "px-2 py-1 text-xs rounded-full",
                    state_color(job.state)
                  ]}>
                    {job.state}
                  </span>
                </td>
                <td class="px-4 py-3 text-sm text-gray-500 max-w-xs truncate">
                  {inspect(job.args)}
                </td>
                <td class="px-4 py-3 text-sm">
                  {job.attempt}{if job.max_attempts, do: "/#{job.max_attempts}"}
                </td>
                <td class="px-4 py-3 text-sm">
                  <div class="flex gap-2">
                    <button
                      type="button"
                      class="text-blue-600 hover:text-blue-800"
                      phx-click="view_job"
                      phx-value-job-id={job.id}
                    >
                      View
                    </button>
                    <%= if job.state in [:available, :scheduled, :retryable] do %>
                      <button
                        type="button"
                        class="text-red-600 hover:text-red-800"
                        phx-click="cancel_job"
                        phx-value-job-id={job.id}
                      >
                        Cancel
                      </button>
                    <% end %>
                    <%= if job.state == :discarded do %>
                      <button
                        type="button"
                        class="text-green-600 hover:text-green-800"
                        phx-click="retry_job"
                        phx-value-job-id={job.id}
                      >
                        Retry
                      </button>
                    <% end %>
                  </div>
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>

        <%= if @streams.jobs == [] do %>
          <div class="p-6 text-center text-gray-500">
            No jobs found matching the current filters.
          </div>
        <% end %>
      </div>
      
    <!-- Job Details Modal -->
      <%= if @selected_job do %>
        <div class="fixed inset-0 bg-black bg-opacity-50 flex items-center justify-center z-50">
          <div class="bg-white rounded-lg p-6 max-w-2xl w-full mx-4 max-h-[80vh] overflow-y-auto">
            <h2 class="text-xl font-bold mb-4">Job Details</h2>
            <dl class="space-y-3">
              <div class="flex">
                <dt class="font-medium w-32">ID:</dt>
                <dd>{@selected_job.id}</dd>
              </div>
              <div class="flex">
                <dt class="font-medium w-32">Worker:</dt>
                <dd>{@selected_job.worker}</dd>
              </div>
              <div class="flex">
                <dt class="font-medium w-32">Queue:</dt>
                <dd>{@selected_job.queue}</dd>
              </div>
              <div class="flex">
                <dt class="font-medium w-32">State:</dt>
                <dd>{@selected_job.state}</dd>
              </div>
              <div class="flex">
                <dt class="font-medium w-32">Attempt:</dt>
                <dd>{@selected_job.attempt}/{@selected_job.max_attempts}</dd>
              </div>
              <div class="flex">
                <dt class="font-medium w-32">Args:</dt>
                <dd class="bg-gray-100 p-2 rounded text-sm">
                  {inspect(@selected_job.args, pretty: true)}
                </dd>
              </div>
              <div class="flex">
                <dt class="font-medium w-32">Meta:</dt>
                <dd class="bg-gray-100 p-2 rounded text-sm">
                  {inspect(@selected_job.meta, pretty: true)}
                </dd>
              </div>
              <%= if @selected_job.attempted_by do %>
                <div class="flex">
                  <dt class="font-medium w-32">Attempted By:</dt>
                  <dd>{@selected_job.attempted_by}</dd>
                </div>
              <% end %>
              <%= if @selected_job.completed_at do %>
                <div class="flex">
                  <dt class="font-medium w-32">Completed At:</dt>
                  <dd>{@selected_job.completed_at}</dd>
                </div>
              <% end %>
            </dl>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  @impl true
  def handle_event("filter_queue", %{"queue" => queue}, socket) do
    params = %{socket.assigns.selected_state => socket.assigns.selected_state, "queue" => queue}
    {:noreply, push_patch(socket, to: path_with_params(socket, params))}
  end

  def handle_event("filter_state", %{"state" => state}, socket) do
    params = %{"queue" => socket.assigns.selected_queue, state => state}
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
     |> put_flash(:info, "Job cancelled successfully")
     |> load_jobs()}
  end

  def handle_event("retry_job", %{"job_id" => job_id}, socket) do
    job_id = String.to_integer(job_id)

    case Oban.retry_job(job_id) do
      :ok ->
        {:noreply,
         socket
         |> assign(:selected_job, nil)
         |> put_flash(:info, "Job retried successfully")
         |> load_jobs()}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to retry job: #{inspect(reason)}")}
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
      |> Enum.map(fn job -> {job.id, job} end)

    queue_stats =
      @queues
      |> Enum.map(fn q ->
        count =
          Job
          |> where(queue: ^q)
          |> where(state: [:available, :scheduled, :executing])
          |> Repo.aggregate(:count)

        {q, count}
      end)
      |> Map.new()

    socket
    |> stream(:jobs, [], reset: true)
    |> stream(:jobs, jobs)
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

  defp state_color("available"), do: "bg-green-100 text-green-800"
  defp state_color("scheduled"), do: "bg-blue-100 text-blue-800"
  defp state_color("executing"), do: "bg-yellow-100 text-yellow-800"
  defp state_color("retryable"), do: "bg-orange-100 text-orange-800"
  defp state_color("completed"), do: "bg-gray-100 text-gray-800"
  defp state_color("discarded"), do: "bg-red-100 text-red-800"
  defp state_color(_), do: "bg-gray-100 text-gray-800"
end
