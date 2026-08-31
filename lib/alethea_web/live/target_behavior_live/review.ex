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

  @impl true
  def mount(%{"patient_id" => patient_id, "id" => target_behavior_id}, _session, socket) do
    professional = socket.assigns.current_professional

    case ClinicalRecord.review_timeline(professional, patient_id, target_behavior_id) do
      {:ok, items} ->
        draft_body =
          case ClinicalRecord.get_functional_analysis_draft(
                 professional,
                 patient_id,
                 target_behavior_id
               ) do
            {:ok, nil} -> ""
            {:ok, draft} -> draft.body
            {:error, _reason} -> ""
          end

        if connected?(socket) do
          Phoenix.PubSub.subscribe(Alethea.PubSub, "target_behavior:#{target_behavior_id}")
        end

        socket =
          socket
          |> assign(:page_title, "Revisión clínica")
          |> assign(:patient_id, patient_id)
          |> assign(:target_behavior_id, target_behavior_id)
          |> assign(:generation_pending, false)
          |> assign(:editing_proposal_id, nil)
          |> assign(:timeline_index, timeline_index(items))
          |> assign(:observation_form, to_form(%{"body" => ""}, as: "observation"))
          |> assign(:note_form, to_form(%{"body" => ""}, as: "note"))
          |> assign(:draft_form, to_form(%{"body" => draft_body}, as: "draft"))
          |> stream(:timeline, items)

        {:ok, socket}

      {:error, :unauthorized} ->
        {:ok,
         socket
         |> put_flash(:error, "No estás autorizado para ver esta línea de tiempo clínica.")
         |> push_navigate(to: ~p"/patients")}
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
         |> load_timeline()}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "No se pudo guardar la observación.")}
    end
  end

  @impl true
  def handle_event("suggest_patterns", _params, socket) do
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
         |> load_timeline()}

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
        accepted_text =
          socket.assigns.timeline_index
          |> Map.get(id, %{})
          |> Map.get(:text)

        {:noreply,
         socket
         |> load_timeline()
         |> merge_into_draft(accepted_text)}

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
        {:noreply, load_timeline(socket)}

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
        {:noreply,
         socket
         |> assign(:draft_form, to_form(%{"body" => body}, as: "draft"))
         |> put_flash(:info, "Borrador guardado.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "No se pudo guardar el borrador.")}
    end
  end

  @impl true
  def handle_event("create_note", %{"note" => %{"body" => body}}, socket) do
    professional = socket.assigns.current_professional
    patient_id = socket.assigns.patient_id

    case ClinicalRecord.create_clinical_note(professional, patient_id, body) do
      {:ok, _note} ->
        {:noreply,
         socket
         |> assign(:note_form, to_form(%{"body" => ""}, as: "note"))
         |> put_flash(:info, "Nota clínica creada.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "No se pudo crear la nota clínica.")}
    end
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

  @impl true
  def handle_info({:ai_proposals_failed, _reason}, socket) do
    {:noreply,
     socket
     |> assign(:generation_pending, false)
     |> put_flash(:error, "La generación de patrones de IA falló.")}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp load_timeline(socket) do
    professional = socket.assigns.current_professional
    patient_id = socket.assigns.patient_id
    target_behavior_id = socket.assigns.target_behavior_id

    case ClinicalRecord.review_timeline(professional, patient_id, target_behavior_id) do
      {:ok, items} ->
        socket
        |> assign(:timeline_index, timeline_index(items))
        |> stream(:timeline, items, reset: true)

      {:error, _reason} ->
        socket
    end
  end

  defp timeline_index(items), do: Map.new(items, &{&1.id, &1})

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

  defp merge_into_draft(socket, nil), do: socket

  defp merge_into_draft(socket, proposal_text) do
    professional = socket.assigns.current_professional
    patient_id = socket.assigns.patient_id
    target_behavior_id = socket.assigns.target_behavior_id

    current_body = socket.assigns.draft_form[:body].value || ""
    new_body = String.trim(current_body <> "\n" <> proposal_text)

    case ClinicalRecord.upsert_functional_analysis_draft(
           professional,
           patient_id,
           target_behavior_id,
           new_body
         ) do
      {:ok, _draft} -> assign(socket, :draft_form, to_form(%{"body" => new_body}, as: "draft"))
      {:error, _reason} -> socket
    end
  end

  defp review_item_class(:consultation_evidence), do: "review-item--evidence"
  defp review_item_class(:clinician_observation), do: "review-item--observation"
  defp review_item_class(:ai_proposal), do: "review-item--proposal"

  defp kind_label(:consultation_evidence), do: "Evidencia citada"
  defp kind_label(:clinician_observation), do: "Observación del clínico"
  defp kind_label(:ai_proposal), do: "Propuesta de IA"

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
            id="suggest-patterns"
            phx-click="suggest_patterns"
            disabled={@generation_pending}
            class="button-secondary button-secondary--sm"
          >
            <.icon name="hero-presentation-chart-line" class="size-4" style="margin-right:6px;" />
            {if @generation_pending, do: "Generando patrones…", else: "Sugerir patrones (IA)"}
          </button>
        </:actions>
      </.header>

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

          <p class="review-item__text">{item.text}</p>

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

      <div class="review-observation">
        <h2 class="pt-h2">Agregar observación clínica</h2>
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
        <.form for={@draft_form} id="draft-form" phx-submit="save_draft">
          <.input field={@draft_form[:body]} type="textarea" label="Análisis funcional (editable)" />
          <div class="form-actions">
            <button type="submit" class="button-primary button-primary--sm">Guardar borrador</button>
          </div>
        </.form>
      </div>

      <div class="review-note">
        <h2 class="pt-h2">Crear nota clínica</h2>
        <p class="pt-muted">
          Acción explícita y separada — no se crea automáticamente al aceptar una propuesta ni al
          guardar el borrador.
        </p>
        <.form for={@note_form} id="note-form" phx-submit="create_note">
          <.input field={@note_form[:body]} type="textarea" label="Contenido de la nota clínica" />
          <div class="form-actions">
            <button type="submit" class="button-primary button-primary--sm">
              Crear nota clínica
            </button>
          </div>
        </.form>
      </div>
    </div>
    """
  end
end
