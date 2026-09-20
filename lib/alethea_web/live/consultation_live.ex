defmodule AletheaWeb.ConsultationLive do
  @moduledoc """
  Chat de consulta clínica fundamentada (#227, ADR-010) — carcasa fina
  sobre `Alethea.ClinicalRecord.Rag.Consultation`. Superficie primaria
  única (D1/#221): esta vista nunca implementa una ruta de búsqueda
  paralela, y desde #234b es la única: `PatientLive.ClinicalSearch` quedó
  retirada. El contrato resuelve a `Consultation.Live` (#232) en dev y
  prod, y a `Consultation.Fake` sólo en `:test`.

  Cero persistencia (ADR-010 §6): `history` y `followup_state` viven
  únicamente en `socket.assigns` y mueren con el proceso (remount,
  navegación, logout, "nueva conversación"). Ningún handler escribe en
  `Repo`, ETS, ni audita el acceso. `current_professional` y
  `patient_id` siempre se leen de `socket.assigns`, nunca de params de
  evento.
  """
  use AletheaWeb, :live_view

  alias Alethea.ClinicalRecord.Rag.Consultation
  alias AletheaWeb.GroundedChat.{FollowupState, SourceCitation}

  import AletheaWeb.GroundedChat.HypothesisPanel, only: [hypothesis_panel: 1]

  @history_limit 6

  @impl true
  def mount(%{"patient_id" => patient_id}, _session, socket) do
    professional = socket.assigns.current_professional

    case Consultation.open(professional, patient_id) do
      {:ok, _metadata} ->
        socket =
          socket
          |> assign(:patient_id, patient_id)
          |> assign(:history, [])
          |> assign(:state, :idle)
          |> assign(:pending, 0)
          |> assign(:turn, 0)
          |> assign(:followup_state, FollowupState.new(patient_id))
          |> assign(:query_form, to_form(%{"query" => ""}, as: "consultation"))
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
    history = socket.assigns.history

    socket =
      socket
      |> assign(:state, :retrieving)
      |> assign(:query_form, to_form(%{"query" => ""}, as: "consultation"))
      |> start_async(:answer, fn ->
        {query, Consultation.answer(professional, patient_id, query, history: history)}
      end)

    {:noreply, socket}
  end

  @impl true
  def handle_event("new_conversation", _params, socket) do
    socket =
      socket
      |> assign(:history, [])
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

    history =
      (socket.assigns.history ++
         [
           %{role: :professional, content: query},
           %{role: :assistant, content: answer.synthesis}
         ])
      |> Enum.take(-@history_limit)

    # #235c/R10 — citations for the unified `citation/1` renderer, derived
    # here (once per turn, alongside `:last_answer`) rather than
    # recomputed on every render. Same 1:1 order as `answer.sources`, so
    # the render function can zip both to recover `target_behavior_id`
    # for the "Ver conducta objetivo" link (`%Citation{}` doesn't carry it).
    citations = Enum.map(answer.sources, &SourceCitation.source_to_citation/1)

    socket
    |> assign(:state, :synthesis)
    |> assign(:history, history)
    |> assign(:turn, turn + 1)
    |> assign(:last_answer, answer)
    |> assign(:citations, citations)
    |> stream_insert(:messages, %{id: "turn-#{turn}", turn: turn, query: query, answer: answer})
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
      <div :if={@state == :idle} id="consultation-idle" class="empty-state">
        <p>Escribí una pregunta sobre la historia clínica del paciente.</p>
      </div>
      
      <div :if={@state == :retrieving} id="consultation-retrieving" class="empty-state">
        <p>Buscando evidencia en el registro…</p>
      </div>
      
      <section
        :if={@state == :synthesis}
        id="consultation-synthesis"
        class="consultation__synthesis"
      >
        <h2 class="consultation__section-title">Síntesis basada en evidencia</h2>
        
        <p>{@last_answer.synthesis}</p>
      </section>
      
      <section
        :if={@state == :synthesis}
        id="consultation-sources"
        class="consultation__sources-panel"
      >
        <h2 class="consultation__section-title">Fuentes</h2>

        <.citation
          :for={{cite, source} <- Enum.zip(@citations, @last_answer.sources)}
          citation={cite}
          id={"citation-sources-#{cite.source_ref}"}
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
