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

  alias Alethea.AI.Chains.FunctionalAnalysisDraftChain
  alias Alethea.AI.Sanitizer
  alias Alethea.ClinicalRecord
  alias Alethea.ClinicalRecord.FunctionalAnalysisContent
  alias Alethea.ClinicalRecord.FunctionalAnalysisDraft
  alias Alethea.ClinicalRecord.FunctionalAnalysisVersion
  alias AletheaWeb.TargetBehaviorLive.AudioMarker
  alias Phoenix.LiveView.AsyncResult

  # Mirrors the editable form fieldset labels (:2398-2497) for the read-only
  # version view (GitHub #364). Kept as a function, not `@foo` usage inside
  # `~H`, since that always reads `assigns.foo`, never a module attribute.
  @version_view_sections_data [
    {"E", "Antecedentes",
     [
       {:antecedents_distal, "Antecedentes distales"},
       {:antecedents_immediate, "Antecedentes inmediatos"}
     ]},
    {"O", "Organismo",
     [
       {:organism_sleep, "Sueño"},
       {:organism_pain_or_discomfort, "Dolor o malestar"},
       {:organism_hunger_or_nutrition, "Hambre o nutrición"},
       {:organism_learning_history, "Historia de aprendizaje"}
     ]},
    {"R", "Respuesta",
     [
       {:response_physiological, "Fisiológica"},
       {:response_cognitive, "Cognitiva"},
       {:response_motor, "Motora o conductual"}
     ]},
    {"C", "Consecuencias",
     [
       {:consequences_short_term, "A corto plazo"},
       {:consequences_long_term, "A largo plazo"}
     ]}
  ]

  defp version_view_sections, do: @version_view_sections_data

  @search_source_filters [
    %{id: "all", label: "Todos"},
    %{id: "telegram", label: "Telegram"},
    %{id: "notes", label: "Notas"},
    %{id: "sessions", label: "Sesiones"}
  ]

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

        {functional_analysis_content, draft_tombstoned_at, draft_lock_version} =
          case ClinicalRecord.get_functional_analysis_draft(
                 professional,
                 patient_id,
                 target_behavior_id
               ) do
            {:ok, nil} ->
              {%FunctionalAnalysisContent{}, nil, 0}

            {:ok, {:legally_deleted, deleted_at}} ->
              {%FunctionalAnalysisContent{}, deleted_at, nil}

            {:ok, %FunctionalAnalysisDraft{body: body, lock_version: lv}} ->
              {_format, content} = FunctionalAnalysisContent.parse(body)
              {content, nil, lv}

            {:error, _reason} ->
              {%FunctionalAnalysisContent{}, nil, 0}
          end

        draft_status = compute_draft_status(draft_tombstoned_at, functional_analysis_content)
        initial_content_params = content_params(functional_analysis_content)

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
          |> assign(:functional_analysis_lock_version, draft_lock_version)
          |> assign(:last_saved_functional_analysis_params, initial_content_params)
          |> assign(:autosave_seq, 0)
          |> assign(:generation_pending, false)
          |> assign(:draft_generation_pending, false)
          |> assign(:editing_proposal_id, nil)
          |> assign(:active_input_tab, :evidence)
          |> assign(:observation_form_open, false)
          |> assign(:citation_step, nil)
          |> assign(:evidence_sources, [])
          |> assign(:selected_evidence_source, nil)
          |> assign(:citation_excerpt, nil)
          |> assign(:citation_error, nil)
          |> assign(:citation_form, to_form(%{"excerpt" => ""}, as: "citation"))
          |> assign(:trimming_candidate_id, nil)
          |> assign(:trim_form, nil)
          |> assign(:trim_error, nil)
          |> assign(:search_query, "")
          |> assign(:search_form, to_form(%{"query" => ""}, as: "search"))
          |> assign(:search_source_filter, "all")
          |> assign(:search_source_filters, @search_source_filters)
          |> assign(:cited_chunk_ids, MapSet.new())
          |> assign(
            :search_results,
            Phoenix.LiveView.AsyncResult.ok(%Phoenix.LiveView.AsyncResult{}, [])
          )
          |> assign(:timeline_index, timeline_index(items))
          |> assign(:observation_form, to_form(%{"body" => ""}, as: "observation"))
          |> assign(
            :functional_analysis_form,
            to_form(initial_content_params, as: "functional_analysis")
          )
          |> assign(:draft_tombstoned_at, draft_tombstoned_at)
          |> assign(:version_form, version_form(""))
          |> assign(
            :version_summaries,
            load_version_summaries(professional, patient_id, target_behavior_id)
          )
          |> assign(:selected_version, nil)
          |> assign(:selected_version_content, nil)
          |> assign(:continue_confirmation_pending, false)
          |> assign_async(:suggested_candidates, fn ->
            case ClinicalRecord.suggest_evidence_candidates(
                   professional,
                   patient_id,
                   target_behavior_id,
                   limit: 5
                 ) do
              {:ok, candidates} -> {:ok, %{suggested_candidates: candidates}}
              {:error, reason} -> {:error, reason}
            end
          end)
          |> stream(:timeline, items)

        {:ok, socket}

      {:error, :unauthorized} ->
        {:ok, redirect_to_patients(socket, :unauthorized)}

      {:error, :not_found} ->
        {:ok, redirect_to_patients(socket, :not_found)}
    end
  end

  @impl true
  def handle_event("search_evidence", %{"search" => %{"query" => query}}, socket) do
    query = String.trim(query)

    if query == "" do
      {:noreply, reset_evidence_search(socket)}
    else
      {:noreply,
       socket
       |> assign(:search_query, query)
       |> assign(:search_form, to_form(%{"query" => query}, as: "search"))
       |> trigger_evidence_search(query, socket.assigns.search_source_filter)}
    end
  end

  @impl true
  def handle_event("filter_search_source", %{"source" => source}, socket) do
    source = normalize_search_source_filter(source)
    socket = assign(socket, :search_source_filter, source)

    if socket.assigns.search_query == "" do
      {:noreply, socket}
    else
      {:noreply, trigger_evidence_search(socket, socket.assigns.search_query, source)}
    end
  end

  @impl true
  def handle_event("clear_evidence_search", _params, socket) do
    {:noreply, reset_evidence_search(socket)}
  end

  @impl true
  def handle_event("select_input_tab", %{"tab" => tab}, socket)
      when tab in ["evidence", "observations", "proposals"] do
    {:noreply, assign(socket, :active_input_tab, String.to_existing_atom(tab))}
  end

  @impl true
  def handle_event("navigate_input_tab", %{"key" => key}, socket)
      when key in ["ArrowLeft", "ArrowRight"] do
    next_tab = adjacent_input_tab(socket.assigns.active_input_tab, key)

    {:noreply,
     socket
     |> assign(:active_input_tab, next_tab)
     |> push_event("focus_input_tab", %{id: input_tab_id(next_tab)})}
  end

  def handle_event("navigate_input_tab", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("toggle_observation_form", _params, socket) do
    {:noreply, assign(socket, :observation_form_open, !socket.assigns.observation_form_open)}
  end

  @impl true
  def handle_event("cancel_observation", _params, socket) do
    {:noreply,
     socket
     |> assign(:observation_form_open, false)
     |> assign(:observation_form, to_form(%{"body" => ""}, as: "observation"))}
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
         |> assign(:observation_form_open, false)
         |> assign(:active_input_tab, :observations)
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
  def handle_event("cite_suggested_candidate", %{"id" => chunk_id}, socket) do
    professional = socket.assigns.current_professional
    patient_id = socket.assigns.patient_id
    target_behavior_id = socket.assigns.target_behavior_id

    candidate = find_citable_candidate(socket.assigns.suggested_candidates, chunk_id)

    result =
      with %{source_resource_type: resource_type} = candidate when not is_nil(candidate) <-
             candidate,
           {:ok, source_kind} <- citation_source_kind(resource_type) do
        ClinicalRecord.cite_evidence_source(
          professional,
          patient_id,
          target_behavior_id,
          citation_attrs(candidate, source_kind, candidate.content)
        )
      else
        _reason -> {:error, :invalid_suggestion}
      end

    case result do
      {:ok, _evidence} ->
        {:noreply,
         socket
         |> mark_search_result_cited(chunk_id)
         |> remove_suggested_candidate(chunk_id)
         |> load_timeline()
         |> put_flash(:info, "Evidencia citada correctamente.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "No se pudo citar la sugerencia de evidencia.")}
    end
  end

  @impl true
  def handle_event("open_trim_candidate", %{"id" => chunk_id}, socket) do
    candidate = find_citable_candidate(socket.assigns.suggested_candidates, chunk_id)

    if candidate do
      {:noreply,
       socket
       |> assign(:trimming_candidate_id, chunk_id)
       |> assign(:trim_form, to_form(%{"excerpt" => candidate.content}, as: "trim"))
       |> assign(:trim_error, nil)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("cancel_trim_candidate", _params, socket) do
    {:noreply,
     socket
     |> assign(:trimming_candidate_id, nil)
     |> assign(:trim_form, nil)
     |> assign(:trim_error, nil)}
  end

  @impl true
  def handle_event("confirm_trimmed_candidate", %{"trim" => trim_params}, socket) do
    raw_excerpt = Map.get(trim_params, "excerpt", "")
    professional = socket.assigns.current_professional
    patient_id = socket.assigns.patient_id
    target_behavior_id = socket.assigns.target_behavior_id
    chunk_id = socket.assigns.trimming_candidate_id

    candidate = find_citable_candidate(socket.assigns.suggested_candidates, chunk_id)
    trimmed_excerpt = String.trim(raw_excerpt || "")

    cond do
      is_nil(candidate) ->
        {:noreply,
         socket
         |> assign(:trimming_candidate_id, nil)
         |> assign(:trim_form, nil)
         |> assign(:trim_error, nil)
         |> put_flash(:error, "No se encontró la sugerencia a recortar.")}

      trimmed_excerpt == "" ->
        {:noreply,
         socket
         |> assign(:trim_form, to_form(%{"excerpt" => raw_excerpt}, as: "trim"))
         |> assign(:trim_error, "Ingresá el fragmento exacto que querés citar.")}

      not String.contains?(candidate.content, trimmed_excerpt) ->
        {:noreply,
         socket
         |> assign(:trim_form, to_form(%{"excerpt" => raw_excerpt}, as: "trim"))
         |> assign(:trim_error, "El fragmento debe coincidir exactamente con la fuente.")}

      true ->
        result =
          with %{source_resource_type: resource_type} <- candidate,
               {:ok, source_kind} <- citation_source_kind(resource_type) do
            ClinicalRecord.cite_evidence_source(
              professional,
              patient_id,
              target_behavior_id,
              citation_attrs(candidate, source_kind, trimmed_excerpt)
            )
          else
            _reason -> {:error, :invalid_suggestion}
          end

        case result do
          {:ok, _evidence} ->
            {:noreply,
             socket
             |> mark_search_result_cited(chunk_id)
             |> remove_suggested_candidate(chunk_id)
             |> assign(:trimming_candidate_id, nil)
             |> assign(:trim_form, nil)
             |> assign(:trim_error, nil)
             |> load_timeline()
             |> put_flash(:info, "Evidencia citada correctamente.")}

          {:error, :excerpt_not_found} ->
            {:noreply,
             socket
             |> assign(:trim_form, to_form(%{"excerpt" => raw_excerpt}, as: "trim"))
             |> assign(:trim_error, "El fragmento debe coincidir exactamente con la fuente.")}

          {:error, _reason} ->
            {:noreply,
             socket
             |> assign(:trim_form, to_form(%{"excerpt" => raw_excerpt}, as: "trim"))
             |> assign(:trim_error, "No se pudo citar la sugerencia de evidencia.")}
        end
    end
  end

  @impl true
  def handle_event("cite_search_result", %{"id" => chunk_id}, socket) do
    professional = socket.assigns.current_professional
    patient_id = socket.assigns.patient_id
    target_behavior_id = socket.assigns.target_behavior_id

    candidate = find_citable_candidate(socket.assigns.search_results, chunk_id)

    result =
      with %{source_resource_type: resource_type} = candidate when not is_nil(candidate) <-
             candidate,
           {:ok, source_kind} <- citation_source_kind(resource_type) do
        ClinicalRecord.cite_evidence_source(
          professional,
          patient_id,
          target_behavior_id,
          citation_attrs(candidate, source_kind, candidate.content)
        )
      else
        _reason -> {:error, :invalid_search_result}
      end

    case result do
      {:ok, _evidence} ->
        {:noreply,
         socket
         |> mark_search_result_cited(chunk_id)
         |> remove_suggested_candidate(chunk_id)
         |> load_timeline()
         |> put_flash(:info, "Evidencia citada correctamente.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "No se pudo citar el resultado de búsqueda.")}
    end
  end

  @impl true
  def handle_event("dismiss_suggested_candidate", %{"id" => chunk_id}, socket) do
    professional = socket.assigns.current_professional
    patient_id = socket.assigns.patient_id
    target_behavior_id = socket.assigns.target_behavior_id

    candidate = find_dismissable_candidate(socket.assigns.suggested_candidates, chunk_id)

    result =
      if candidate do
        ClinicalRecord.dismiss_evidence_suggestion(
          professional,
          patient_id,
          target_behavior_id,
          %{
            chunk_id: candidate.chunk_id,
            resource_type: to_string(candidate.source_resource_type)
          }
        )
      else
        {:error, :candidate_not_found}
      end

    case result do
      {:ok, _dismissal} ->
        {:noreply,
         socket
         |> remove_suggested_candidate(chunk_id)
         |> put_flash(:info, "Sugerencia descartada.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "No se pudo descartar la sugerencia de evidencia.")}
    end
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
    professional = socket.assigns.current_professional
    patient_id = socket.assigns.patient_id

    case ClinicalRecord.accept_ai_proposal(professional, patient_id, id) do
      {:ok, _proposal} ->
        {:noreply,
         socket
         |> load_timeline()
         |> put_flash(
           :info,
           "Propuesta aceptada. Permanece disponible para clasificación y ubicación manual."
         )}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "No se pudo aceptar la propuesta.")}
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

  # Forged/stale write while a version is selected: silent no-op (R5/AD3).
  @impl true
  def handle_event(
        "change_functional_analysis",
        _params,
        %{assigns: %{selected_version: %FunctionalAnalysisVersion{}}} = socket
      ) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("change_functional_analysis", %{"functional_analysis" => params}, socket) do
    current_values = functional_analysis_form_values(socket)
    merged_values = Map.merge(current_values, params)

    socket =
      assign(
        socket,
        :functional_analysis_form,
        to_form(merged_values, as: "functional_analysis")
      )

    cond do
      socket.assigns.draft_tombstoned_at != nil ->
        {:noreply, socket}

      params_equal?(merged_values, socket.assigns.last_saved_functional_analysis_params) ->
        {:noreply, socket}

      true ->
        {:noreply, schedule_functional_analysis_autosave(socket, merged_values)}
    end
  end

  # Forged/stale write while a version is selected: silent no-op (R5/AD3).
  @impl true
  def handle_event(
        "generate_functional_analysis_draft",
        _params,
        %{assigns: %{selected_version: %FunctionalAnalysisVersion{}}} = socket
      ) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("generate_functional_analysis_draft", _params, socket) do
    cond do
      socket.assigns.draft_tombstoned_at ->
        {:noreply, socket}

      socket.assigns.draft_generation_pending ->
        {:noreply, socket}

      not socket.assigns.has_sufficient_evidence ->
        {:noreply, put_flash(socket, :error, "No hay evidencia citada para generar el borrador.")}

      true ->
        professional = socket.assigns.current_professional
        patient_id = socket.assigns.patient_id
        target_behavior_id = socket.assigns.target_behavior_id

        {:noreply,
         socket
         |> assign(:draft_generation_pending, true)
         |> start_async(:functional_analysis_draft, fn ->
           with {:ok, items} <-
                  ClinicalRecord.review_timeline(professional, patient_id, target_behavior_id),
                %{texts: evidence} = selected when evidence != [] <-
                  cited_sanitized_evidence(items),
                {:ok, generated} <-
                  functional_analysis_draft_chain().run(%{sanitized_evidence: evidence}) do
             {:ok, %{generated: generated, evidence_ids: selected.ids}}
           else
             %{texts: []} -> {:error, :no_cited_evidence}
             error -> error
           end
         end)}
    end
  end

  # Forged/stale write while a version is selected: silent no-op (R5/AD3).
  @impl true
  def handle_event(
        "save_functional_analysis",
        _params,
        %{assigns: %{selected_version: %FunctionalAnalysisVersion{}}} = socket
      ) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("save_functional_analysis", %{"functional_analysis" => params}, socket) do
    professional = socket.assigns.current_professional
    patient_id = socket.assigns.patient_id
    target_behavior_id = socket.assigns.target_behavior_id
    expected_lock_version = socket.assigns.functional_analysis_lock_version

    case ClinicalRecord.upsert_functional_analysis_content(
           professional,
           patient_id,
           target_behavior_id,
           params,
           expected_lock_version: expected_lock_version
         ) do
      {:ok, draft} ->
        content = FunctionalAnalysisContent.new(params)
        content_map = content_params(content)

        {:noreply,
         socket
         |> assign(:autosave_seq, socket.assigns.autosave_seq + 1)
         |> assign(
           :functional_analysis_form,
           to_form(content_map, as: "functional_analysis")
         )
         |> assign(:functional_analysis_lock_version, draft.lock_version)
         |> assign(:last_saved_functional_analysis_params, content_map)
         |> assign(:draft_status, compute_draft_status(nil, content))
         |> put_flash(:info, "Análisis funcional guardado.")}

      {:error, :conflict} ->
        {:noreply,
         socket
         |> assign(:draft_status, :conflict)
         |> put_flash(:error, "Conflicto: otra sesión modificó el borrador.")}

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(:draft_status, :save_failed)
         |> put_flash(:error, "No se pudo guardar el análisis funcional.")}
    end
  end

  # Forged/stale write while a version is selected: silent no-op (R5/AD3).
  @impl true
  def handle_event(
        "register_functional_analysis_version",
        _params,
        %{assigns: %{selected_version: %FunctionalAnalysisVersion{}}} = socket
      ) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("register_functional_analysis_version", params, socket) do
    note = version_note_param(params)
    socket = assign(socket, :version_form, version_form(note))

    case version_registration_blocker(socket, note) do
      nil -> register_functional_analysis_version(socket, note)
      {:flash, message} -> {:noreply, put_flash(socket, :error, message)}
      {:note, message} -> {:noreply, assign(socket, :version_form, version_form(note, message))}
    end
  end

  # Pending AI generation blocks selection itself, forged or not (AD4/R8/L5).
  @impl true
  def handle_event(
        "select_functional_analysis_version",
        _params,
        %{assigns: %{draft_generation_pending: true}} = socket
      ) do
    {:noreply, socket}
  end

  def handle_event("select_functional_analysis_version", %{"id" => "working-draft"}, socket) do
    {:noreply, put_selected_version(socket, nil, nil)}
  end

  def handle_event("select_functional_analysis_version", %{"id" => id}, socket) do
    professional = socket.assigns.current_professional
    patient_id = socket.assigns.patient_id
    target_behavior_id = socket.assigns.target_behavior_id

    case ClinicalRecord.get_functional_analysis_version(
           professional,
           patient_id,
           target_behavior_id,
           id
         ) do
      {:ok, version} ->
        {_format, content} = FunctionalAnalysisContent.parse(version.body)

        {:noreply, put_selected_version(socket, version, content)}

      {:error, :unauthorized} ->
        {:noreply, redirect_to_patients(socket, :unauthorized)}

      {:error, _reason} ->
        socket
        |> put_selected_version(nil, nil)
        |> put_flash(:error, "La versión no está disponible.")
        |> relist_version_summaries()
    end
  end

  @impl true
  def handle_event("request_continue_from_version", _params, socket) do
    case continuation_blocker(socket.assigns) do
      :noop ->
        {:noreply, socket}

      {:flash, message} ->
        {:noreply, put_flash(socket, :error, message)}

      nil ->
        if working_form_blank?(socket) do
          apply_version_continuation(socket)
        else
          {:noreply, assign(socket, :continue_confirmation_pending, true)}
        end
    end
  end

  @impl true
  def handle_event(
        "confirm_continue_from_version",
        _params,
        %{assigns: %{continue_confirmation_pending: true}} = socket
      ) do
    case continuation_blocker(socket.assigns) do
      :noop ->
        {:noreply, socket}

      {:flash, message} ->
        {:noreply,
         socket
         |> put_flash(:error, message)
         |> assign(:continue_confirmation_pending, false)}

      nil ->
        apply_version_continuation(socket)
    end
  end

  # No pending confirmation: a forged confirm must not bypass the
  # replacement acknowledgement (AD7).
  def handle_event("confirm_continue_from_version", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("cancel_continue_from_version", _params, socket) do
    {:noreply, assign(socket, :continue_confirmation_pending, false)}
  end

  @impl true
  def handle_async(
        :functional_analysis_draft,
        {:ok, {:ok, %{generated: generated, evidence_ids: evidence_ids}}},
        socket
      ) do
    professional = socket.assigns.current_professional
    patient_id = socket.assigns.patient_id
    target_behavior_id = socket.assigns.target_behavior_id

    with {:ok, items} <-
           ClinicalRecord.review_timeline(professional, patient_id, target_behavior_id),
         :ok <- cited_evidence_still_live(evidence_ids, items),
         {:ok, current_content} <-
           ClinicalRecord.get_functional_analysis_content(
             professional,
             patient_id,
             target_behavior_id
           ) do
      case current_content do
        {:legally_deleted, deleted_at} ->
          {:noreply,
           socket
           |> assign(:draft_generation_pending, false)
           |> assign(:draft_tombstoned_at, deleted_at)
           |> assign(:draft_status, :tombstoned)
           |> put_flash(:error, "El borrador fue eliminado y no se restauró.")}

        _content ->
          values = merge_generated_draft(functional_analysis_form_values(socket), generated)

          {:noreply,
           socket
           |> assign(:draft_generation_pending, false)
           |> assign(
             :functional_analysis_form,
             to_form(values, as: "functional_analysis")
           )
           |> put_flash(:info, "Borrador E-O-R-C generado. Revisalo antes de guardar.")}
      end
    else
      {:error, :unauthorized} ->
        {:noreply, redirect_to_patients(socket, :unauthorized)}

      {:error, :not_found} ->
        {:noreply, redirect_to_patients(socket, :not_found)}

      {:error, :stale_cited_evidence} ->
        {:noreply,
         socket
         |> assign(:draft_generation_pending, false)
         |> put_flash(:error, "La evidencia citada cambió durante la generación.")}

      {:error, _reason} ->
        {:noreply, draft_generation_error(socket)}
    end
  end

  def handle_async(:functional_analysis_draft, {:ok, {:error, :unauthorized}}, socket) do
    {:noreply, redirect_to_patients(socket, :unauthorized)}
  end

  def handle_async(:functional_analysis_draft, {:ok, {:error, :not_found}}, socket) do
    {:noreply, redirect_to_patients(socket, :not_found)}
  end

  def handle_async(:functional_analysis_draft, _result, socket) do
    {:noreply, draft_generation_error(socket)}
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

  @impl true
  def handle_info({:perform_autosave, params, seq}, socket) do
    if seq == socket.assigns.autosave_seq and is_nil(socket.assigns.draft_tombstoned_at) do
      professional = socket.assigns.current_professional
      patient_id = socket.assigns.patient_id
      target_behavior_id = socket.assigns.target_behavior_id
      expected_lock_version = socket.assigns.functional_analysis_lock_version

      case ClinicalRecord.upsert_functional_analysis_content(
             professional,
             patient_id,
             target_behavior_id,
             params,
             expected_lock_version: expected_lock_version
           ) do
        {:ok, draft} ->
          content = FunctionalAnalysisContent.new(params)
          content_map = content_params(content)

          {:noreply,
           socket
           |> assign(:functional_analysis_lock_version, draft.lock_version)
           |> assign(:last_saved_functional_analysis_params, content_map)
           |> assign(:draft_status, compute_draft_status(nil, content))}

        {:error, :conflict} ->
          {:noreply,
           socket
           |> assign(:draft_status, :conflict)}

        {:error, _reason} ->
          {:noreply,
           socket
           |> assign(:draft_status, :save_failed)}
      end
    else
      {:noreply, socket}
    end
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

  # Mount is already authorized by `load_review/3`; any later error degrades
  # to an empty list rather than failing the whole page.
  defp load_version_summaries(professional, patient_id, target_behavior_id) do
    case ClinicalRecord.list_functional_analysis_version_summaries(
           professional,
           patient_id,
           target_behavior_id
         ) do
      {:ok, summaries} -> summaries
      {:error, _reason} -> []
    end
  end

  # AD5: an :unauthorized/:not_found here means access itself changed, so
  # redirect instead of showing a stale list.
  defp relist_version_summaries(socket) do
    professional = socket.assigns.current_professional
    patient_id = socket.assigns.patient_id
    target_behavior_id = socket.assigns.target_behavior_id

    case ClinicalRecord.list_functional_analysis_version_summaries(
           professional,
           patient_id,
           target_behavior_id
         ) do
      {:ok, summaries} -> {:noreply, assign(socket, :version_summaries, summaries)}
      {:error, :unauthorized} -> {:noreply, redirect_to_patients(socket, :unauthorized)}
      {:error, :not_found} -> {:noreply, redirect_to_patients(socket, :not_found)}
    end
  end

  defp version_option_label(version) do
    author =
      case version.professional do
        %{full_name: full_name, email: email} -> full_name || email
        _other -> nil
      end

    "Versión #{version.version_number} · #{format_datetime(version.inserted_at)} · #{author} · #{truncate_note(version.change_note)}"
  end

  defp truncate_note(note) when is_binary(note) do
    if String.length(note) > 60 do
      String.slice(note, 0, 57) <> "…"
    else
      note
    end
  end

  defp truncate_note(_note), do: ""

  defp version_view_field_id(field),
    do: "functional-analysis-version-view-#{String.replace(Atom.to_string(field), "_", "-")}"

  defp find_citable_candidate(%AsyncResult{ok?: true, result: candidates}, chunk_id) do
    Enum.find(candidates, fn candidate ->
      candidate.chunk_id == chunk_id and citable_candidate?(candidate)
    end)
  end

  defp find_citable_candidate(_async_result, _chunk_id), do: nil

  defp find_dismissable_candidate(%AsyncResult{ok?: true, result: candidates}, chunk_id) do
    Enum.find(candidates, &(&1.chunk_id == chunk_id))
  end

  defp find_dismissable_candidate(_async_result, _chunk_id), do: nil

  defp mark_search_result_cited(socket, chunk_id) do
    cited_chunk_ids = MapSet.put(socket.assigns.cited_chunk_ids, chunk_id)
    assign(socket, :cited_chunk_ids, cited_chunk_ids)
  end

  defp cited_chunk?(cited_chunk_ids, chunk_id) do
    MapSet.member?(cited_chunk_ids, chunk_id)
  end

  defp remove_suggested_candidate(socket, chunk_id) do
    async_result = socket.assigns.suggested_candidates

    socket =
      if socket.assigns[:trimming_candidate_id] == chunk_id do
        assign(socket, trimming_candidate_id: nil, trim_form: nil, trim_error: nil)
      else
        socket
      end

    case async_result do
      %AsyncResult{ok?: true, result: candidates} when is_list(candidates) ->
        candidates = Enum.reject(candidates, &(&1.chunk_id == chunk_id))
        assign(socket, :suggested_candidates, AsyncResult.ok(async_result, candidates))

      _other ->
        socket
    end
  end

  defp trigger_evidence_search(socket, query, source) do
    professional = socket.assigns.current_professional
    patient_id = socket.assigns.patient_id
    target_behavior_id = socket.assigns.target_behavior_id

    socket
    |> cancel_async(:search_results)
    |> assign(:search_results, %Phoenix.LiveView.AsyncResult{})
    |> assign_async(:search_results, fn ->
      case ClinicalRecord.search_evidence_candidates(
             professional,
             patient_id,
             target_behavior_id,
             query,
             source_kind: source,
             limit: 10
           ) do
        {:ok, results} -> {:ok, %{search_results: results}}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  defp normalize_search_source_filter(source) when source in ["telegram", "notes", "sessions"],
    do: source

  defp normalize_search_source_filter(_other), do: "all"

  defp citable_candidate?(%{source_resource_type: resource_type}) do
    match?({:ok, _source_kind}, citation_source_kind(resource_type))
  end

  defp citation_source_kind("clinical_note"), do: {:ok, "clinical_note"}
  defp citation_source_kind("patient_message"), do: {:ok, "message"}
  defp citation_source_kind("session_transcript"), do: {:ok, "session_transcript"}
  defp citation_source_kind(_resource_type), do: {:error, :unsupported_source}

  # Builds the trusted attrs for `cite_evidence_source/4`. The span hint
  # (AD2/AD3) comes only from the server-side candidate/result assign — never
  # from client `phx-value-*`/form params, so a forged client speaker or time
  # value can never influence which span is matched or what gets persisted.
  defp citation_attrs(candidate, source_kind, excerpt) do
    base = %{source_kind: source_kind, source_id: candidate.source_resource_id, excerpt: excerpt}

    if candidate.speaker do
      Map.put(base, :span_hint, %{
        speaker: candidate.speaker,
        audio_start_seconds: candidate.audio_start_seconds,
        audio_end_seconds: candidate.audio_end_seconds
      })
    else
      base
    end
  end

  defp reset_evidence_search(socket) do
    socket
    |> cancel_async(:search_results)
    |> assign(:search_query, "")
    |> assign(:search_form, to_form(%{"query" => ""}, as: "search"))
    |> assign(
      :search_results,
      Phoenix.LiveView.AsyncResult.ok(%Phoenix.LiveView.AsyncResult{}, [])
    )
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

  defp cited_sanitized_evidence(items) do
    items
    |> Enum.filter(&(&1.kind == :consultation_evidence))
    |> Enum.reduce(%{ids: MapSet.new(), texts: []}, fn item, selected ->
      case Sanitizer.sanitize(item.text) do
        "" ->
          selected

        text ->
          %{
            ids: MapSet.put(selected.ids, item.id),
            texts: [text | selected.texts]
          }
      end
    end)
    |> Map.update!(:texts, &Enum.reverse/1)
  end

  defp cited_evidence_still_live(evidence_ids, items) do
    live_ids =
      items
      |> Enum.filter(&(&1.kind == :consultation_evidence))
      |> MapSet.new(& &1.id)

    if MapSet.subset?(evidence_ids, live_ids),
      do: :ok,
      else: {:error, :stale_cited_evidence}
  end

  defp functional_analysis_draft_chain do
    Application.get_env(
      :alethea,
      :functional_analysis_draft_chain,
      FunctionalAnalysisDraftChain
    )
  end

  defp functional_analysis_form_values(socket) do
    fields = ["previous_notes" | FunctionalAnalysisDraftChain.eorc_fields()]

    Map.new(fields, fn field ->
      atom_field = String.to_existing_atom(field)
      {field, socket.assigns.functional_analysis_form[atom_field].value || ""}
    end)
  end

  defp params_equal?(params1, params2) when is_map(params1) and is_map(params2) do
    fields = ["previous_notes" | FunctionalAnalysisDraftChain.eorc_fields()]

    Enum.all?(fields, fn field ->
      (Map.get(params1, field) || "") == (Map.get(params2, field) || "")
    end)
  end

  defp params_equal?(_, _), do: false

  # Bumps seq so any queued stale autosave is ignored by :perform_autosave (:1035).
  defp schedule_functional_analysis_autosave(socket, values) do
    seq = socket.assigns.autosave_seq + 1
    send(self(), {:perform_autosave, values, seq})
    socket |> assign(:autosave_seq, seq) |> assign(:draft_status, :saving)
  end

  # Single choke point for selecting a version (or the working draft): every
  # caller resets any pending continuation confirmation, so a stale
  # confirmation can never survive a selection change (GitHub #365, AD6/C9).
  defp put_selected_version(socket, version, content) do
    socket
    |> assign(:selected_version, version)
    |> assign(:selected_version_content, content)
    |> assign(:continue_confirmation_pending, false)
  end

  # Mirrors only the `:conflict` row of `version_registration_blocker/2`
  # (AD3): a stale `functional_analysis_lock_version` would make the
  # scheduled upsert re-conflict. `:save_failed`/`:saving` are explicitly
  # allowed (L6/AD1-AD2). Checked before any re-fetch or scheduling so a
  # forged event never causes a needless audited read (AD4).
  defp continuation_blocker(assigns) do
    cond do
      not match?(%FunctionalAnalysisVersion{}, assigns.selected_version) ->
        :noop

      assigns.draft_generation_pending ->
        :noop

      assigns.draft_tombstoned_at != nil ->
        :noop

      assigns.draft_status == :conflict ->
        {:flash, "Resolvé el conflicto de guardado antes de continuar desde una versión."}

      true ->
        nil
    end
  end

  # Current work is "any unsaved keystroke", not just `draft_status` (AD8):
  # `draft_status` reflects the last save, not the live form.
  defp working_form_blank?(socket) do
    socket
    |> functional_analysis_form_values()
    |> Map.values()
    |> Enum.all?(&(String.trim(&1) == ""))
  end

  # L3: always re-fetches the version rather than trusting
  # `@selected_version_content`, so a version deleted/altered between
  # opening and confirming is never copied stale (C4).
  defp apply_version_continuation(socket) do
    professional = socket.assigns.current_professional
    patient_id = socket.assigns.patient_id
    target_behavior_id = socket.assigns.target_behavior_id
    version_id = socket.assigns.selected_version.id

    case ClinicalRecord.get_functional_analysis_version(
           professional,
           patient_id,
           target_behavior_id,
           version_id
         ) do
      {:ok, version} ->
        {_format, content} = FunctionalAnalysisContent.parse(version.body)
        values = content_params(content)

        socket =
          socket
          |> assign(:functional_analysis_form, to_form(values, as: "functional_analysis"))
          |> put_selected_version(nil, nil)
          |> schedule_functional_analysis_autosave(values)
          |> put_flash(
            :info,
            "Contenido de la Versión #{version.version_number} copiado al borrador de trabajo."
          )

        {:noreply, socket}

      {:error, :unauthorized} ->
        {:noreply, redirect_to_patients(socket, :unauthorized)}

      {:error, _reason} ->
        socket
        |> put_selected_version(nil, nil)
        |> put_flash(:error, "La versión no está disponible.")
        |> relist_version_summaries()
    end
  end

  defp merge_generated_draft(current, generated) do
    Enum.reduce(FunctionalAnalysisDraftChain.eorc_fields(), current, fn field, values ->
      current_value = Map.get(values, field, "")
      generated_value = Map.get(generated, field, "")

      if String.trim(current_value) == "" and
           is_binary(generated_value) and String.trim(generated_value) != "" do
        Map.put(values, field, generated_value)
      else
        values
      end
    end)
  end

  defp draft_generation_error(socket) do
    socket
    |> assign(:draft_generation_pending, false)
    |> put_flash(:error, "No se pudo generar el borrador E-O-R-C.")
  end

  defp compute_draft_status(tombstoned_at, %FunctionalAnalysisContent{} = content) do
    cond do
      tombstoned_at != nil ->
        :tombstoned

      content
      |> Map.from_struct()
      |> Map.values()
      |> Enum.all?(&(String.trim(&1) == "")) ->
        :empty

      true ->
        :saved
    end
  end

  defp version_note_param(%{"version" => %{"change_note" => note}}) when is_binary(note),
    do: note

  defp version_note_param(_params), do: ""

  defp version_form(note, error \\ nil) do
    errors = if error, do: [change_note: {error, []}], else: []
    to_form(%{"change_note" => note}, as: "version", errors: errors)
  end

  # Only a draft that is confirmed persisted and identical to what the
  # professional sees may be registered. Returns nil when registration may
  # proceed, otherwise where the rejection must be shown.
  defp version_registration_blocker(socket, note) do
    assigns = socket.assigns

    cond do
      assigns.draft_tombstoned_at != nil ->
        {:flash, "El borrador fue eliminado legalmente."}

      assigns.draft_status == :conflict ->
        {:flash, "Resolvé el conflicto de guardado antes de registrar una versión."}

      assigns.draft_status == :save_failed ->
        {:flash, "Resolvé el error de guardado antes de registrar una versión."}

      assigns.draft_status == :saving ->
        {:flash, "Esperá a que termine el guardado antes de registrar una versión."}

      not params_equal?(
        functional_analysis_form_values(socket),
        assigns.last_saved_functional_analysis_params
      ) ->
        {:flash, "Guardá los cambios pendientes antes de registrar una versión."}

      assigns.draft_status == :empty or assigns.functional_analysis_lock_version in [nil, 0] ->
        {:flash, "Guardá el análisis funcional antes de registrar una versión."}

      String.trim(note) == "" ->
        {:note, "Ingresá una nota breve del cambio."}

      true ->
        nil
    end
  end

  defp register_functional_analysis_version(socket, note) do
    case ClinicalRecord.register_functional_analysis_version(
           socket.assigns.current_professional,
           socket.assigns.patient_id,
           socket.assigns.target_behavior_id,
           socket.assigns.functional_analysis_lock_version,
           note
         ) do
      {:ok, version} ->
        {:noreply,
         socket
         |> assign(:version_form, version_form(""))
         |> put_flash(:info, "Versión #{version.version_number} registrada.")}

      {:error, :invalid_change_note} ->
        {:noreply,
         assign(
           socket,
           :version_form,
           version_form(note, "La nota debe tener entre 1 y 500 caracteres.")
         )}

      {:error, :conflict} ->
        {:noreply,
         socket
         |> assign(:draft_status, :conflict)
         |> put_flash(:error, "Conflicto: otra sesión modificó el borrador.")}

      {:error, :legally_deleted} ->
        {:noreply,
         socket
         |> assign(:draft_tombstoned_at, draft_deleted_at(socket))
         |> assign(:draft_status, :tombstoned)
         |> put_flash(:error, "El borrador fue eliminado legalmente.")}

      {:error, :unauthorized} ->
        {:noreply, redirect_to_patients(socket, :unauthorized)}

      {:error, :not_found} ->
        {:noreply, redirect_to_patients(socket, :not_found)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "No se pudo registrar la versión.")}
    end
  end

  defp draft_deleted_at(socket) do
    case ClinicalRecord.get_functional_analysis_draft(
           socket.assigns.current_professional,
           socket.assigns.patient_id,
           socket.assigns.target_behavior_id
         ) do
      {:ok, {:legally_deleted, deleted_at}} -> deleted_at
      _other -> DateTime.utc_now()
    end
  end

  defp content_params(%FunctionalAnalysisContent{} = content) do
    content
    |> Map.from_struct()
    |> Map.new(fn {field, value} -> {Atom.to_string(field), value} end)
  end

  defp timeline_tab_class(:evidence), do: "review-timeline--evidence"
  defp timeline_tab_class(:observations), do: "review-timeline--observations"
  defp timeline_tab_class(:proposals), do: "review-timeline--proposals"

  defp input_tab_id(tab), do: "input-tab-#{tab}"

  defp adjacent_input_tab(active_tab, key) do
    tabs = [:evidence, :observations, :proposals]
    offset = if key == "ArrowRight", do: 1, else: -1
    active_index = Enum.find_index(tabs, &(&1 == active_tab))
    Enum.at(tabs, Integer.mod(active_index + offset, length(tabs)))
  end

  defp draft_status_label(:empty), do: "Borrador vacío"
  defp draft_status_label(:saved), do: "Guardado"
  defp draft_status_label(:saving), do: "Guardando…"
  defp draft_status_label(:save_failed), do: "Error al guardar"
  defp draft_status_label(:conflict), do: "Conflicto al guardar"
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

  defp source_label({:ok, %{kind: :session_transcript, occurred_at: occurred_at}}) do
    "Transcripción de sesión · #{format_datetime(occurred_at)}"
  end

  defp source_label(_), do: "Fuente no disponible"

  defp speaker_label("patient"), do: "Paciente"
  defp speaker_label("therapist"), do: "Terapeuta"

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

  defp evidence_source_card_class(%{kind: :clinical_note}),
    do: "evidence-source-card--clinical-note"

  defp evidence_source_card_class(%{kind: :message, direction: "inbound"}),
    do: "evidence-source-card--inbound"

  defp evidence_source_card_class(%{kind: :message, direction: "outbound"}),
    do: "evidence-source-card--outbound"

  defp evidence_source_card_class(%{kind: :message}), do: "evidence-source-card--message"

  defp source_kind_label("clinical_note"), do: "Nota clínica"
  defp source_kind_label("patient_message"), do: "Mensaje del paciente"
  defp source_kind_label("session_transcript"), do: "Transcripción de sesión"
  defp source_kind_label("session_transcripts"), do: "Transcripción de sesión"
  defp source_kind_label("consultation_evidence"), do: "Evidencia citada"
  defp source_kind_label("clinician_observation"), do: "Observación del clínico"
  defp source_kind_label("ai_proposal"), do: "Propuesta de IA (aceptada)"
  defp source_kind_label("functional_analysis_draft"), do: "Borrador de análisis funcional"
  defp source_kind_label(kind), do: Phoenix.Naming.humanize(kind)

  defp format_iso_datetime(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp format_iso_datetime(nil), do: ""

  defp format_datetime(%DateTime{} = datetime) do
    Calendar.strftime(datetime, "%d/%m/%Y %H:%M")
  end

  defp format_datetime(_datetime), do: ""

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

        <div class="stat-strip review-metadata-strip" id="review-stat-strip">
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

      <div id="clinical-workbench" class="clinical-workbench">
        <section id="workbench-inputs-panel" class="workbench-panel workbench-inputs-panel">
          <div class="workbench-panel__header">
            <div>
              <span class="pt-eyebrow">Insumos clínicos</span>
              <h2 class="t-title-sm">Evidencia y observaciones</h2>
            </div>

            <button
              type="button"
              id="toggle-observation-form"
              phx-click="toggle_observation_form"
              aria-controls="observation-entry"
              aria-expanded={to_string(@observation_form_open)}
              class="button-secondary button-secondary--sm"
            >
              <.icon name="hero-plus" class="size-4" /> Observación
            </button>
          </div>

          <div
            id="input-tabs"
            class="review-tabs"
            role="tablist"
            aria-label="Filtrar insumos clínicos"
            phx-hook=".InputTabs"
          >
            <button
              type="button"
              role="tab"
              id="input-tab-evidence"
              phx-click="select_input_tab"
              phx-keydown="navigate_input_tab"
              phx-value-tab="evidence"
              aria-controls="review-timeline"
              aria-selected={to_string(@active_input_tab == :evidence)}
              tabindex={if(@active_input_tab == :evidence, do: "0", else: "-1")}
              class={["review-tab", @active_input_tab == :evidence && "review-tab--active"]}
            >
              Evidencia citada <span>{@evidence_count}</span>
            </button>
            <button
              type="button"
              role="tab"
              id="input-tab-observations"
              phx-click="select_input_tab"
              phx-keydown="navigate_input_tab"
              phx-value-tab="observations"
              aria-controls="review-timeline"
              aria-selected={to_string(@active_input_tab == :observations)}
              tabindex={if(@active_input_tab == :observations, do: "0", else: "-1")}
              class={["review-tab", @active_input_tab == :observations && "review-tab--active"]}
            >
              Observaciones <span>{@observation_count}</span>
            </button>
            <button
              type="button"
              role="tab"
              id="input-tab-proposals"
              phx-click="select_input_tab"
              phx-keydown="navigate_input_tab"
              phx-value-tab="proposals"
              aria-controls="review-timeline"
              aria-selected={to_string(@active_input_tab == :proposals)}
              tabindex={if(@active_input_tab == :proposals, do: "0", else: "-1")}
              class={["review-tab", @active_input_tab == :proposals && "review-tab--active"]}
            >
              Propuestas IA <span>{@proposal_count}</span>
            </button>
          </div>

          <script :type={Phoenix.LiveView.ColocatedHook} name=".InputTabs">
            export default {
              mounted() {
                this.handleEvent("focus_input_tab", ({ id }) => {
                  const tab = document.getElementById(id)

                  if (tab && this.el.contains(tab)) tab.focus()
                })
              }
            }
          </script>

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
              <h3 id="evidence-source-feed-label" class="t-title-sm">Fuentes disponibles</h3>

              <p id="evidence-source-feed-description" class="pt-muted">
                Seleccioná una fuente para citar. Cada tarjeta muestra el contenido completo y su procedencia.
              </p>

              <div
                id="evidence-source-feed"
                aria-labelledby="evidence-source-feed-label"
                aria-describedby="evidence-source-feed-description"
              >
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
                  class={["evidence-source-card", evidence_source_card_class(source)]}
                >
                  <span class="evidence-source-card__meta">
                    <strong class="evidence-source-card__type">
                      {evidence_source_type_label(source)}
                    </strong>
                    <span class="evidence-source-card__date">
                      {format_datetime(source.occurred_at)}
                    </span>
                    <span class="evidence-source-card__provenance">
                      {evidence_source_provenance(source)}
                    </span>
                  </span>
                  <span class="evidence-source-card__content">{source.content}</span>
                </button>
              </div>
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

          <div
            :if={@active_input_tab == :proposals}
            id="proposal-inbox"
            class="proposal-inbox"
          >
            <.icon name="hero-information-circle" class="size-4" />
            <div>
              <strong>Las propuestas de IA son provisionales.</strong>
              <p>
                Aceptarlas no modifica el análisis. Revisá y ubicá manualmente cada contenido en E/O/R/C cuando corresponda.
              </p>
            </div>
          </div>

          <section
            :if={@active_input_tab == :evidence and is_nil(@citation_step)}
            id="suggested-evidence-panel"
            class="suggested-evidence-panel"
            aria-label="Sugerencias de evidencia"
          >
            <header class="suggested-evidence-panel__header">
              <div>
                <span class="pt-eyebrow">
                  {if @search_query != "", do: "Búsqueda semántica", else: "Sugerencias"}
                </span>
                <h3 class="t-title-sm">
                  {if @search_query != "",
                    do: "Resultados en el historial",
                    else: "Evidencia potencialmente relevante"}
                </h3>
              </div>
            </header>

            <div id="evidence-search-bar" class="evidence-search-bar">
              <div
                id="evidence-search-filters"
                class="evidence-search-filters"
                role="group"
                aria-label="Filtrar por tipo de fuente"
              >
                <button
                  :for={filter <- @search_source_filters}
                  type="button"
                  id={"evidence-search-filter-#{filter.id}"}
                  phx-click="filter_search_source"
                  phx-value-source={filter.id}
                  class={[
                    "filter-pill",
                    @search_source_filter == filter.id && "filter-pill--active"
                  ]}
                  aria-pressed={to_string(@search_source_filter == filter.id)}
                >
                  {filter.label}
                </button>
              </div>

              <.form
                for={@search_form}
                id="evidence-search-form"
                phx-change="search_evidence"
                phx-submit="search_evidence"
              >
                <div class="evidence-search-field">
                  <.icon name="hero-magnifying-glass" class="evidence-search-icon size-4" />
                  <.input
                    field={@search_form[:query]}
                    type="search"
                    id="evidence-search-input"
                    placeholder="Buscar en el historial clínico (ej. angustia en el supermercado)…"
                    phx-debounce="400"
                    autocomplete="off"
                    class={["text-input", "evidence-search-input"]}
                  />
                  <button
                    :if={@search_query != ""}
                    type="button"
                    id="clear-evidence-search"
                    phx-click="clear_evidence_search"
                    class="evidence-search-clear-button"
                    aria-label="Limpiar búsqueda"
                  >
                    <.icon name="hero-x-mark" class="size-4" />
                  </button>
                </div>
              </.form>
            </div>

            <.async_result :let={candidates} :if={@search_query == ""} assign={@suggested_candidates}>
              <:loading>
                <div id="suggested-candidates-loading" class="pt-muted">
                  Buscando fragmentos relevantes…
                </div>
              </:loading>

              <:failed :let={_reason}>
                <div id="suggested-candidates-error" class="field__error">
                  No se pudieron cargar las sugerencias de evidencia.
                </div>
              </:failed>

              <div
                :if={candidates == []}
                id="suggested-candidates-empty"
                class="empty-state empty-state--compact suggested-candidates-empty"
              >
                <.icon name="hero-magnifying-glass" class="empty-state__icon" />
                <p class="empty-state__title">No hay sugerencias disponibles</p>

                <p class="empty-state__text">
                  No se encontraron fragmentos relevantes para esta conducta objetivo.
                </p>
              </div>

              <div
                :if={candidates != []}
                id="suggested-candidates-list"
                class="suggested-candidates-list"
              >
                <article
                  :for={candidate <- candidates}
                  id={"suggested-candidate-#{candidate.chunk_id}"}
                  class={[
                    "suggested-candidate-card",
                    "suggested-candidate-card--#{candidate.affinity_tier}"
                  ]}
                >
                  <header class="suggested-candidate-card__meta">
                    <span class={[
                      "badge",
                      "badge--affinity",
                      "badge--affinity-#{candidate.affinity_tier}"
                    ]}>
                      {candidate.affinity_badge.label}
                    </span>
                    <span class={[
                      "badge",
                      "badge--source-kind",
                      "badge--source-#{candidate.source_resource_type}"
                    ]}>
                      {source_kind_label(candidate.source_resource_type)}
                    </span>
                    <time
                      datetime={format_iso_datetime(candidate.source_occurred_at)}
                      class="suggested-candidate-card__time"
                    >
                      {format_datetime(candidate.source_occurred_at)}
                    </time>
                    <span
                      :if={candidate.speaker}
                      class={["badge", "badge--speaker", "badge--speaker-#{candidate.speaker}"]}
                    >
                      {speaker_label(candidate.speaker)}
                    </span>
                    <span :if={candidate.speaker} class="suggested-candidate-card__audio">
                      {AudioMarker.format_range(
                        candidate.audio_start_seconds,
                        candidate.audio_end_seconds
                      )}
                    </span>
                  </header>

                  <%= if @trimming_candidate_id == candidate.chunk_id do %>
                    <.form
                      for={@trim_form}
                      id={"trim-candidate-form-#{candidate.chunk_id}"}
                      phx-submit="confirm_trimmed_candidate"
                      class="suggested-candidate-card__trim-form"
                    >
                      <.input
                        field={@trim_form[:excerpt]}
                        type="textarea"
                        label="Recortar fragmento exacto"
                        rows={3}
                        id={"trim-candidate-excerpt-#{candidate.chunk_id}"}
                        placeholder="Editá o recortá el fragmento exacto a citar…"
                      />
                      <p
                        :if={@trim_error}
                        id={"trim-candidate-error-#{candidate.chunk_id}"}
                        class="field__error"
                      >
                        {@trim_error}
                      </p>

                      <div class="suggested-candidate-card__trim-actions form-actions">
                        <button
                          type="submit"
                          id={"confirm-trim-candidate-#{candidate.chunk_id}"}
                          class="button-primary button-primary--sm"
                        >
                          Confirmar cita
                        </button>
                        <button
                          type="button"
                          id={"cancel-trim-candidate-#{candidate.chunk_id}"}
                          phx-click="cancel_trim_candidate"
                          class="button-secondary button-secondary--sm"
                        >
                          Cancelar
                        </button>
                      </div>
                    </.form>
                  <% else %>
                    <p class="suggested-candidate-card__content">{candidate.content}</p>

                    <div class="suggested-candidate-card__actions">
                      <button
                        :if={citable_candidate?(candidate)}
                        type="button"
                        id={"cite-suggested-candidate-#{candidate.chunk_id}"}
                        phx-click="cite_suggested_candidate"
                        phx-value-id={candidate.chunk_id}
                        class="button-primary button-primary--sm"
                      >
                        + Citar todo
                      </button>
                      <button
                        :if={citable_candidate?(candidate)}
                        type="button"
                        id={"trim-suggested-candidate-#{candidate.chunk_id}"}
                        phx-click="open_trim_candidate"
                        phx-value-id={candidate.chunk_id}
                        class="button-secondary button-secondary--sm"
                      >
                        Recortar
                      </button>
                      <button
                        type="button"
                        id={"dismiss-suggested-candidate-#{candidate.chunk_id}"}
                        phx-click="dismiss_suggested_candidate"
                        phx-value-id={candidate.chunk_id}
                        class="button-secondary button-secondary--sm"
                      >
                        Descartar ✕
                      </button>
                    </div>
                  <% end %>
                </article>
              </div>
            </.async_result>

            <.async_result :let={results} :if={@search_query != ""} assign={@search_results}>
              <:loading>
                <div id="evidence-search-loading" class="pt-muted">
                  Buscando en el historial clínico…
                </div>
              </:loading>

              <:failed :let={_reason}>
                <div id="evidence-search-error" class="field__error">
                  No se pudieron cargar los resultados de búsqueda.
                </div>
              </:failed>

              <div
                :if={results == []}
                id="evidence-search-empty"
                class="empty-state empty-state--compact evidence-search-empty"
              >
                <.icon name="hero-magnifying-glass" class="empty-state__icon" />
                <p class="empty-state__title">No se encontraron coincidencias</p>

                <p class="empty-state__text">
                  Probá con otras palabras o una descripción más amplia.
                </p>
              </div>

              <div
                :if={results != []}
                id="evidence-search-results-list"
                class="suggested-candidates-list evidence-search-results-list"
              >
                <article
                  :for={result <- results}
                  id={"evidence-search-result-#{result.chunk_id}"}
                  class={[
                    "suggested-candidate-card",
                    "suggested-candidate-card--#{result.affinity_tier}",
                    cited_chunk?(@cited_chunk_ids, result.chunk_id) &&
                      "suggested-candidate-card--cited"
                  ]}
                >
                  <header class="suggested-candidate-card__meta">
                    <span class={[
                      "badge",
                      "badge--affinity",
                      "badge--affinity-#{result.affinity_tier}"
                    ]}>
                      {result.affinity_badge.label}
                    </span>
                    <span class={[
                      "badge",
                      "badge--source-kind",
                      "badge--source-#{result.source_resource_type}"
                    ]}>
                      {source_kind_label(result.source_resource_type)}
                    </span>
                    <time
                      datetime={format_iso_datetime(result.source_occurred_at)}
                      class="suggested-candidate-card__time"
                    >
                      {format_datetime(result.source_occurred_at)}
                    </time>
                    <span
                      :if={result.speaker}
                      class={["badge", "badge--speaker", "badge--speaker-#{result.speaker}"]}
                    >
                      {speaker_label(result.speaker)}
                    </span>
                    <span :if={result.speaker} class="suggested-candidate-card__audio">
                      {AudioMarker.format_range(
                        result.audio_start_seconds,
                        result.audio_end_seconds
                      )}
                    </span>
                  </header>

                  <p class="suggested-candidate-card__content">{result.content}</p>

                  <div class="suggested-candidate-card__actions">
                    <button
                      :if={
                        citable_candidate?(result) and
                          not cited_chunk?(@cited_chunk_ids, result.chunk_id)
                      }
                      type="button"
                      id={"cite-search-result-#{result.chunk_id}"}
                      phx-click="cite_search_result"
                      phx-value-id={result.chunk_id}
                      class="button-primary button-primary--sm"
                    >
                      + Citar
                    </button>
                    <span
                      :if={cited_chunk?(@cited_chunk_ids, result.chunk_id)}
                      id={"cited-confirmation-#{result.chunk_id}"}
                      class="evidence-search-result__cited-confirmation badge badge--cited"
                    >
                      ✓ Citado
                    </span>
                  </div>
                </article>
              </div>
            </.async_result>
          </section>

          <ol
            id="review-timeline"
            role="tabpanel"
            aria-labelledby={input_tab_id(@active_input_tab)}
            phx-update="stream"
            class={["review-timeline", timeline_tab_class(@active_input_tab)]}
          >
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
                <span
                  :if={item.speaker}
                  class={["badge", "badge--speaker", "badge--speaker-#{item.speaker}"]}
                >
                  {speaker_label(item.speaker)}
                </span>
                <span :if={item.speaker} class="suggested-candidate-card__audio">
                  {AudioMarker.format_range(item.audio_start_seconds, item.audio_end_seconds)}
                </span>
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
                <.input
                  type="textarea"
                  name="proposal[text]"
                  value={item.text}
                  label="Editar propuesta"
                />
                <div class="form-actions">
                  <button type="submit" class="button-primary button-primary--sm">
                    Guardar edición
                  </button>
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

          <div :if={@observation_form_open} class="review-observation" id="observation-entry">
            <h3 class="t-title-sm">Agregar observación clínica</h3>

            <.form for={@observation_form} id="observation-form" phx-submit="add_observation">
              <.input
                field={@observation_form[:body]}
                type="textarea"
                label="Observación (sin cita)"
              />
              <div class="form-actions">
                <button type="submit" class="button-primary button-primary--sm">
                  Agregar observación
                </button>
                <button
                  type="button"
                  id="cancel-observation"
                  phx-click="cancel_observation"
                  class="button-secondary button-secondary--sm"
                >
                  Cancelar
                </button>
              </div>
            </.form>
          </div>

          <div
            :if={@observation_count == 0 and @active_input_tab == :observations}
            id="empty-observations"
            class="empty-state empty-state--compact"
          >
            <.icon name="hero-chat-bubble-left-right" class="empty-state__icon" />
            <p class="empty-state__title">Sin observaciones del clínico</p>

            <p class="empty-state__text">Todavía no registraste observaciones directas.</p>
          </div>
        </section>

        <aside id="workbench-editor-panel" class="workbench-panel workbench-editor-panel">
          <div class="review-draft">
            <div class="workbench-panel__header">
              <div>
                <span class="pt-eyebrow">Formulación clínica</span>
                <h2 class="t-title-sm">Análisis funcional E-O-R-C</h2>
              </div>

              <div class="form-actions">
                <button
                  :if={!@draft_tombstoned_at and is_nil(@selected_version)}
                  type="button"
                  id="generate-functional-analysis-draft"
                  phx-click="generate_functional_analysis_draft"
                  disabled={@draft_generation_pending or !@has_sufficient_evidence}
                  class="button-primary button-primary--sm"
                >
                  {if @draft_generation_pending,
                    do: "Generando borrador…",
                    else: "✨ Generar borrador E-O-R-C con IA"}
                </button>
                <span id="editor-draft-status" class="review-status-chip">
                  {draft_status_label(@draft_status)}
                </span>
              </div>
            </div>

            <div :if={@draft_tombstoned_at} id="draft-tombstone" class="tombstone-note">
              <.icon name="hero-lock-closed" class="size-3" />
              Eliminado legalmente el {format_datetime(@draft_tombstoned_at)}
            </div>

            <div
              id="functional-analysis-version-selector"
              role="group"
              aria-label="Versiones registradas"
              class="version-selector"
            >
              <button
                type="button"
                id="functional-analysis-working-draft-option"
                phx-click="select_functional_analysis_version"
                phx-value-id="working-draft"
                disabled={@draft_generation_pending}
                aria-pressed={to_string(is_nil(@selected_version))}
                class={[
                  "filter-pill",
                  is_nil(@selected_version) && "filter-pill--active"
                ]}
              >
                Borrador de trabajo
              </button>

              <button
                :for={version <- @version_summaries}
                type="button"
                id={"functional-analysis-version-option-#{version.id}"}
                phx-click="select_functional_analysis_version"
                phx-value-id={version.id}
                disabled={@draft_generation_pending}
                aria-pressed={to_string(@selected_version && @selected_version.id == version.id)}
                class={[
                  "filter-pill",
                  @selected_version && @selected_version.id == version.id && "filter-pill--active"
                ]}
              >
                {version_option_label(version)}
              </button>
            </div>

            <section
              :if={@selected_version}
              id="functional-analysis-version-view"
              class="functional-analysis-version-view"
            >
              <h2 class="t-title-sm">Versión {@selected_version.version_number}</h2>

              <div class="review-item__meta">
                <span id="functional-analysis-version-view-author">
                  {(@selected_version.professional && @selected_version.professional.full_name) ||
                    (@selected_version.professional && @selected_version.professional.email)}
                </span>
                <span id="functional-analysis-version-view-date">
                  {format_datetime(@selected_version.inserted_at)}
                </span>
              </div>

              <div
                :if={!@draft_tombstoned_at}
                id="functional-analysis-version-actions"
                class="form-actions"
              >
                <button
                  :if={!@continue_confirmation_pending}
                  type="button"
                  id="functional-analysis-version-continue"
                  phx-click="request_continue_from_version"
                  class="button-primary button-primary--sm"
                >
                  Continuar desde esta versión
                </button>
              </div>
              <div
                :if={@continue_confirmation_pending}
                id="functional-analysis-version-continue-confirmation"
                role="alert"
              >
                <p id="functional-analysis-version-continue-warning">
                  El borrador de trabajo actual será reemplazado por el contenido de la Versión {@selected_version.version_number}. La versión histórica no se modifica y no se registra una versión nueva.
                </p>
                <div class="form-actions">
                  <button
                    type="button"
                    id="functional-analysis-version-continue-confirm"
                    phx-click="confirm_continue_from_version"
                    class="button-primary button-primary--sm"
                  >
                    Reemplazar borrador
                  </button>
                  <button
                    type="button"
                    id="functional-analysis-version-continue-cancel"
                    phx-click="cancel_continue_from_version"
                    class="button-secondary button-secondary--sm"
                  >
                    Cancelar
                  </button>
                </div>
              </div>

              <section
                :if={
                  @selected_version_content &&
                    @selected_version_content.previous_notes not in [nil, ""]
                }
                id="functional-analysis-version-view-previous-notes"
                class="previous-notes"
              >
                <h3>Notas anteriores</h3>
                <pre class="previous-notes__content">{@selected_version_content.previous_notes}</pre>
              </section>

              <fieldset
                :for={{letter, legend, fields} <- version_view_sections()}
                class="functional-analysis-section"
              >
                <legend><span>{letter}</span> {legend}</legend>

                <div :for={{field, label} <- fields} id={version_view_field_id(field)} class="field">
                  <span class="field__label">{label}</span>
                  <div class="functional-analysis-version-view__value">
                    {@selected_version_content && Map.get(@selected_version_content, field)}
                  </div>
                </div>
              </fieldset>

              <div id="functional-analysis-version-view-change-note" class="field">
                <span class="field__label">Nota del cambio</span>
                <div class="functional-analysis-version-view__value">
                  {@selected_version.change_note}
                </div>
              </div>
            </section>

            <div
              :if={@draft_status == :empty and !@draft_tombstoned_at and is_nil(@selected_version)}
              id="empty-draft"
              class="empty-state empty-state--compact"
            >
              <.icon name="hero-information-circle" class="empty-state__icon" />
              <p class="empty-state__title">Sin análisis funcional guardado</p>

              <p class="empty-state__text">
                Completá únicamente los campos respaldados por la revisión clínica.
              </p>
            </div>

            <.form
              :if={!@draft_tombstoned_at and is_nil(@selected_version)}
              for={@functional_analysis_form}
              id="functional-analysis-form"
              phx-change="change_functional_analysis"
              phx-submit="save_functional_analysis"
              class="functional-analysis-form"
            >
              <.input field={@functional_analysis_form[:previous_notes]} type="hidden" />
              <section
                :if={@functional_analysis_form[:previous_notes].value not in [nil, ""]}
                id="previous-notes"
                class="previous-notes"
                aria-labelledby="previous-notes-title"
              >
                <div class="previous-notes__header">
                  <.icon name="hero-information-circle" class="size-4" />
                  <h3 id="previous-notes-title">Notas anteriores</h3>
                </div>

                <p class="previous-notes__explanation">
                  Este texto se preservó del borrador anterior de texto libre y no se clasificó automáticamente. Usalo como referencia para ubicar manualmente su contenido en E/O/R/C.
                </p>
                <pre class="previous-notes__content">{@functional_analysis_form[:previous_notes].value}</pre>
              </section>

              <fieldset class="functional-analysis-section" id="functional-analysis-antecedents">
                <legend><span>E</span> Antecedentes</legend>

                <.input
                  field={@functional_analysis_form[:antecedents_distal]}
                  id="functional-analysis-antecedents-distal"
                  type="textarea"
                  label="Antecedentes distales"
                  phx-debounce="1000"
                />
                <.input
                  field={@functional_analysis_form[:antecedents_immediate]}
                  id="functional-analysis-antecedents-immediate"
                  type="textarea"
                  label="Antecedentes inmediatos"
                  phx-debounce="1000"
                />
              </fieldset>

              <fieldset class="functional-analysis-section" id="functional-analysis-organism">
                <legend><span>O</span> Organismo</legend>

                <div class="functional-analysis-grid">
                  <.input
                    field={@functional_analysis_form[:organism_sleep]}
                    id="functional-analysis-organism-sleep"
                    type="textarea"
                    label="Sueño"
                    phx-debounce="1000"
                  />
                  <.input
                    field={@functional_analysis_form[:organism_pain_or_discomfort]}
                    id="functional-analysis-organism-pain-or-discomfort"
                    type="textarea"
                    label="Dolor o malestar"
                    phx-debounce="1000"
                  />
                  <.input
                    field={@functional_analysis_form[:organism_hunger_or_nutrition]}
                    id="functional-analysis-organism-hunger-or-nutrition"
                    type="textarea"
                    label="Hambre o nutrición"
                    phx-debounce="1000"
                  />
                  <.input
                    field={@functional_analysis_form[:organism_learning_history]}
                    id="functional-analysis-organism-learning-history"
                    type="textarea"
                    label="Historia de aprendizaje"
                    phx-debounce="1000"
                  />
                </div>
              </fieldset>

              <fieldset class="functional-analysis-section" id="functional-analysis-response">
                <legend><span>R</span> Respuesta</legend>

                <div class="functional-analysis-grid">
                  <.input
                    field={@functional_analysis_form[:response_physiological]}
                    id="functional-analysis-response-physiological"
                    type="textarea"
                    label="Fisiológica"
                    phx-debounce="1000"
                  />
                  <.input
                    field={@functional_analysis_form[:response_cognitive]}
                    id="functional-analysis-response-cognitive"
                    type="textarea"
                    label="Cognitiva"
                    phx-debounce="1000"
                  />
                  <.input
                    field={@functional_analysis_form[:response_motor]}
                    id="functional-analysis-response-motor"
                    type="textarea"
                    label="Motora o conductual"
                    phx-debounce="1000"
                  />
                </div>
              </fieldset>

              <fieldset class="functional-analysis-section" id="functional-analysis-consequences">
                <legend><span>C</span> Consecuencias</legend>

                <.input
                  field={@functional_analysis_form[:consequences_short_term]}
                  id="functional-analysis-consequences-short-term"
                  type="textarea"
                  label="A corto plazo"
                  phx-debounce="1000"
                />
                <.input
                  field={@functional_analysis_form[:consequences_long_term]}
                  id="functional-analysis-consequences-long-term"
                  type="textarea"
                  label="A largo plazo"
                  phx-debounce="1000"
                />
              </fieldset>

              <div class="form-actions functional-analysis-actions">
                <button
                  type="submit"
                  id="save-functional-analysis"
                  class="button-primary button-primary--sm"
                >
                  <.icon name="hero-check" class="size-4" /> Guardar análisis
                </button>
              </div>
            </.form>

            <.form
              :if={!@draft_tombstoned_at and is_nil(@selected_version)}
              for={@version_form}
              id="functional-analysis-version-form"
              phx-submit="register_functional_analysis_version"
              class="functional-analysis-version-form"
            >
              <.input
                field={@version_form[:change_note]}
                id="functional-analysis-version-note"
                type="text"
                label="Nota del cambio"
                maxlength="500"
                placeholder="Qué cambió en esta versión"
                autocomplete="off"
              />
              <div class="form-actions functional-analysis-actions">
                <button
                  type="submit"
                  id="register-functional-analysis-version"
                  class="button-secondary button-secondary--sm"
                >
                  <.icon name="hero-lock-closed" class="size-4" /> Registrar versión
                </button>
              </div>
            </.form>
          </div>
        </aside>
      </div>
    </div>
    """
  end
end
