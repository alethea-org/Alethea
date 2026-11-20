defmodule AletheaWeb.SessionRecordingLive.Index do
  @moduledoc """
  Patient-scoped session recordings (session-recording S2/S3/S4).

  The professional confirms the patient's consent, then records the session
  in the browser (`SessionRecorder` hook, MediaRecorder) or uploads an audio
  file. Both paths go through the `:audio` LiveView upload; the finished
  entry is stored encrypted by `ClinicalRecord.create_session_recording/3`
  and transcribed in Oban. The list follows status changes live over PubSub.
  """
  use AletheaWeb, :live_view

  alias Alethea.Accounts
  alias Alethea.AI
  alias Alethea.ClinicalRecord
  alias Alethea.ClinicalRecord.SessionRecordings

  # `audio/*` covers ogg and m4a, whose extensions the `mime` package does not
  # know (allow_upload rejects unknown extensions); the explicit extensions
  # cover files browsers report as video (webm, mp4).
  @accept ~w(audio/* .webm .mp3 .wav .mp4)
  @max_file_size 300_000_000

  @impl true
  def mount(%{"patient_id" => patient_id}, _session, socket) do
    professional = socket.assigns.current_professional

    with %{} = patient <- Accounts.get_patient_for_professional(professional.id, patient_id),
         {:ok, recordings} <- ClinicalRecord.list_session_recordings(professional, patient.id) do
      if connected?(socket) do
        Phoenix.PubSub.subscribe(Alethea.PubSub, SessionRecordings.topic(patient.id))
      end

      {:ok,
       socket
       |> assign(:page_title, "Sesiones grabadas · #{patient.alias}")
       |> assign(:patient, patient)
       |> assign(:transcription_enabled?, AI.enabled?(:ai_whisper))
       |> assign(:consent?, false)
       |> assign(:consent_form, consent_form(false))
       |> assign(:details, %{})
       |> assign(:recordings_empty?, recordings == [])
       |> stream(:recordings, recordings)
       |> allow_upload(:audio,
         accept: @accept,
         max_entries: 1,
         max_file_size: @max_file_size,
         auto_upload: true,
         progress: &handle_progress/3
       )}
    else
      _unauthorized ->
        {:ok,
         socket
         |> put_flash(:error, "No estás autorizado para ver las sesiones de este paciente.")
         |> push_navigate(to: ~p"/patients")}
    end
  end

  # ── Consent + upload ────────────────────────────────────────────────

  @impl true
  def handle_event("toggle_consent", %{"consent" => %{"confirmed" => confirmed}}, socket) do
    consent? = confirmed == "true"

    {:noreply,
     socket
     |> assign(:consent?, consent?)
     |> assign(:consent_form, consent_form(consent?))}
  end

  def handle_event("validate_upload", _params, socket), do: {:noreply, socket}

  def handle_event("save_upload", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :audio, ref)}
  end

  # ── Row actions ─────────────────────────────────────────────────────

  def handle_event("show_speakers", %{"id" => id}, socket) do
    %{current_professional: professional, patient: patient} = socket.assigns

    case ClinicalRecord.session_recording_speaker_samples(professional, patient.id, id) do
      {:ok, samples} ->
        {:noreply, put_detail(socket, id, {:speakers, samples})}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "No se pudieron cargar los hablantes.")}
    end
  end

  def handle_event("show_transcript", %{"id" => id}, socket) do
    %{current_professional: professional, patient: patient} = socket.assigns

    with {:ok, recording} <- ClinicalRecord.get_session_recording(professional, patient.id, id),
         transcript_id when is_binary(transcript_id) <- recording.session_transcript_id,
         {:ok, transcript} <-
           ClinicalRecord.get_session_transcript(professional, patient.id, transcript_id) do
      {:noreply, put_detail(socket, id, {:transcript, transcript.spans})}
    else
      _error -> {:noreply, put_flash(socket, :error, "No se pudo cargar la transcripción.")}
    end
  end

  def handle_event("hide_detail", %{"id" => id}, socket) do
    {:noreply, put_detail(socket, id, nil)}
  end

  def handle_event("assign_speakers", %{"recording_id" => id} = params, socket) do
    %{current_professional: professional, patient: patient} = socket.assigns
    mapping = Map.get(params, "speakers", %{})

    case ClinicalRecord.assign_session_recording_speakers(professional, patient.id, id, mapping) do
      {:ok, recording} ->
        {:noreply,
         socket
         |> assign(:details, Map.delete(socket.assigns.details, recording.id))
         |> stream_insert(:recordings, recording)
         |> put_flash(
           :info,
           "Hablantes asignados. La transcripción ya forma parte de la historia clínica."
         )}

      {:error, :invalid_speaker_mapping} ->
        {:noreply, put_flash(socket, :error, "Indicá si cada hablante sos vos o el paciente.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "No se pudieron asignar los hablantes.")}
    end
  end

  def handle_event("retry", %{"id" => id}, socket) do
    %{current_professional: professional, patient: patient} = socket.assigns

    case ClinicalRecord.retry_session_recording(professional, patient.id, id) do
      {:ok, recording} ->
        {:noreply,
         socket
         |> stream_insert(:recordings, recording)
         |> put_flash(:info, "Reintentando la transcripción.")}

      {:error, _reason} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Esta grabación ya no se puede reintentar: su audio fue eliminado."
         )}
    end
  end

  @impl true
  def handle_info({:session_recording_updated, id}, socket) do
    %{current_professional: professional, patient: patient} = socket.assigns

    case ClinicalRecord.get_session_recording(professional, patient.id, id) do
      {:ok, recording} ->
        {:noreply,
         socket
         |> assign(:recordings_empty?, false)
         |> stream_insert(:recordings, recording, at: 0)}

      {:error, _reason} ->
        {:noreply, socket}
    end
  end

  defp handle_progress(:audio, entry, socket) do
    cond do
      not entry.done? ->
        {:noreply, socket}

      not (socket.assigns.consent? and socket.assigns.transcription_enabled?) ->
        {:noreply,
         socket
         |> cancel_upload(:audio, entry.ref)
         |> put_flash(:error, "Confirmá el consentimiento del paciente antes de grabar o subir.")}

      true ->
        audio =
          consume_uploaded_entry(socket, entry, fn %{path: path} -> {:ok, File.read!(path)} end)

        save_recording(socket, audio, content_type(entry))
    end
  end

  defp save_recording(socket, audio, content_type) do
    %{current_professional: professional, patient: patient} = socket.assigns

    case ClinicalRecord.create_session_recording(professional, patient.id, %{
           audio: audio,
           content_type: content_type,
           consent: true
         }) do
      {:ok, recording} ->
        {:noreply,
         socket
         |> assign(:recordings_empty?, false)
         |> stream_insert(:recordings, recording, at: 0)
         |> put_flash(:info, "Grabación guardada. La transcripción está en curso.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "No se pudo guardar la grabación.")}
    end
  end

  defp content_type(%{client_type: type}) when is_binary(type) and type != "", do: type
  defp content_type(%{client_name: name}), do: MIME.from_path(name)

  defp put_detail(socket, id, detail) do
    %{current_professional: professional, patient: patient} = socket.assigns

    details =
      if detail,
        do: Map.put(socket.assigns.details, id, detail),
        else: Map.delete(socket.assigns.details, id)

    socket = assign(socket, :details, details)

    case ClinicalRecord.get_session_recording(professional, patient.id, id) do
      {:ok, recording} -> stream_insert(socket, :recordings, recording)
      {:error, _reason} -> socket
    end
  end

  defp consent_form(confirmed?),
    do: to_form(%{"confirmed" => to_string(confirmed?)}, as: "consent")

  # ── View helpers ────────────────────────────────────────────────────

  defp status_label("transcribing"), do: "Transcribiendo"
  defp status_label("needs_speakers"), do: "Falta identificar hablantes"
  defp status_label("ready"), do: "Lista"
  defp status_label("failed"), do: "Falló"

  defp status_class("transcribing"), do: "pt-pill--neutral"
  defp status_class("needs_speakers"), do: "pt-pill--warn"
  defp status_class("ready"), do: "pt-pill--ok"
  defp status_class("failed"), do: "pt-pill--danger"

  defp error_message("provider_timeout"),
    do: "El servicio de transcripción no respondió a tiempo."

  defp error_message("transcription_disabled"), do: "La transcripción no está configurada."
  defp error_message("empty_transcript"), do: "No se detectó habla en la grabación."
  defp error_message("audio_unavailable"), do: "El audio de la grabación no estaba disponible."
  defp error_message(_code), do: "El servicio de transcripción devolvió un error."

  defp speaker_label("patient"), do: "Paciente"
  defp speaker_label("therapist"), do: "Profesional"
  defp speaker_label(_unknown), do: "Sesión"

  defp timestamp(seconds) when is_number(seconds) do
    total = trunc(seconds)
    minutes = div(total, 60) |> Integer.to_string() |> String.pad_leading(2, "0")
    secs = rem(total, 60) |> Integer.to_string() |> String.pad_leading(2, "0")
    "#{minutes}:#{secs}"
  end

  defp format_datetime(%DateTime{} = datetime), do: Calendar.strftime(datetime, "%d/%m/%Y %H:%M")

  defp format_duration(nil), do: nil
  defp format_duration(seconds), do: timestamp(seconds)

  defp upload_error_message(:too_large), do: "El archivo supera los 300 MB."

  defp upload_error_message(:not_accepted),
    do: "Formato no admitido. Usá webm, ogg, mp3, m4a, wav o mp4."

  defp upload_error_message(:too_many_files), do: "Subí un archivo por vez."
  defp upload_error_message(_error), do: "No se pudo subir el archivo."

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns, :capture_enabled?, assigns.consent? and assigns.transcription_enabled?)

    ~H"""
    <div class="session-recordings" style="max-width: 840px; margin: 0 auto; padding: 24px;">
      <div style="margin-bottom: 20px;">
        <.link
          id="back-to-dashboard-link"
          navigate={~p"/dashboard/patients/#{@patient.id}"}
          class="button-secondary button-secondary--sm"
          style="margin-bottom: 8px; display: inline-flex; align-items: center; gap: 4px;"
        >
          <.icon name="hero-chevron-left" class="size-4" />
          <span>Volver al dashboard</span>
        </.link>
        <h1 class="pt-h1">Sesiones grabadas · {@patient.alias}</h1>
        <p class="pt-muted">
          Grabá o subí una sesión. La transcripción se suma a la historia clínica del paciente y el audio se elimina al terminar.
        </p>
      </div>

      <div class="pt-card" style="margin-bottom: 28px;">
        <div class="pt-card__head">
          <span class="pt-h2">Nueva sesión</span>
        </div>
        <div class="pt-card__body">
          <div
            :if={!@transcription_enabled?}
            id="transcription-disabled-notice"
            class="flash flash--info"
            style="margin-bottom: 16px;"
          >
            <.icon name="hero-information-circle" class="flash__icon" />
            <div>
              <p class="flash__title">Transcripción no configurada</p>
              <p class="flash__msg">
                Este entorno no tiene un servicio de transcripción configurado, así que no se pueden grabar ni subir sesiones.
              </p>
            </div>
          </div>

          <.form for={@consent_form} id="consent-form" phx-change="toggle_consent">
            <.input
              id="consent-confirmed"
              field={@consent_form[:confirmed]}
              type="checkbox"
              label="El paciente dio su consentimiento para grabar la sesión"
              disabled={!@transcription_enabled?}
            />
          </.form>

          <div
            id="session-recorder"
            phx-hook="SessionRecorder"
            data-enabled={to_string(@capture_enabled?)}
            class="session-recorder"
          >
            <div id="session-recorder-controls" phx-update="ignore" class="session-recorder__controls">
              <button
                type="button"
                class="button-primary button-primary--sm"
                data-recorder-action="start"
                disabled
              >
                Grabar
              </button>
              <button
                type="button"
                class="button-secondary button-secondary--sm"
                data-recorder-action="pause"
                disabled
              >
                Pausar
              </button>
              <button
                type="button"
                class="button-secondary button-secondary--sm"
                data-recorder-action="stop"
                disabled
              >
                Finalizar
              </button>
              <span class="session-recorder__elapsed" data-recorder-elapsed>00:00</span>
              <span class="pt-muted session-recorder__status" data-recorder-status></span>
            </div>
          </div>

          <form
            id="upload-form"
            phx-change="validate_upload"
            phx-submit="save_upload"
            class="session-recorder__upload"
          >
            <label for={@uploads.audio.ref} class="pt-eyebrow">O subí un archivo de audio</label>
            <.live_file_input upload={@uploads.audio} disabled={!@capture_enabled?} />
            <div :for={entry <- @uploads.audio.entries} id={"upload-entry-#{entry.ref}"}>
              <span>{entry.client_name} · {entry.progress}%</span>
              <button
                type="button"
                class="button-secondary button-secondary--sm"
                phx-click="cancel_upload"
                phx-value-ref={entry.ref}
              >
                Cancelar
              </button>
              <p :for={err <- upload_errors(@uploads.audio, entry)} class="pt-muted">
                {upload_error_message(err)}
              </p>
            </div>
            <p :for={err <- upload_errors(@uploads.audio)} class="pt-muted">
              {upload_error_message(err)}
            </p>
          </form>
        </div>
      </div>

      <div>
        <h2 class="pt-h2" style="margin-bottom: 14px;">Grabaciones</h2>

        <div :if={@recordings_empty?} id="session-recordings-empty" class="empty-state">
          <.icon name="hero-chat-bubble-left-right" class="empty-state__icon" />
          <p class="empty-state__title">Sin sesiones grabadas</p>
          <p class="empty-state__text">Las sesiones que grabes o subas aparecen acá.</p>
        </div>

        <div
          id="session-recordings-list"
          phx-update="stream"
          style="display: flex; flex-direction: column; gap: 16px;"
        >
          <div :for={{dom_id, recording} <- @streams.recordings} id={dom_id} class="pt-card">
            <div
              class="pt-card__head"
              style="display: flex; justify-content: space-between; align-items: center; gap: 8px;"
            >
              <div style="display: flex; align-items: center; gap: 8px;">
                <span class={"pt-pill " <> status_class(recording.status)}>
                  {status_label(recording.status)}
                </span>
                <span :if={format_duration(recording.audio_duration_seconds)} class="pt-muted">
                  {format_duration(recording.audio_duration_seconds)}
                </span>
              </div>
              <span class="pt-eyebrow" style="margin: 0;">
                {format_datetime(recording.recorded_at)}
              </span>
            </div>

            <div class="pt-card__body">
              <%= case recording.status do %>
                <% "transcribing" -> %>
                  <p class="pt-muted" style="margin: 0;">
                    Transcribiendo la sesión. Esta lista se actualiza sola.
                  </p>
                <% "needs_speakers" -> %>
                  <.speaker_form
                    recording={recording}
                    detail={Map.get(@details, recording.id)}
                  />
                <% "ready" -> %>
                  <.transcript_view recording={recording} detail={Map.get(@details, recording.id)} />
                <% "failed" -> %>
                  <p id={"recording-error-#{recording.id}"} style="margin: 0;">
                    {error_message(recording.error_code)}
                    <%= if SessionRecordings.retryable?(recording) do %>
                      <button
                        type="button"
                        id={"retry-recording-#{recording.id}"}
                        class="button-secondary button-secondary--sm"
                        phx-click="retry"
                        phx-value-id={recording.id}
                      >
                        Reintentar
                      </button>
                    <% else %>
                      <span class="pt-muted">
                        El audio ya se eliminó, así que no se puede reintentar. Volvé a grabar o subir la sesión.
                      </span>
                    <% end %>
                  </p>
              <% end %>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :recording, :map, required: true
  attr :detail, :any, default: nil

  defp speaker_form(assigns) do
    ~H"""
    <%= case @detail do %>
      <% {:speakers, samples} -> %>
        <form
          id={"speakers-form-#{@recording.id}"}
          phx-submit="assign_speakers"
          class="session-speakers"
        >
          <input type="hidden" name="recording_id" value={@recording.id} />
          <p class="pt-muted" style="margin-top: 0;">
            Indicá quién habla en cada caso. Si hay más de dos voces, marcá cada una como vos o como el paciente.
          </p>
          <fieldset
            :for={%{speaker: speaker, samples: lines} <- samples}
            id={"speaker-#{@recording.id}-#{speaker}"}
            class="session-speakers__speaker"
          >
            <legend class="pt-eyebrow">Hablante {speaker + 1}</legend>
            <blockquote :for={line <- lines} class="session-speakers__sample">{line}</blockquote>
            <div style="display: flex; gap: 16px;">
              <label
                :for={{value, label} <- [{"therapist", "Vos (profesional)"}, {"patient", "Paciente"}]}
                style="display: inline-flex; align-items: center; gap: 6px; font-size: 14px;"
              >
                <input
                  type="radio"
                  id={"speaker-#{@recording.id}-#{speaker}-#{value}"}
                  name={"speakers[#{speaker}]"}
                  value={value}
                  required
                />
                {label}
              </label>
            </div>
          </fieldset>
          <div class="form-actions" style="margin-top: 12px;">
            <button type="submit" class="button-primary button-primary--sm">
              Guardar hablantes
            </button>
          </div>
        </form>
      <% _ -> %>
        <p style="margin: 0;">
          Se detectaron varias voces. Indicá quién es quién para sumar la transcripción a la historia clínica.
          <button
            type="button"
            id={"show-speakers-#{@recording.id}"}
            class="button-primary button-primary--sm"
            phx-click="show_speakers"
            phx-value-id={@recording.id}
          >
            Identificar hablantes
          </button>
        </p>
    <% end %>
    """
  end

  attr :recording, :map, required: true
  attr :detail, :any, default: nil

  defp transcript_view(assigns) do
    ~H"""
    <%= case @detail do %>
      <% {:transcript, spans} -> %>
        <div id={"transcript-#{@recording.id}"} class="session-transcript">
          <p :for={span <- spans} class="session-transcript__span">
            <span class="session-transcript__time">{timestamp(span.start)}</span>
            <strong class="session-transcript__speaker">{speaker_label(span.speaker)}</strong>
            <span>{span.text}</span>
          </p>
          <button
            type="button"
            class="button-secondary button-secondary--sm"
            phx-click="hide_detail"
            phx-value-id={@recording.id}
          >
            Ocultar transcripción
          </button>
        </div>
      <% _ -> %>
        <button
          type="button"
          id={"show-transcript-#{@recording.id}"}
          class="button-secondary button-secondary--sm"
          phx-click="show_transcript"
          phx-value-id={@recording.id}
        >
          Ver transcripción
        </button>
    <% end %>
    """
  end
end
