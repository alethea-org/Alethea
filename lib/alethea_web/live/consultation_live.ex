defmodule AletheaWeb.ConsultationLive do
  @moduledoc """
  Chat de consulta clínica fundamentada (#227, ADR-010) — carcasa fina
  sobre `Alethea.ClinicalRecord.Rag.Consultation`. Superficie primaria
  única (D1/#221): esta vista nunca implementa una ruta de búsqueda
  paralela; hasta que `#232` entregue `Consultation.Live`, sólo consume
  `Consultation.Fake`.

  Cero persistencia (ADR-010 §6): `history` y `followup_state` viven
  únicamente en `socket.assigns` y mueren con el proceso (remount,
  navegación, logout, "nueva conversación"). Ningún handler escribe en
  `Repo`, ETS, ni audita el acceso. `current_professional` y
  `patient_id` siempre se leen de `socket.assigns`, nunca de params de
  evento.
  """
  use AletheaWeb, :live_view

  alias Alethea.ClinicalRecord.Rag.Consultation
  alias AletheaWeb.GroundedChat.FollowupState

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

    socket
    |> assign(:state, :synthesis)
    |> assign(:history, history)
    |> assign(:turn, turn + 1)
    |> assign(:last_answer, answer)
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

      <div :if={@state == :synthesis} id="consultation-synthesis">
        <p>{@last_answer.synthesis}</p>
        <ol>
          <li :for={source <- @last_answer.sources}>
            {source.excerpt}
          </li>
        </ol>
      </div>

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
