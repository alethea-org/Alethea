defmodule AletheaWeb.PatientLive.ClinicalSearch do
  @moduledoc """
  The non-authoritative, patient-scoped semantic search view over
  `Alethea.ClinicalRecord.Rag.Retrieval.search/4`
  (sdd/clinical-rag-projection, GitHub #196, WU5/PR5, Phase 7 tasks
  7.1-7.2).

  Thin shell over `Retrieval.search/4`, same pattern as
  `TargetBehaviorLive.Review` over `Alethea.ClinicalRecord`: this
  module never touches `Alethea.Repo`, `Alethea.Encryption.PatientVault`,
  or any `Alethea.Accounts.load_*` key-loading function directly.

  ## Access control (spec's "Access Control" requirement)

  `mount/3` calls `Retrieval.search/4` once (with an empty query) both
  to authorize `current_professional` against `patient_id` and to load
  the initial `chunk_count`/`freshness` — the same accessor every other
  patient-scoped surface uses, per design section 7 ("Patient-scope
  authz falls out of `Retrieval.search/4`"). A non-treating
  professional is redirected before any patient data reaches the
  socket.

  ## Empty states (spec's "Empty States" requirement)

  `Retrieval.search/4` is a RANKING function, not a filter — it always
  returns up to `:limit` candidates from the patient's `:candidate_limit`
  window, ordered by score, with no minimum-relevance cutoff (design
  section 5 has no such threshold; WU4's apply-progress explicitly
  left this derivation to WU5). So distinguishing "nothing indexed
  yet" from "indexed, but nothing actually matches this query" needs a
  minimum relevance cutoff applied HERE, in the view: `@relevance_threshold`
  filters `results` before rendering. `:never_indexed` is `chunk_count == 0`
  (no relevance judgment needed — there is nothing to rank). `:no_match`
  is `chunk_count > 0` but every candidate's merged `score` falls below
  the threshold once an explicit query has been submitted.

  ## Non-authoritative badge (spec's "Citation and Non-Authoritative
  Labeling" requirement)

  Every rendered result carries `badge badge--non-authoritative`
  inside its `review-item__meta` — there is no dismiss/close control
  anywhere in this template, so the badge cannot be hidden after first
  render (this is a persistent indicator, not a one-time banner).

  ## Citation (same requirement)

  Each result shows its source kind and `source_occurred_at`. When the
  chunk carries a `target_behavior_id` (design's D2 filter facet), the
  citation additionally links to that target behavior's existing
  review timeline (`TargetBehaviorLive.Review`) — the one per-resource
  browsing surface that already exists; resources without a target
  behavior (e.g. a bare `ClinicalNote`) show the citation as text only,
  since no dedicated single-resource route exists for them and adding
  one is out of this slice's scope.

  ## Stream reset (spec: results must reflect only the current query)

  `handle_event("search", ...)` always re-`stream/3`s `:results` with
  `reset: true` — a second query never accumulates on top of the
  first's results (CLAUDE.md: streams are not enumerable, filtering
  means refetch + reset, never `phx-update="append"`).
  """
  use AletheaWeb, :live_view

  alias Alethea.ClinicalRecord.Rag.Retrieval

  # Below this merged score, a candidate is treated as "not actually
  # relevant" rather than "the closest thing we have" — see moduledoc.
  @relevance_threshold 0.35

  @impl true
  def mount(%{"patient_id" => patient_id}, _session, socket) do
    professional = socket.assigns.current_professional

    case Retrieval.search(professional, patient_id, "") do
      {:ok, %{chunk_count: chunk_count, freshness: freshness}} ->
        socket =
          socket
          |> assign(:page_title, "Búsqueda clínica (no autoritativa)")
          |> assign(:patient_id, patient_id)
          |> assign(:chunk_count, chunk_count)
          |> assign(:freshness, freshness)
          |> assign(:searched?, false)
          |> assign(:empty_state, if(chunk_count == 0, do: :never_indexed, else: nil))
          |> assign(:query_form, to_form(%{"query" => ""}, as: "search"))
          |> stream_configure(:results, dom_id: &"clinical-search-result-#{&1.chunk_id}")
          |> stream(:results, [])

        {:ok, socket}

      {:error, :unauthorized} ->
        {:ok, deny_access(socket)}
    end
  end

  @impl true
  def handle_event("search", %{"search" => %{"query" => query}}, socket) do
    professional = socket.assigns.current_professional
    patient_id = socket.assigns.patient_id

    case Retrieval.search(professional, patient_id, query) do
      {:ok, %{results: results, chunk_count: chunk_count, freshness: freshness}} ->
        relevant = Enum.filter(results, &relevant?/1)

        empty_state =
          cond do
            chunk_count == 0 -> :never_indexed
            relevant == [] -> :no_match
            true -> nil
          end

        socket =
          socket
          |> assign(:searched?, true)
          |> assign(:chunk_count, chunk_count)
          |> assign(:freshness, freshness)
          |> assign(:empty_state, empty_state)
          |> assign(:query_form, to_form(%{"query" => query}, as: "search"))
          |> stream(:results, relevant, reset: true)

        {:noreply, socket}

      {:error, :unauthorized} ->
        {:noreply, deny_access(socket)}
    end
  end

  defp deny_access(socket) do
    socket
    |> put_flash(
      :error,
      "No estás autorizado para buscar en el historial clínico de este paciente."
    )
    |> push_navigate(to: ~p"/patients")
  end

  defp relevant?(%{score: score}), do: score >= @relevance_threshold

  defp source_kind_label("clinical_note"), do: "Nota clínica"
  defp source_kind_label("consultation_evidence"), do: "Evidencia citada"
  defp source_kind_label("clinician_observation"), do: "Observación del clínico"
  defp source_kind_label("ai_proposal"), do: "Propuesta de IA (aceptada)"
  defp source_kind_label("functional_analysis_draft"), do: "Borrador de análisis funcional"
  defp source_kind_label(other), do: other

  defp source_link(%{target_behavior_id: nil}, _patient_id), do: nil

  defp source_link(%{target_behavior_id: target_behavior_id}, patient_id) do
    ~p"/patients/#{patient_id}/target_behaviors/#{target_behavior_id}/review"
  end

  defp format_datetime(%DateTime{} = datetime) do
    Calendar.strftime(datetime, "%d/%m/%Y %H:%M")
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="clinical-search">
      <.header>
        Búsqueda clínica (no autoritativa)
        <:subtitle>
          Proyección semántica de apoyo. Nunca sustituye el historial clínico
          autoritativo — verificá siempre la fuente citada.
        </:subtitle>
      </.header>

      <div :if={@freshness.stale?} class="notice notice--warning">
        <.icon name="hero-clock" class="notice__icon" />
        <span>
          La indexación todavía está poniéndose al día ({@freshness.pending} evento(s)
          pendiente(s)). Los resultados pueden estar incompletos.
        </span>
      </div>

      <.form for={@query_form} id="clinical-search-form" phx-submit="search">
        <.input field={@query_form[:query]} type="text" label="Buscar en el historial clínico" />
        <div class="form-actions">
          <button type="submit" class="button-primary button-primary--sm">
            <.icon name="hero-magnifying-glass" class="size-4" style="margin-right:6px;" /> Buscar
          </button>
        </div>
      </.form>

      <div :if={@empty_state == :never_indexed} id="clinical-search-never-indexed" class="empty-state">
        <.icon name="hero-circle-stack" class="empty-state__icon" />
        <p class="empty-state__title">Todavía no hay nada indexado para este paciente</p>
      </div>

      <div :if={@empty_state == :no_match} id="clinical-search-no-match" class="empty-state">
        <.icon name="hero-magnifying-glass" class="empty-state__icon" />
        <p class="empty-state__title">No hay coincidencias para esta búsqueda</p>
      </div>

      <p :if={@empty_state == nil and not @searched?} class="pt-muted">
        Escribí una consulta para buscar en el historial clínico de este paciente.
      </p>

      <ol
        :if={@empty_state == nil and @searched?}
        id="clinical-search-results"
        phx-update="stream"
        class="review-timeline"
      >
        <li :for={{dom_id, result} <- @streams.results} id={dom_id} class="review-item">
          <div class="review-item__meta">
            <span class="review-item__kind">{source_kind_label(result.source_resource_type)}</span>
            <span class="review-item__time">{format_datetime(result.source_occurred_at)}</span>
            <span class="badge badge--non-authoritative">
              No autoritativo — proyección semántica, verificar en la fuente
            </span>
          </div>

          <p class="review-item__text">{result.content}</p>

          <div class="review-item__source">
            <.icon name="hero-link" class="size-3" />
            <%= if source_link(result, @patient_id) do %>
              <.link navigate={source_link(result, @patient_id)}>
                Ver fuente: {source_kind_label(result.source_resource_type)} · {format_datetime(
                  result.source_occurred_at
                )}
              </.link>
            <% else %>
              {source_kind_label(result.source_resource_type)} · {format_datetime(
                result.source_occurred_at
              )}
            <% end %>
          </div>
        </li>
      </ol>
    </div>
    """
  end
end
