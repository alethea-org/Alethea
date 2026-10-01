defmodule AletheaWeb.ConsultationLive do
  @moduledoc """
  Chat de consulta clínica fundamentada (#227, ADR-010) — carcasa fina
  sobre `Alethea.ClinicalRecord.Rag.Consultation`. Superficie primaria
  única (D1/#221): esta vista nunca implementa una ruta de búsqueda
  paralela, y desde #234b es la única: `PatientLive.ClinicalSearch` quedó
  retirada. El contrato resuelve a `Consultation.Live` (#232) en dev y
  prod, y a `Consultation.Fake` sólo en `:test`.

  Presentación conversacional (consultation-chat-ui): cada pregunta se
  hace eco de inmediato como burbuja del usuario con indicador de tipeo
  dentro del hilo (`#consultation-retrieving`), y `handle_async/3`
  reemplaza ese turno pendiente — mismo DOM id `turn-N` — por su
  resultado: síntesis con fuentes e hipótesis por turno, o un aviso de
  error dentro del propio turno (`#consultation-no-evidence`,
  `#consultation-stale`, `#consultation-provider-error`). El hilo
  (`#consultation-thread`) existe siempre que hay turnos, también en
  turnos de error; el compositor queda fijado abajo y se deshabilita
  mientras se espera la respuesta.

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
          |> assign(:pending_turn, nil)
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
    {:noreply, start_consultation_turn(socket, query)}
  end

  # Idle-hero suggestion chips: `value-query` lands here and runs the
  # exact same path as the composer submit — one shared private
  # function, no duplicated logic.
  @impl true
  def handle_event("suggest", %{"query" => query}, socket) do
    {:noreply, start_consultation_turn(socket, query)}
  end

  @impl true
  def handle_event("new_conversation", _params, socket) do
    socket =
      socket
      |> assign(:state, :idle)
      |> assign(:pending, 0)
      |> assign(:turn, 0)
      |> assign(:pending_turn, nil)
      |> assign(:followup_state, FollowupState.reset(socket.assigns.followup_state))
      |> stream(:messages, [], reset: true)

    {:noreply, socket}
  end

  # Stale-result and revocation guards (R3-stale-async-guard-order):
  # "nueva conversación" resets `pending_turn` to nil without
  # cancelling the in-flight task — LiveView cannot cancel
  # `start_async` tasks — so a late result or exit must resolve
  # against a discarded turn instead of corrupting the reset conversation
  # or crashing the LiveView. A late unauthorized result still redirects
  # (access can be revoked mid-flight), tested before discarding.
  @impl true
  def handle_async(:answer, {:ok, {_query, {:error, :unauthorized}}}, socket) do
    {:noreply,
     socket
     |> put_flash(:error, "No estás autorizado para consultar a este paciente.")
     |> push_navigate(to: ~p"/patients")}
  end

  def handle_async(:answer, {:ok, _stale_result}, socket)
      when is_nil(socket.assigns.pending_turn) do
    {:noreply, socket}
  end

  def handle_async(:answer, {:ok, {query, result}}, socket) do
    {:noreply, apply_answer(socket, query, result)}
  end

  @impl true
  def handle_async(:answer, {:exit, _reason}, socket)
      when is_map(socket.assigns.pending_turn) do
    %{turn: turn, query: query} = socket.assigns.pending_turn

    {:noreply,
     socket
     |> assign(:state, :provider_failure)
     |> replace_turn(turn, query, :provider_failure)}
  end

  def handle_async(:answer, {:exit, _reason}, socket), do: {:noreply, socket}

  # Shared ask path (composer submit + suggestion chips). The question is
  # echoed into the message stream as a pending turn — user bubble plus
  # in-thread typing indicator, under the same DOM id `turn-N` the async
  # resolution will replace — before `start_async` fires, so it is
  # visible while the retrieval runs.
  defp start_consultation_turn(socket, query) do
    professional = socket.assigns.current_professional
    patient_id = socket.assigns.patient_id
    followup_state = socket.assigns.followup_state
    next_turn = socket.assigns.turn

    socket
    |> assign(:state, :retrieving)
    |> assign(:query_form, to_form(%{"query" => ""}, as: "consultation"))
    |> assign(:pending_turn, %{turn: next_turn, query: query})
    |> stream_insert(:messages, %{
      id: "turn-#{next_turn}",
      turn: next_turn,
      query: query,
      status: :pending,
      answer: nil,
      citations: []
    })
    |> start_async(:answer, fn ->
      {query,
       Consultation.answer(professional, patient_id, query,
         followup_state: followup_state,
         turn_index: next_turn
       )}
    end)
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
    |> replace_turn(turn, query, :synthesis, answer, citations)
  end

  defp apply_answer(socket, query, {:ok, %Consultation.Answer{outcome: :no_evidence}}) do
    socket
    |> assign(:state, :no_evidence)
    |> replace_turn(socket.assigns.turn, query, :no_evidence)
  end

  defp apply_answer(
         socket,
         query,
         {:ok, %Consultation.Answer{outcome: :stale, pending: pending}}
       ) do
    socket
    |> assign(:state, :stale)
    |> assign(:pending, pending)
    |> replace_turn(socket.assigns.turn, query, :stale)
  end

  defp apply_answer(socket, query, {:ok, %Consultation.Answer{outcome: :provider_failure}}) do
    socket
    |> assign(:state, :provider_failure)
    |> replace_turn(socket.assigns.turn, query, :provider_failure)
  end

  # Resolves a turn by replacing the pending stream item under the same
  # DOM id (`turn-N`). Error turns reuse the id on retry by design: the
  # turn counter only advances on synthesis, so a retry replaces the
  # previous error item instead of stacking a new turn.
  defp replace_turn(socket, turn, query, status, answer \\ nil, citations \\ []) do
    stream_insert(socket, :messages, %{
      id: "turn-#{turn}",
      turn: turn,
      query: query,
      status: status,
      answer: answer,
      citations: citations
    })
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
      <header class="consultation__header">
        <h1>Consulta clínica</h1>

        <button id="consultation-new-conversation" type="button" phx-click="new_conversation">
          Nueva conversación
        </button>
      </header>

      <div :if={@state == :idle and @turn == 0} id="consultation-idle" class="consultation__hero">
        <h2 class="consultation__hero-title">Consulta clínica fundamentada</h2>
        <p>Preguntá lo que quieras saber de la historia clínica del paciente.</p>

        <div class="consultation__hero-suggestions">
          <button
            type="button"
            class="consultation__suggestion"
            phx-click="suggest"
            phx-value-query="¿Cómo viene el paciente últimamente?"
          >
            ¿Cómo viene el paciente últimamente?
          </button>
          <button
            type="button"
            class="consultation__suggestion"
            phx-click="suggest"
            phx-value-query="¿Qué evidencia hay sobre el sueño?"
          >
            ¿Qué evidencia hay sobre el sueño?
          </button>
          <button
            type="button"
            class="consultation__suggestion"
            phx-click="suggest"
            phx-value-query="¿Qué conductas objetivo se registraron?"
          >
            ¿Qué conductas objetivo se registraron?
          </button>
        </div>
      </div>

      <div
        :if={@turn > 0 or @state != :idle}
        id="consultation-thread"
        class="consultation__thread"
        phx-hook="ConsultationScroll"
        aria-live="polite"
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

            <div :if={message.status == :pending} class="consultation__assistant">
              <div class="consultation__avatar" aria-hidden="true">
                <.icon name="hero-sparkles" class="size-4" />
              </div>

              <div id="consultation-retrieving" class="consultation__typing">
                <span class="consultation__typing-dots" aria-hidden="true">
                  <i></i><i></i><i></i>
                </span>
                <p>Consultando el registro clínico…</p>
              </div>
            </div>

            <section
              :if={message.status == :synthesis}
              id={"#{dom_id}-synthesis"}
              class="consultation-synthesis consultation__synthesis"
            >
              <h2 class="consultation__section-title">Síntesis basada en evidencia</h2>
              <p>{message.answer.synthesis}</p>
            </section>

            <section
              :if={message.status == :synthesis}
              id={"#{dom_id}-sources"}
              class="consultation__sources-panel"
            >
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

            <.hypothesis_panel
              :if={message.answer && message.answer.hypothesis}
              id={"turn-#{message.turn}-hypothesis"}
              hypothesis={message.answer.hypothesis}
            />

            <div :if={message.status == :no_evidence} class="consultation__assistant">
              <div class="consultation__avatar" aria-hidden="true">
                <.icon name="hero-sparkles" class="size-4" />
              </div>

              <div id="consultation-no-evidence" class="consultation__notice">
                <p>El registro no cuenta con evidencia suficiente para responder esta consulta.</p>
              </div>
            </div>

            <div :if={message.status == :stale} class="consultation__assistant">
              <div class="consultation__avatar" aria-hidden="true">
                <.icon name="hero-sparkles" class="size-4" />
              </div>

              <div id="consultation-stale" class="consultation__notice consultation__notice--warning">
                <p>
                  La indexación del paciente está pendiente ({@pending} elementos). Reintentá cuando finalice.
                </p>
              </div>
            </div>

            <div :if={message.status == :provider_failure} class="consultation__assistant">
              <div class="consultation__avatar" aria-hidden="true">
                <.icon name="hero-sparkles" class="size-4" />
              </div>

              <div id="consultation-provider-error" class="consultation__notice">
                <p>No se pudo generar una respuesta. Intentá nuevamente.</p>
              </div>
            </div>
          </article>
        </div>
      </div>

      <.form
        for={@query_form}
        id="consultation-ask-form"
        phx-submit="ask"
        class="consultation__composer"
        phx-hook="ConsultationComposer"
      >
        <.input
          field={@query_form[:query]}
          type="textarea"
          rows="1"
          placeholder="Preguntá sobre la historia clínica…"
          aria-label="Preguntá sobre la historia clínica"
        />
        <button type="submit" class="consultation__send" disabled={@state == :retrieving}>
          <.icon name="hero-arrow-up" class="size-5" />
          <span class="sr-only">Enviar</span>
        </button>
      </.form>
    </div>
    """
  end
end
