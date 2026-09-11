defmodule AletheaWeb.ConsultationLive do
  @moduledoc """
  Grounded clinical consultation chat — authorized per-patient shell
  (#227, sdd/grounded-clinical-chat-initial).

  Thin adapter over `Alethea.ClinicalRecord.Rag.Consultation`: it only ever
  calls that context's public functions (`open/2`, `answer/4`) and never
  `Repo`, `PatientVault`, `Retrieval`, or any `Accounts.load_*` helper
  directly. `mount/3` authorizes `current_professional` (from the
  `:require_authenticated_professional` `on_mount`) against the patient via
  `Consultation.open/2`; an unauthorized professional is redirected to
  `/patients` before any content renders. Every turn re-reads
  `socket.assigns.current_professional` — no professional id ever comes
  from params.

  Conversation state (message stream + bounded follow-up `history`) lives
  ONLY in socket assigns. Nothing is persisted: no ETS, no DB row, no
  `Alethea.AI.ConversationMemory`, no audit/access record. It dies on
  remount, navigation, and "nueva conversación" by construction. This
  slice consumes `Consultation.Fake` only.
  """
  use AletheaWeb, :live_view

  alias Alethea.ClinicalRecord.Rag.Consultation

  @history_limit 6

  @impl true
  def mount(%{"patient_id" => patient_id}, _session, socket) do
    professional = socket.assigns.current_professional

    case Consultation.open(professional, patient_id) do
      {:ok, %{chunk_count: _, freshness: _}} ->
        socket =
          socket
          |> assign(:page_title, "Consulta clínica")
          |> assign(:patient_id, patient_id)
          |> assign(:history, [])
          |> assign(:state, :idle)
          |> assign(:turn, 0)
          |> assign(:pending_turn, nil)
          |> assign(:query_form, to_form(%{"query" => ""}, as: "consultation"))
          |> stream(:messages, [])

        {:ok, socket}

      {:error, :unauthorized} ->
        {:ok,
         socket
         |> put_flash(:error, "No estás autorizado para consultar el historial de este paciente.")
         |> push_navigate(to: ~p"/patients")}
    end
  end

  @impl true
  def handle_event("ask", %{"consultation" => %{"query" => query}}, socket) do
    trimmed = String.trim(query)

    if trimmed == "" do
      {:noreply, socket}
    else
      professional = socket.assigns.current_professional
      patient_id = socket.assigns.patient_id
      history = socket.assigns.history
      turn = socket.assigns.turn + 1

      socket =
        socket
        |> assign(:state, :retrieving)
        |> assign(:turn, turn)
        |> assign(:pending_turn, %{turn: turn, query: trimmed})
        |> assign(:query_form, to_form(%{"query" => ""}, as: "consultation"))
        |> stream_insert(:messages, %{
          id: "q-#{turn}",
          role: :question,
          turn: turn,
          content: trimmed
        })
        |> start_async(:answer, fn ->
          Consultation.answer(professional, patient_id, trimmed, history: history)
        end)

      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("new_conversation", _params, socket) do
    socket =
      socket
      |> assign(:state, :idle)
      |> assign(:turn, 0)
      |> assign(:history, [])
      |> assign(:pending_turn, nil)
      |> assign(:query_form, to_form(%{"query" => ""}, as: "consultation"))
      |> stream(:messages, [], reset: true)

    {:noreply, socket}
  end

  @impl true
  def handle_async(:answer, {:ok, {:ok, answer}}, socket) do
    %{turn: turn, query: query} = socket.assigns.pending_turn

    message = %{
      id: "a-#{turn}",
      role: :answer,
      turn: turn,
      outcome: answer.outcome,
      outcome_slug: outcome_slug(answer.outcome),
      synthesis: answer.synthesis,
      sources: answer.sources,
      pending: answer.pending
    }

    {:noreply,
     socket
     |> assign(:state, :idle)
     |> assign(:pending_turn, nil)
     |> assign(:history, extend_history(socket.assigns.history, query, answer))
     |> stream_insert(:messages, message)}
  end

  def handle_async(:answer, {:ok, {:error, :unauthorized}}, socket) do
    {:noreply,
     socket
     |> put_flash(:error, "No estás autorizado para consultar el historial de este paciente.")
     |> push_navigate(to: ~p"/patients")}
  end

  def handle_async(:answer, {:exit, _reason}, socket) do
    turn = socket.assigns.pending_turn[:turn] || socket.assigns.turn

    message = %{
      id: "a-#{turn}",
      role: :answer,
      turn: turn,
      outcome: :provider_failure,
      outcome_slug: outcome_slug(:provider_failure),
      synthesis: nil,
      sources: [],
      pending: 0
    }

    {:noreply,
     socket
     |> assign(:state, :idle)
     |> assign(:pending_turn, nil)
     |> stream_insert(:messages, message)}
  end

  # Follow-up context only — bounded, never sent to the LLM in this slice
  # and never persisted (AD6, AD11).
  defp extend_history(history, query, answer) do
    (history ++
       [
         %{role: :professional, content: query},
         %{role: :assistant, content: answer.synthesis || ""}
       ])
    |> Enum.take(-@history_limit)
  end

  defp outcome_slug(:synthesis), do: "synthesis"
  defp outcome_slug(:no_evidence), do: "no-evidence"
  defp outcome_slug(:stale), do: "stale"
  defp outcome_slug(:provider_failure), do: "provider-error"

  defp format_datetime(%DateTime{} = datetime), do: Calendar.strftime(datetime, "%d/%m/%Y %H:%M")

  @impl true
  def render(assigns) do
    ~H"""
    <div class="consultation">
      <.header>
        Consulta clínica
        <:subtitle>
          Preguntá sobre este paciente. Las respuestas se basan solo en el historial
          clínico indexado — nunca en conocimiento general.
        </:subtitle>
        <:actions>
          <button
            id="consultation-new"
            type="button"
            phx-click="new_conversation"
            class="button-secondary button-secondary--sm"
          >
            <.icon name="hero-arrow-path" class="size-4" style="margin-right:6px;" />
            Nueva conversación
          </button>
        </:actions>
      </.header>

      <ol id="consultation-messages" phx-update="stream" class="consultation__messages">
        <li
          :for={{dom_id, message} <- @streams.messages}
          id={dom_id}
          class="consultation__message"
        >
          <p :if={message.role == :question} class="consultation__question">
            {message.content}
          </p>

          <div
            :if={message.role == :answer}
            id={"consultation-#{message.outcome_slug}-#{message.turn}"}
            class={["consultation__answer", "consultation__answer--#{message.outcome_slug}"]}
          >
            <%= case message.outcome do %>
              <% :synthesis -> %>
                <section class="consultation__synthesis">
                  <h3 class="pt-h3">Síntesis basada en evidencia</h3>
                  <p>{message.synthesis}</p>
                </section>
                <ol class="consultation__sources">
                  <li :for={source <- message.sources} class="consultation__source">
                    <p class="consultation__source-excerpt">{source.excerpt}</p>
                    <span class="consultation__source-meta">
                      {source.kind} · {format_datetime(source.occurred_at)}
                    </span>
                  </li>
                </ol>
              <% :no_evidence -> %>
                <p>
                  El historial clínico indexado no respalda una respuesta a esta pregunta.
                  No se genera ninguna respuesta a partir de conocimiento general.
                </p>
              <% :stale -> %>
                <p>
                  La indexación del historial todavía está en curso ({message.pending} evento(s) pendiente(s)). Volvé a preguntar cuando la indexación termine.
                </p>
              <% :provider_failure -> %>
                <p>
                  No se pudo generar una síntesis en este momento. Intentá nuevamente.
                </p>
            <% end %>
          </div>
        </li>
      </ol>

      <div :if={@state == :retrieving} id="consultation-retrieving" class="consultation__status">
        <.icon name="hero-arrow-path" class="size-4" style="margin-right:6px;" />
        Recuperando evidencia del historial…
      </div>

      <div
        :if={@state == :idle and @turn == 0}
        id="consultation-idle"
        class="consultation__status"
      >
        <.icon name="hero-chat-bubble-left-right" class="size-4" style="margin-right:6px;" />
        Hacé una pregunta clínica sobre este paciente para comenzar.
      </div>

      <.form for={@query_form} id="consultation-form" phx-submit="ask">
        <.input field={@query_form[:query]} type="text" label="Pregunta clínica" />
        <div class="form-actions">
          <button
            type="submit"
            class="button-primary button-primary--sm"
            disabled={@state == :retrieving}
          >
            <.icon name="hero-chat-bubble-left-right" class="size-4" style="margin-right:6px;" />
            Preguntar
          </button>
        </div>
      </.form>
    </div>
    """
  end
end
