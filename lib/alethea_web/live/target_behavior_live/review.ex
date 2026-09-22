defmodule AletheaWeb.TargetBehaviorLive.Review do
  @moduledoc """
  Clinical review workbench for one target behavior (PR3,
  sdd/alethea/issue-195-clinical-review-workbench, GitHub #195).

  Thin shell over `Alethea.ClinicalRecord` — this module never touches
  `Alethea.Repo`, `Alethea.Encryption.PatientVault`, or any
  `Alethea.Accounts.load_*` key-loading function directly. Every read and
  write goes through a `ClinicalRecord` public function, and every
  `handle_event/3` re-authorizes by passing `socket.assigns.current_professional`
  (assigned by the `:require_authenticated_professional` `live_session`'s
  `on_mount`) — a stale or forged client id in event params can never
  substitute for it, because no event reads a professional id from params.

  Provenance is rendered as three structurally distinct card kinds
  (`review-item--evidence`, `review-item--observation`,
  `review-item--proposal`) mirroring `Alethea.ClinicalRecord.review_timeline/3`'s
  table-identity provenance model (design A1) — never a shared "kind"
  label alone. AI proposals always carry a `badge--provisional` badge and
  their `status`; they are never rendered with clinical-note typography,
  and no code path in this module ever calls `create_clinical_note/3` as a
  side effect of accepting/editing/discarding a proposal or saving the
  draft (spec: note creation stays a distinct, explicit action).

  `suggest_patterns` is the only handler that enqueues AI generation
  (design D2 — clinician-triggered only, never automatic on evidence
  change). The PubSub topic `"target_behavior:\#{target_behavior_id}"` is
  subscribed to now so PR4's `AletheaJobs.AIProposalWorker` can broadcast
  `{:ai_proposals_ready, _}` / `{:ai_proposals_failed, _}` without another
  change to this file.
  """
  use AletheaWeb, :live_view

  alias Alethea.ClinicalRecord
  alias Alethea.ClinicalRecord.FunctionalAnalysisDraft

  @impl true
  def mount(%{"patient_id" => patient_id, "id" => target_behavior_id}, _session, socket) do
    professional = socket.assigns.current_professional

    case load_review(professional, patient_id, target_behavior_id) do
      {:ok, target_behavior, items} ->
        patient_alias = (target_behavior.patient && target_behavior.patient.alias) || "Paciente"
        target_behavior_description = target_behavior.description || "Conducta objetivo"

        evidence_count = Enum.count(items, &(&1.kind == :consultation_evidence))
        observation_count = Enum.count(items, &(&1.kind == :clinician_observation))
        proposal_count = Enum.count(items, &(&1.kind == :ai_proposal))
        has_sufficient_evidence = evidence_count > 0

        {draft_body, draft_tombstoned_at} =
          case ClinicalRecord.get_functional_analysis_draft(
                 professional,
                 patient_id,
                 target_behavior_id
               ) do
            {:ok, nil} -> {"", nil}
            {:ok, {:legally_deleted, deleted_at}} -> {"", deleted_at}
            {:ok, draft} -> {draft.body, nil}
            {:error, _reason} -> {"", nil}
          end

        draft_status = compute_draft_status(draft_tombstoned_at, draft_body)

        if connected?(socket) do
          Phoenix.PubSub.subscribe(Alethea.PubSub, "target_behavior:#{target_behavior_id}")
        end

        socket =
          socket
          |> assign(:page_title, "Revisión clínica · #{patient_alias}")
          |> assign(:patient_id, patient_id)
          |> assign(:target_behavior_id, target_behavior_id)
          |> assign(:patient_alias, patient_alias)
          |> assign(:target_behavior_description, target_behavior_description)
          |> assign(:evidence_count, evidence_count)
          |> assign(:observation_count, observation_count)
          |> assign(:proposal_count, proposal_count)
          |> assign(:has_sufficient_evidence, has_sufficient_evidence)
          |> assign(:draft_status, draft_status)
          |> assign(:generation_pending, false)
          |> assign(:editing_proposal_id, nil)
          |> assign(:citation_step, nil)
          |> assign(:evidence_sources, [])
          |> assign(:selected_evidence_source, nil)
          |> assign(:citation_excerpt, nil)
          |> assign(:citation_error, nil)
          |> assign(:citation_form, to_form(%{"excerpt" => ""}, as: "citation"))
          |> assign(:timeline_index, timeline_index(items))
          |> assign(:observation_form, to_form(%{"body" => ""}, as: "observation"))
          |> assign(:draft_form, to_form(%{"body" => draft_body}, as: "draft"))
          |> assign(:draft_tombstoned_at, draft_tombstoned_at)
          |> stream(:timeline, items)

        {:ok, socket}

      {:error, :unauthorized} ->
        {:ok, redirect_to_patients(socket, :unauthorized)}

      {:error, :not_found} ->
        {:ok, redirect_to_patients(socket, :not_found)}
    end
  end

  @impl true
  def handle_event("add_observation", %{"observation" => %{"body" => body}}, socket) do
    professional = socket.assigns.current_professional
    patient_id = socket.assigns.patient_id
    target_behavior_id = socket.assigns.target_behavior_id

    case ClinicalRecord.add_clinician_observation(
           professional,
           patient_id,
           target_behavior_id,
           body
         ) do
      {:ok, _observation} ->
        {:noreply,
         socket
         |> assign(:observation_form, to_form(%{"body" => ""}, as: "observation"))
         |> load_timeline()
         |> put_flash(:info, "Observación clínica agregada.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "No se pudo guardar la observación.")}
    end
  end

  @impl true
  def handle_event("open_evidence_citation", _params, socket) do
    professional = socket.assigns.current_professional
    patient_id = socket.assigns.patient_id

    case ClinicalRecord.list_evidence_sources(professional, patient_id) do
      {:ok, sources} ->
        {:noreply,
         socket
         |> reset_citation()
         |> assign(:citation_step, :select)
         |> assign(:evidence_sources, sources)}

      {:error, _reason} ->
        {:noreply,
         socket
         |> reset_citation()
         |> assign(:citation_step, :select)
         |> assign(:citation_error, "No se pudieron cargar las fuentes de evidencia.")}
    end
  end

  @impl true
  def handle_event("select_evidence_source", %{"id" => id, "kind" => kind}, socket) do
    source =
      Enum.find(socket.assigns.evidence_sources, fn source ->
        source.id == id and Atom.to_string(source.kind) == kind
      end)

    if source do
      {:noreply,
       socket
       |> assign(:citation_step, :excerpt)
       |> assign(:selected_evidence_source, source)
       |> assign(:citation_excerpt, nil)
       |> assign(:citation_error, nil)
       |> assign(:citation_form, to_form(%{"excerpt" => ""}, as: "citation"))}
    else
      {:noreply,
       assign(
         socket,
         :citation_error,
         "La fuente seleccionada no está disponible para este paciente."
       )}
    end
  end

  @impl true
  def handle_event("prepare_evidence_citation", %{"citation" => %{"excerpt" => excerpt}}, socket) do
    source = socket.assigns.selected_evidence_source

    cond do
      is_nil(source) ->
        {:noreply, assign(socket, :citation_error, "Seleccioná una fuente antes de continuar.")}

      excerpt == "" or String.trim(excerpt) == "" ->
        {:noreply,
         socket
         |> assign(:citation_form, to_form(%{"excerpt" => excerpt}, as: "citation"))
         |> assign(:citation_error, "Ingresá el fragmento exacto que querés citar.")}

      not String.contains?(source.content, excerpt) ->
        {:noreply,
         socket
         |> assign(:citation_form, to_form(%{"excerpt" => excerpt}, as: "citation"))
         |> assign(:citation_error, "El fragmento debe coincidir exactamente con la fuente.")}

      true ->
        {:noreply,
         socket
         |> assign(:citation_step, :confirm)
         |> assign(:citation_excerpt, excerpt)
         |> assign(:citation_error, nil)
         |> assign(:citation_form, to_form(%{"excerpt" => excerpt}, as: "citation"))}
    end
  end

  @impl true
  def handle_event("confirm_evidence_citation", _params, socket) do
    professional = socket.assigns.current_professional
    patient_id = socket.assigns.patient_id
    target_behavior_id = socket.assigns.target_behavior_id
    source = socket.assigns.selected_evidence_source
    excerpt = socket.assigns.citation_excerpt

    result =
      if source && is_binary(excerpt) do
        ClinicalRecord.cite_evidence_source(
          professional,
          patient_id,
          target_behavior_id,
          %{
            source_kind: Atom.to_string(source.kind),
            source_id: source.id,
            excerpt: excerpt
          }
        )
      else
        {:error, :invalid_citation_state}
      end

    case result do
      {:ok, _evidence} ->
        {:noreply,
         socket
         |> reset_citation()
         |> load_timeline()
         |> put_flash(:info, "Evidencia citada correctamente.")}

      {:error, _reason} ->
        {:noreply,
         assign(
           socket,
           :citation_error,
           "No se pudo citar la evidencia. Revisá el fragmento y volvé a intentar."
         )}
    end
  end

  @impl true
  def handle_event("cancel_evidence_citation", _params, socket) do
    {:noreply, reset_citation(socket)}
  end

  @impl true
  def handle_event("suggest_patterns", _params, socket) do
    if not socket.assigns.has_sufficient_evidence do
      {:noreply,
       put_flash(
         socket,
         :error,
         "No hay evidencia clínica suficiente para solicitar sugerencias de IA."
       )}
    else
      professional = socket.assigns.current_professional
      patient_id = socket.assigns.patient_id
      target_behavior_id = socket.assigns.target_behavior_id

      case ClinicalRecord.request_ai_proposals(professional, patient_id, target_behavior_id) do
        {:ok, :requested} ->
          {:noreply,
           socket
           |> assign(:generation_pending, true)
           |> put_flash(:info, "Generación de patrones solicitada.")}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, "No se pudo solicitar la generación de patrones.")}
      end
    end
  end

  @impl true
  def handle_event("start_edit_proposal", %{"id" => id}, socket) do
    previous_id = socket.assigns.editing_proposal_id

    socket =
      socket
      |> assign(:editing_proposal_id, id)
      |> reinsert_timeline_item(previous_id)
      |> reinsert_timeline_item(id)

    {:noreply, socket}
  end

  @impl true
  def handle_event("cancel_edit_proposal", _params, socket) do
    previous_id = socket.assigns.editing_proposal_id

    socket =
      socket
      |> assign(:editing_proposal_id, nil)
      |> reinsert_timeline_item(previous_id)

    {:noreply, socket}
  end

  @impl true
  def handle_event(
        "save_edit_proposal",
        %{"proposal_id" => id, "proposal" => %{"text" => text}},
        socket
      ) do
    professional = socket.assigns.current_professional
    patient_id = socket.assigns.patient_id

    case ClinicalRecord.edit_ai_proposal(professional, patient_id, id, text) do
      {:ok, _proposal} ->
        {:noreply,
         socket
         |> assign(:editing_proposal_id, nil)
         |> load_timeline()
         |> put_flash(:info, "Propuesta editada.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "No se pudo editar la propuesta.")}
    end
  end

  @impl true
  def handle_event("accept_proposal", %{"id" => id}, socket) do
    if socket.assigns.draft_tombstoned_at do
      {:noreply,
       put_flash(socket, :info, "Propuesta aceptada, pero no pudo agregarse al borrador.")}
    else
      professional = socket.assigns.current_professional
      patient_id = socket.assigns.patient_id
      target_behavior_id = socket.assigns.target_behavior_id

      case ClinicalRecord.accept_ai_proposal_into_draft(
             professional,
             patient_id,
             target_behavior_id,
             id
           ) do
        {:ok, %{draft: _draft}} ->
          draft_body =
            case ClinicalRecord.get_functional_analysis_draft(
                   professional,
                   patient_id,
                   target_behavior_id
                 ) do
              {:ok, %{body: body}} -> body
              _other -> ""
            end

          {:noreply,
           socket
           |> load_timeline()
           |> assign(:draft_form, to_form(%{"body" => draft_body}, as: "draft"))
           |> assign(:draft_status, :saved)
           |> put_flash(:info, "Propuesta aceptada y agregada al borrador.")}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, "No se pudo aceptar la propuesta.")}
      end
    end
  end

  @impl true
  def handle_event("discard_proposal", %{"id" => id}, socket) do
    professional = socket.assigns.current_professional
    patient_id = socket.assigns.patient_id

    case ClinicalRecord.discard_ai_proposal(professional, patient_id, id) do
      {:ok, _proposal} ->
        {:noreply,
         socket
         |> load_timeline()
         |> put_flash(:info, "Propuesta descartada.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "No se pudo descartar la propuesta.")}
    end
  end

  @impl true
  def handle_event("save_draft", %{"draft" => %{"body" => body}}, socket) do
    professional = socket.assigns.current_professional
    patient_id = socket.assigns.patient_id
    target_behavior_id = socket.assigns.target_behavior_id

    case ClinicalRecord.upsert_functional_analysis_draft(
           professional,
           patient_id,
           target_behavior_id,
           body
         ) do
      {:ok, _draft} ->
        draft_status = compute_draft_status(socket.assigns.draft_tombstoned_at, body)

        {:noreply,
         socket
         |> assign(:draft_form, to_form(%{"body" => body}, as: "draft"))
         |> assign(:draft_status, draft_status)
         |> put_flash(:info, "Borrador guardado.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "No se pudo guardar el borrador.")}
    end
  end

  @impl true
  def handle_event("insert_draft_structure", _params, socket) do
    {:noreply,
     assign(
       socket,
       :draft_form,
       to_form(%{"body" => FunctionalAnalysisDraft.default_structure()}, as: "draft")
     )}
  end

  @impl true
  def handle_info({:ai_proposals_ready, target_behavior_id}, socket) do
    if target_behavior_id == socket.assigns.target_behavior_id do
      {:noreply,
       socket
       |> assign(:generation_pending, false)
       |> load_timeline()}
    else
      {:noreply, socket}
    end
  end

  # The worker found the target behavior gone (deleted mid-generation, e.g. by
  # retention): the page cannot be served any more, so leave (GitHub #289).
  @impl true
  def handle_info({:ai_proposals_failed, reason}, socket)
      when reason in [:target_behavior_deleted, :not_found] do
    {:noreply, redirect_to_patients(socket, :not_found)}
  end

  def handle_info({:ai_proposals_failed, _reason}, socket) do
    {:noreply,
     socket
     |> assign(:generation_pending, false)
     |> put_flash(:error, "La generación de patrones de IA falló.")}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Ownership gate for mount (GitHub #289): the target behavior must belong
  # to the patient in the URL before any timeline data is read.
  defp load_review(professional, patient_id, target_behavior_id) do
    with {:ok, target_behavior} <-
           ClinicalRecord.get_target_behavior(professional, patient_id, target_behavior_id),
         {:ok, items} <-
           ClinicalRecord.review_timeline(professional, patient_id, target_behavior_id) do
      {:ok, target_behavior, items}
    end
  end

  defp load_timeline(socket) do
    professional = socket.assigns.current_professional
    patient_id = socket.assigns.patient_id
    target_behavior_id = socket.assigns.target_behavior_id

    case ClinicalRecord.review_timeline(professional, patient_id, target_behavior_id) do
      {:ok, items} ->
        evidence_count = Enum.count(items, &(&1.kind == :consultation_evidence))
        observation_count = Enum.count(items, &(&1.kind == :clinician_observation))
        proposal_count = Enum.count(items, &(&1.kind == :ai_proposal))

        socket
        |> assign(:evidence_count, evidence_count)
        |> assign(:observation_count, observation_count)
        |> assign(:proposal_count, proposal_count)
        |> assign(:has_sufficient_evidence, evidence_count > 0)
        |> assign(:timeline_index, timeline_index(items))
        |> stream(:timeline, items, reset: true)

      # Access or the target behavior itself is gone since mount: leave rather
      # than keep the previous (now stale) stream on screen (GitHub #289).
      {:error, :unauthorized} ->
        redirect_to_patients(socket, :unauthorized)

      {:error, :not_found} ->
        redirect_to_patients(socket, :not_found)

      {:error, _reason} ->
        socket
    end
  end

  defp reset_citation(socket) do
    socket
    |> assign(:citation_step, nil)
    |> assign(:evidence_sources, [])
    |> assign(:selected_evidence_source, nil)
    |> assign(:citation_excerpt, nil)
    |> assign(:citation_error, nil)
    |> assign(:citation_form, to_form(%{"excerpt" => ""}, as: "citation"))
  end

  defp redirect_to_patients(socket, :unauthorized) do
    socket
    |> put_flash(:error, "No estás autorizado para ver esta línea de tiempo clínica.")
    |> push_navigate(to: ~p"/patients")
  end

  defp redirect_to_patients(socket, :not_found) do
    socket
    |> put_flash(:error, "La conducta objetivo no existe o no pertenece a este paciente.")
    |> push_navigate(to: ~p"/patients")
  end

  defp timeline_index(items), do: Map.new(items, &{&1.id, &1})

  defp compute_draft_status(tombstoned_at, body) do
    cond do
      tombstoned_at != nil -> :tombstoned
      is_nil(body) or String.trim(body) == "" -> :empty
      true -> :saved
    end
  end

  defp draft_status_label(:empty), do: "Borrador vacío"
  defp draft_status_label(:saved), do: "Guardado"
  defp draft_status_label(:tombstoned), do: "Eliminado legalmente"

  # Content inside a `phx-update="stream"` container only re-renders on an
  # explicit stream operation (insert/delete/reset) — it does not
  # automatically react to a change in an *outer* assign like
  # `@editing_proposal_id` referenced inside the per-item template.
  # `start_edit_proposal`/`cancel_edit_proposal` toggle that outer assign
  # without touching the timeline data itself, so both the previously- and
  # newly-affected items must be explicitly re-streamed with `stream_insert/3`
  # (same dom_id, same data) to force their `<li>` to actually re-render.
  defp reinsert_timeline_item(socket, nil), do: socket

  defp reinsert_timeline_item(socket, id) do
    case Map.get(socket.assigns.timeline_index, id) do
      nil -> socket
      item -> stream_insert(socket, :timeline, item)
    end
  end

  defp review_item_class(:consultation_evidence), do: "review-item--evidence"
  defp review_item_class(:clinician_observation), do: "review-item--observation"
  defp review_item_class(:ai_proposal), do: "review-item--proposal"
  defp review_item_class(:legally_deleted), do: "review-item--tombstone"

  defp kind_label(:consultation_evidence), do: "Evidencia citada"
  defp kind_label(:clinician_observation), do: "Observación del clínico"
  defp kind_label(:ai_proposal), do: "Propuesta de IA"
  defp kind_label(:legally_deleted), do: "Registro eliminado legalmente"

  defp status_label("pending"), do: "pendiente"
  defp status_label("edited"), do: "editada"
  defp status_label("accepted"), do: "aceptada"
  defp status_label("discarded"), do: "descartada"
  defp status_label(_), do: "desconocido"

  defp source_label(:unavailable), do: "Fuente no disponible"

  defp source_label({:ok, %{kind: :clinical_note, occurred_at: occurred_at}}) do
    "Nota clínica · #{format_datetime(occurred_at)}"
  end

  defp source_label({:ok, %{kind: :message, reference: reference}}) do
    "Mensaje (#{reference[:behavior_type]}/#{reference[:direction]})"
  end

  defp source_label(_), do: "Fuente no disponible"

  defp evidence_source_type_label(%{kind: :clinical_note}), do: "Nota clínica"

  defp evidence_source_type_label(%{kind: :message, direction: "inbound"}),
    do: "Mensaje entrante"

  defp evidence_source_type_label(%{kind: :message, direction: "outbound"}),
    do: "Mensaje saliente"

  defp evidence_source_type_label(%{kind: :message}), do: "Mensaje"

  defp evidence_source_provenance(%{kind: :message, behavior_type: "spontaneous"}),
    do: "espontáneo"

  defp evidence_source_provenance(%{kind: :message, behavior_type: "elicited"}),
    do: "provocado"

  defp evidence_source_provenance(%{kind: :message, behavior_type: "crisis_bypass"}),
    do: "respuesta de crisis"

  defp evidence_source_provenance(%{kind: :message, behavior_type: behavior_type}),
    do: behavior_type || "sin clasificación"

  defp evidence_source_provenance(%{kind: :clinical_note}), do: "registro profesional"

  defp format_datetime(%DateTime{} = datetime) do
    Calendar.strftime(datetime, "%d/%m/%Y %H:%M")
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="review">
      <.header>
        Revisión clínica
        <:subtitle>
          Cronología de evidencia, observaciones y propuestas de IA para esta conducta objetivo.
        </:subtitle>

        <:actions>
          <button
            type="button"
            id="cite-evidence-header"
            phx-click="open_evidence_citation"
            class={[
              "button-primary--sm",
              if(@has_sufficient_evidence, do: "button-secondary", else: "button-primary")
            ]}
          >
            <.icon name="hero-magnifying-glass" class="size-4" /> Citar evidencia
          </button>
          <div class="review-ai-action">
            <button
              type="button"
              id="suggest-patterns"
              phx-click="suggest_patterns"
              disabled={@generation_pending or !@has_sufficient_evidence}
              class={[
                "button-secondary--sm",
                if(@has_sufficient_evidence and @proposal_count == 0,
                  do: "button-primary",
                  else: "button-secondary"
                )
              ]}
            >
              <.icon name="hero-presentation-chart-line" class="size-4" style="margin-right:6px;" /> {if @generation_pending,
                do: "Generando patrones…",
                else: "Sugerir patrones (IA)"}
            </button>
            <p
              :if={!@has_sufficient_evidence and !@generation_pending}
              id="ai-insufficient-evidence-hint"
              class="review-ai-hint"
            >
              Requiere evidencia citada para sugerir patrones.
            </p>
          </div>
        </:actions>
      </.header>

      <section
        class="clinical-workbench-header"
        id="clinical-workbench-header"
        aria-label="Contexto clínico"
      >
        <div class="clinical-workbench-header__info">
          <div class="clinical-workbench-header__patient">
            <span class="clinical-workbench-header__label">Paciente</span>
            <strong class="clinical-workbench-header__value" id="patient-alias">
              {@patient_alias}
            </strong>
          </div>

          <div class="clinical-workbench-header__behavior">
            <span class="clinical-workbench-header__label">Conducta objetivo</span>
            <span class="clinical-workbench-header__value" id="target-behavior-description">
              {@target_behavior_description}
            </span>
          </div>
        </div>

        <div class="stat-strip" id="review-stat-strip">
          <div class="stat-tile" id="stat-evidence">
            <div class="stat-tile__label">Evidencias citadas</div>

            <div class="stat-tile__value">{@evidence_count}</div>

            <div class="stat-tile__desc">Citas de consultas</div>
          </div>

          <div class="stat-tile" id="stat-observations">
            <div class="stat-tile__label">Observaciones</div>

            <div class="stat-tile__value">{@observation_count}</div>

            <div class="stat-tile__desc">Notas del profesional</div>
          </div>

          <div class="stat-tile" id="stat-proposals">
            <div class="stat-tile__label">Propuestas IA</div>

            <div class="stat-tile__value">{@proposal_count}</div>

            <div class="stat-tile__desc">Hipótesis sugeridas</div>
          </div>

          <div class="stat-tile" id="stat-draft">
            <div class="stat-tile__label">Estado del borrador</div>

            <div class="stat-tile__value stat-tile__value--status" id="draft-status-label">
              {draft_status_label(@draft_status)}
            </div>

            <div class="stat-tile__desc">Análisis funcional</div>
          </div>
        </div>
      </section>

      <div
        :if={@evidence_count == 0 or @proposal_count == 0}
        id="evidence-guide"
        class="empty-state empty-state--compact review-empty-banner"
      >
        <%= if @evidence_count == 0 do %>
          <.icon name="hero-magnifying-glass" class="empty-state__icon" />
          <p class="empty-state__title">Fundamentá el análisis con evidencia clínica</p>
          <p class="empty-state__text">
            Citá un fragmento exacto de una nota o mensaje del paciente. Después podrás solicitar sugerencias de patrones sin ocultar ni reemplazar tu borrador clínico.
          </p>
          <button
            type="button"
            id="cite-evidence-guide"
            phx-click="open_evidence_citation"
            class="button-primary button-primary--sm"
          >
            <.icon name="hero-magnifying-glass" class="size-4" /> Citar evidencia
          </button>
        <% else %>
          <.icon name="hero-presentation-chart-line" class="empty-state__icon" />
          <p class="empty-state__title">Convertí la evidencia en hipótesis de trabajo</p>
          <p class="empty-state__text">
            Ya hay evidencia citada. Solicitá sugerencias de patrones para revisarlas antes de incorporarlas al borrador clínico.
          </p>
          <button
            type="button"
            id="suggest-patterns-guide"
            phx-click="suggest_patterns"
            disabled={@generation_pending}
            class="button-primary button-primary--sm"
          >
            <.icon name="hero-presentation-chart-line" class="size-4" /> {if @generation_pending,
              do: "Generando patrones…",
              else: "Sugerir patrones (IA)"}
          </button>
        <% end %>
      </div>

      <section :if={@citation_step} id="evidence-citation-flow" class="review-observation">
        <div class="review-item__meta">
          <h2 class="pt-h2">Citar evidencia</h2>
          <span class="badge badge--uncited">
            Paso {if @citation_step == :select,
              do: "1",
              else: if(@citation_step == :excerpt, do: "2", else: "3")} de 3
          </span>
        </div>

        <p :if={@citation_error} id="evidence-citation-error" class="field__error">
          {@citation_error}
        </p>

        <div :if={@citation_step == :select} id="evidence-source-list">
          <p :if={@evidence_sources == []} class="pt-muted">
            No hay notas ni mensajes disponibles para citar.
          </p>
          <button
            :for={source <- @evidence_sources}
            type="button"
            id={"evidence-source-#{source.id}"}
            phx-click="select_evidence_source"
            phx-value-id={source.id}
            phx-value-kind={source.kind}
            class="review-item button-secondary"
          >
            <strong>{evidence_source_type_label(source)}</strong>
            <span>{format_datetime(source.occurred_at)}</span>
            <span>{evidence_source_provenance(source)}</span>
          </button>
        </div>

        <div :if={@citation_step == :excerpt and @selected_evidence_source}>
          <div class="review-item__meta">
            <strong>{evidence_source_type_label(@selected_evidence_source)}</strong>
            <span>{format_datetime(@selected_evidence_source.occurred_at)}</span>
            <span>{evidence_source_provenance(@selected_evidence_source)}</span>
          </div>
          <p id="evidence-source-content" class="review-item__text">
            {@selected_evidence_source.content}
          </p>
          <.form
            for={@citation_form}
            id="evidence-excerpt-form"
            phx-submit="prepare_evidence_citation"
          >
            <.input
              field={@citation_form[:excerpt]}
              type="textarea"
              label="Fragmento exacto"
              placeholder="Copiá un fragmento exacto de la fuente"
            />
            <div class="form-actions">
              <button type="submit" class="button-primary button-primary--sm">
                Revisar cita
              </button>
            </div>
          </.form>
        </div>

        <div
          :if={@citation_step == :confirm and @selected_evidence_source}
          id="evidence-citation-confirmation"
        >
          <p><strong>Verificá la cita antes de guardarla.</strong></p>
          <dl>
            <dt>Fuente</dt>
            <dd id="citation-confirm-source">
              {evidence_source_type_label(@selected_evidence_source)} · {evidence_source_provenance(
                @selected_evidence_source
              )}
            </dd>
            <dt>Fecha</dt>
            <dd id="citation-confirm-date">
              {format_datetime(@selected_evidence_source.occurred_at)}
            </dd>
            <dt>Fragmento exacto</dt>
            <dd id="citation-confirm-excerpt">{@citation_excerpt}</dd>
            <dt>Destino</dt>
            <dd id="citation-confirm-destination">
              Conducta objetivo: {@target_behavior_description}
            </dd>
          </dl>
          <button
            type="button"
            id="confirm-evidence-citation"
            phx-click="confirm_evidence_citation"
            class="button-primary button-primary--sm"
          >
            Confirmar cita
          </button>
        </div>

        <div class="form-actions">
          <button
            type="button"
            id="cancel-evidence-citation"
            phx-click="cancel_evidence_citation"
            class="button-secondary button-secondary--sm"
          >
            Cancelar
          </button>
        </div>
      </section>

      <ol id="review-timeline" phx-update="stream" class="review-timeline">
        <li
          :for={{dom_id, item} <- @streams.timeline}
          id={dom_id}
          class={["review-item", review_item_class(item.kind)]}
        >
          <div class="review-item__meta">
            <span class="review-item__kind">{kind_label(item.kind)}</span>
            <span class="review-item__time">{format_datetime(item.occurred_at)}</span>
            <span :if={item.kind == :clinician_observation} class="badge badge--uncited">
              Sin cita — agregado por el clínico
            </span>
            <span
              :if={item.kind == :ai_proposal}
              class={["badge", "badge--provisional", "badge--status-#{item.status}"]}
            >
              Propuesta de IA (provisional) · {status_label(item.status)}
            </span>
          </div>

          <p :if={item.kind != :legally_deleted} class="review-item__text">{item.text}</p>

          <p
            :if={item.kind == :legally_deleted}
            class="review-item__text review-item__text--tombstone"
          >
            <.icon name="hero-lock-closed" class="size-3" />
            Eliminado legalmente el {format_datetime(item.occurred_at)}
          </p>

          <div :if={item.kind == :consultation_evidence} class="review-item__source">
            <.icon name="hero-magnifying-glass" class="size-3" /> {source_label(item.source)}
          </div>

          <div
            :if={item.kind == :ai_proposal and item.status in ["pending", "edited"]}
            class="review-item__actions"
          >
            <button
              :if={@editing_proposal_id != item.id}
              type="button"
              phx-click="start_edit_proposal"
              phx-value-id={item.id}
              class="link-button"
            >
              Editar
            </button>
            <button
              type="button"
              phx-click="accept_proposal"
              phx-value-id={item.id}
              class="button-primary button-primary--sm"
            >
              Aceptar
            </button>
            <button
              type="button"
              phx-click="discard_proposal"
              phx-value-id={item.id}
              data-confirm="¿Estás seguro de que deseas descartar esta propuesta de IA?"
              class="button-secondary button-secondary--sm"
            >
              Descartar
            </button>
          </div>

          <.form
            :if={@editing_proposal_id == item.id}
            for={to_form(%{"text" => item.text}, as: "proposal")}
            id={"edit-proposal-#{item.id}"}
            phx-submit="save_edit_proposal"
          >
            <input type="hidden" name="proposal_id" value={item.id} />
            <.input type="textarea" name="proposal[text]" value={item.text} label="Editar propuesta" />
            <div class="form-actions">
              <button type="submit" class="button-primary button-primary--sm">Guardar edición</button>
              <button
                type="button"
                phx-click="cancel_edit_proposal"
                class="button-secondary button-secondary--sm"
              >
                Cancelar
              </button>
            </div>
          </.form>
        </li>
      </ol>

      <div :if={map_size(@timeline_index) == 0} class="empty-state">
        <.icon name="hero-chat-bubble-left-right" class="empty-state__icon" />
        <p class="empty-state__title">Todavía no hay entradas en esta línea de tiempo</p>
      </div>

      <div class="review-observation">
        <h2 class="pt-h2">Agregar observación clínica</h2>

        <div
          :if={@observation_count == 0}
          id="empty-observations"
          class="empty-state empty-state--compact mb-4"
        >
          <.icon name="hero-chat-bubble-left-right" class="empty-state__icon" />
          <p class="empty-state__title">Sin observaciones del clínico</p>

          <p class="empty-state__text">
            No has registrado observaciones directas para esta conducta. Puedes agregar tu primera observación en el formulario a continuación.
          </p>
        </div>

        <.form for={@observation_form} id="observation-form" phx-submit="add_observation">
          <.input field={@observation_form[:body]} type="textarea" label="Observación (sin cita)" />
          <div class="form-actions">
            <button type="submit" class="button-primary button-primary--sm">
              Agregar observación
            </button>
          </div>
        </.form>
      </div>

      <div class="review-draft">
        <h2 class="pt-h2">Borrador de análisis funcional</h2>

        <div :if={@draft_tombstoned_at} id="draft-tombstone" class="tombstone-note">
          <.icon name="hero-lock-closed" class="size-3" />
          Eliminado legalmente el {format_datetime(@draft_tombstoned_at)}
        </div>

        <div
          :if={@draft_status == :empty and !@draft_tombstoned_at}
          id="empty-draft"
          class="empty-state empty-state--compact mb-4"
        >
          <.icon name="hero-information-circle" class="empty-state__icon" />
          <p class="empty-state__title">Sin borrador de análisis funcional</p>

          <p class="empty-state__text">
            El borrador está vacío. Puedes redactar directamente tu hipótesis o aceptar propuestas sugeridas para construirlas aquí.
          </p>
        </div>

        <.form :if={!@draft_tombstoned_at} for={@draft_form} id="draft-form" phx-submit="save_draft">
          <.input
            field={@draft_form[:body]}
            type="textarea"
            label="Análisis funcional (editable)"
            placeholder={FunctionalAnalysisDraft.default_structure()}
          />
          <div class="form-actions">
            <button
              :if={@draft_form[:body].value in [nil, ""]}
              type="button"
              id="insert-draft-structure-button"
              phx-click="insert_draft_structure"
              class="button-secondary button-secondary--sm"
            >
              Cargar estructura clínica inicial
            </button>
            <button type="submit" class="button-primary button-primary--sm">Guardar borrador</button>
          </div>
        </.form>
      </div>
    </div>
    """
  end
end
