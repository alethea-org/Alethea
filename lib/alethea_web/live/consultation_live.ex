defmodule AletheaWeb.ConsultationLive do
  @moduledoc """
  Chat de consulta clínica fundamentada (#227, ADR-010) — carcasa fina
  sobre `Alethea.ClinicalRecord.Rag.Consultation`. Superficie primaria
  única (D1/#221): esta vista nunca implementa una ruta de búsqueda
  paralela, y desde #234b es la única: `PatientLive.ClinicalSearch` quedó
  retirada. El contrato resuelve a `Consultation.Live` (#232) en dev y
  prod, y a `Consultation.Fake` sólo en `:test`.

  Cero persistencia (ADR-010 §6): `followup_state` y el contador de
  turno viven únicamente en `socket.assigns` y mueren con el proceso
  (remount, navegación, logout, "nueva conversación"). Ningún handler
  escribe en `Repo`, ETS, ni audita el acceso. `current_professional` y
  `patient_id` siempre se leen de `socket.assigns`, nunca de params de
  evento. A partir de #233 (B2) ya no se mantiene un historial textual:
  la conversación previa se compone únicamente con `source_ref`s
  server-derived (`followup_state`), nunca con prosa del asistente.
  """
  use AletheaWeb, :live_view

  alias Alethea.ClinicalRecord.Rag.Consultation
  alias AletheaWeb.GroundedChat.{FollowupState, SourceCitation}

  import AletheaWeb.GroundedChat.HypothesisPanel, only: [hypothesis_panel: 1]

  @impl true
  def mount(%{"patient_id" => patient_id}, _session, socket) do
    professional = socket.assigns.current_professional

    case Consultation.open(professional, patient_id) do
      {:ok, _metadata} ->
        socket =
          socket
          |> assign(:patient_id, patient_id)
          |> assign(:state, :idle)
          |> assign(:pending, 0)
          |> assign(:turn, 0)
          |> assign(:followup_state, FollowupState.new(patient_id))
          |> assign(:query_form, to_form(%{"query" => ""}, as: "consultation"))
          |> stream_configure(:messages, dom_id: & &1.id)
          |> stream(:messages, [])

        {:ok, socket}

      {:error, :unauthorized} ->
        {:ok,
         socket
         |> put_flash(:error, "No estás autorizado para consultar a este paciente.")
         |> push_navigate(to: ~p"/patients")}
    end
  end

  @impl true
  def handle_event("ask", %{"consultation" => %{"query" => query}}, socket) do
    professional = socket.assigns.current_professional
    patient_id = socket.assigns.patient_id
    followup_state = socket.assigns.followup_state
    next_turn = socket.assigns.turn

    socket =
      socket
      |> assign(:state, :retrieving)
      |> assign(:query_form, to_form(%{"query" => ""}, as: "consultation"))
      |> start_async(:answer, fn ->
        {query,
         Consultation.answer(professional, patient_id, query,
           followup_state: followup_state,
           turn_index: next_turn
         )}
      end)

    {:noreply, socket}
  end

  @impl true
  def handle_event("new_conversation", _params, socket) do
    socket =
      socket
      |> assign(:state, :idle)
      |> assign(:pending, 0)
      |> assign(:turn, 0)
      |> assign(:followup_state, FollowupState.reset(socket.assigns.followup_state))
      |> stream(:messages, [], reset: true)

    {:noreply, socket}
  end

  @impl true
  def handle_async(:answer, {:ok, {query, result}}, socket) do
    {:noreply, apply_answer(socket, query, result)}
  end

  @impl true
  def handle_async(:answer, {:exit, _reason}, socket) do
    {:noreply, assign(socket, :state, :provider_failure)}
  end

  defp apply_answer(socket, query, {:ok, %Consultation.Answer{outcome: :synthesis} = answer}) do
    turn = socket.assigns.turn
    refs = Enum.map(answer.sources, &source_ref/1)

    # B2 (#233): each successful synthesis turn records its server-derived
    # refs in the B1 slot at the current turn index, then advances the
    # counter. Blocked turns (`no_evidence`, `stale`, `provider_failure`,
    # `unauthorized`) intentionally do NOT advance the counter and do
    # NOT record: the user can retry against the same conversational
    # step without polluting the B1 ring buffer with non-evidence turns.
    next_state = FollowupState.record_turn(socket.assigns.followup_state, turn, query, refs)

    # #235c/R10 — citations for the unified `citation/1` renderer, derived
    # here once per turn and carried in the stream item (each turn keeps its
    # own Fuentes) rather than recomputed on every render. Same 1:1 order as
    # `answer.sources`, so the render function can zip both to recover
    # `target_behavior_id` for the "Ver conducta objetivo" link
    # (`%Citation{}` doesn't carry it).
    citations = Enum.map(answer.sources, &SourceCitation.source_to_citation/1)

    socket
    |> assign(:state, :synthesis)
    |> assign(:turn, turn + 1)
    |> assign(:followup_state, next_state)
    |> assign(:last_answer, answer)
    |> stream_insert(:messages, %{
      id: "turn-#{turn}",
      turn: turn,
      query: query,
      answer: answer,
      citations: citations
    })
  end

  defp apply_answer(socket, _query, {:ok, %Consultation.Answer{outcome: :no_evidence}}) do
    assign(socket, :state, :no_evidence)
  end

  defp apply_answer(
         socket,
         _query,
         {:ok, %Consultation.Answer{outcome: :stale, pending: pending}}
       ) do
    socket
    |> assign(:state, :stale)
    |> assign(:pending, pending)
  end

  defp apply_answer(socket, _query, {:ok, %Consultation.Answer{outcome: :provider_failure}}) do
    assign(socket, :state, :provider_failure)
  end

  defp apply_answer(socket, _query, {:error, :unauthorized}) do
    socket
    |> put_flash(:error, "No estás autorizado para consultar a este paciente.")
    |> push_navigate(to: ~p"/patients")
  end

  # B2 (#233): server-derived `source_ref`. Stable across renders, unique
  # per `(chunk_id, resource_type, resource_id)`. Used to populate the B1
  # slot — never contains excerpts, only metadata that re-derives from
  # the live retrieval on the next turn.
  defp source_ref(%Consultation.Source{reference: ref}) do
    "#{ref.chunk_id}:#{ref.resource_type}:#{ref.resource_id}"
  end

  # Source presentation helper, migrated from `PatientLive.ClinicalSearch`
  # (retired in #234b): the consultation chat is now the only surface that
  # renders server-derived sources. `source_kind_label/1` and
  # `format_datetime/1` were this migration's real casualties (#235c/AD4):
  # `citation/1` now owns kind humanization (its private `kind_label/1`,
  # moved verbatim) and date formatting (its existing `format_date/1`),
  # so both are dead here.
  defp source_link(%{target_behavior_id: nil}, _patient_id), do: nil

  defp source_link(%{target_behavior_id: target_behavior_id}, patient_id) do
    ~p"/patients/#{patient_id}/target_behaviors/#{target_behavior_id}/review"
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="consultation">
      <.header>Consulta clínica</.header>

      <.form for={@query_form} id="consultation-ask-form" phx-submit="ask">
        <.input field={@query_form[:query]} type="text" label="Preguntá sobre la historia clínica" />
        <div class="form-actions">
          <button
            type="submit"
            class="button-primary button-primary--sm"
            disabled={@state == :retrieving}
          >
            Preguntar
          </button>
        </div>
      </.form>

      <button id="consultation-new-conversation" type="button" phx-click="new_conversation">
        Nueva conversación
      </button>

      <div :if={@state == :idle and @turn == 0} id="consultation-idle" class="empty-state">
        <p>Escribí una pregunta sobre la historia clínica del paciente.</p>
      </div>

      <div :if={@state == :retrieving} id="consultation-retrieving" class="empty-state">
        <p>Buscando evidencia en el registro…</p>
      </div>

      <div
        :if={@turn > 0}
        id="consultation-synthesis"
        class="consultation-synthesis consultation__thread"
      >
        <div id="consultation-messages" phx-update="stream" class="consultation__messages">
          <article
            :for={{dom_id, message} <- @streams.messages}
            id={dom_id}
            class="consultation__turn"
            data-turn={message.turn}
          >
            <div class="consultation__turn-query">
              <p class="consultation__turn-query-text">{message.query}</p>
            </div>

            <section
              id={"#{dom_id}-synthesis"}
              class="consultation-synthesis consultation__synthesis"
            >
              <h2 class="consultation__section-title">Síntesis basada en evidencia</h2>
              <p>{message.answer.synthesis}</p>
            </section>

            <section id={"#{dom_id}-sources"} class="consultation__sources-panel">
              <h2 class="consultation__section-title">Fuentes</h2>

              <.citation
                :for={{cite, source} <- Enum.zip(message.citations, message.answer.sources)}
                citation={cite}
                id={"#{dom_id}-citation-#{cite.source_ref}"}
              >
                <:link :if={source_link(source.reference, @patient_id)}>
                  <.link
                    navigate={source_link(source.reference, @patient_id)}
                    class="consultation__source-link"
                  >
                    Ver conducta objetivo
                  </.link>
                </:link>
              </.citation>
            </section>
          </article>
        </div>
      </div>

      <.hypothesis_panel
        :if={@state == :synthesis}
        id={"consultation-hypothesis-turn-#{@turn}"}
        hypothesis={@last_answer.hypothesis}
      />

      <div :if={@state == :no_evidence} id="consultation-no-evidence" class="empty-state">
        <p>El registro no cuenta con evidencia suficiente para responder esta consulta.</p>
      </div>

      <div :if={@state == :stale} id="consultation-stale" class="notice notice--warning">
        <p>
          La indexación del paciente está pendiente ({@pending} elementos). Reintentá cuando finalice.
        </p>
      </div>

      <div :if={@state == :provider_failure} id="consultation-provider-error" class="empty-state">
        <p>No se pudo generar una respuesta. Intentá nuevamente.</p>
      </div>
    </div>
    """
  end
end
