defmodule AletheaWeb.SessionRecordingLiveTest do
  use AletheaWeb.ConnCase, async: false
  use Oban.Testing, repo: Alethea.Repo

  import Alethea.RagFixtures
  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Alethea.ClinicalRecord
  alias Alethea.ClinicalRecord.{SessionRecording, SessionRecordingChunk}
  alias Alethea.Repo
  alias Alethea.TranscriptionStub
  alias AletheaJobs.SessionTranscriptionWorker

  setup [:register_and_log_in_professional]

  setup %{professional: professional} do
    TranscriptionStub.install(%{text: "", language: "es", duration: nil, segments: []})
    %{patient: create_patient!(professional)}
  end

  # A finished recording with one chunk, waiting for transcription.
  defp create_recording!(professional, patient) do
    {:ok, recording} =
      ClinicalRecord.start_session_recording(professional, patient.id, %{
        consent: true,
        content_type: "audio/webm"
      })

    :ok =
      ClinicalRecord.append_session_recording_chunk(
        professional,
        patient.id,
        recording.id,
        0,
        "audio-bytes"
      )

    {:ok, recording} =
      ClinicalRecord.finish_session_recording(professional, patient.id, recording.id)

    recording
  end

  defp confirm_consent(view) do
    view
    |> form("#consent-form", %{"consent" => %{"confirmed" => "true"}})
    |> render_change()
  end

  defp chunk_seqs(recording_id) do
    Repo.all(
      from c in SessionRecordingChunk,
        where: c.session_recording_id == ^recording_id,
        order_by: c.seq,
        select: c.seq
    )
  end

  defp transcribe!(recording) do
    :ok = perform_job(SessionTranscriptionWorker, %{"session_recording_id" => recording.id})
  end

  test "the dashboard links to the patient's recorded sessions", %{conn: conn, patient: patient} do
    {:ok, view, _html} = live(conn, ~p"/dashboard/patients/#{patient.id}")

    assert view
           |> element("#patient-sessions-link")
           |> render() =~ ~s(href="/patients/#{patient.id}/sessions")
  end

  test "redirects a non-treating professional", %{patient: patient} do
    other_conn = log_in_professional(build_conn(), create_professional!())

    assert {:error, {:live_redirect, %{to: "/patients"}}} =
             live(other_conn, ~p"/patients/#{patient.id}/sessions")
  end

  test "renders the page with capture disabled until consent is confirmed, without uploads", %{
    conn: conn,
    patient: patient
  } do
    {:ok, view, html} = live(conn, ~p"/patients/#{patient.id}/sessions")

    assert html =~ "Sesiones grabadas · #{patient.alias}"
    assert has_element?(view, "#back-to-dashboard-link[href='/dashboard/patients/#{patient.id}']")
    assert has_element?(view, "#session-recordings-empty")
    assert has_element?(view, "#session-recorder[data-enabled='false']")
    refute has_element?(view, "input[type=file]")
    refute html =~ "subí"
    refute html =~ "Subí"
    refute has_element?(view, "#transcription-disabled-notice")

    confirm_consent(view)

    assert has_element?(view, "#session-recorder[data-enabled='true']")
  end

  test "start, chunk and finish stream a recording into transcription", %{
    conn: conn,
    professional: professional,
    patient: patient
  } do
    {:ok, view, _html} = live(conn, ~p"/patients/#{patient.id}/sessions")
    confirm_consent(view)
    hook = element(view, "#session-recorder")

    render_hook(hook, "start", %{"content_type" => "audio/webm;codecs=opus"})
    assert [%SessionRecording{} = recording] = Repo.all(SessionRecording)
    assert_reply(view, %{id: id})
    assert id == recording.id
    assert recording.status == "recording"
    assert recording.content_type == "audio/webm;codecs=opus"
    assert recording.professional_id == professional.id
    assert has_element?(view, "#recordings-#{id}", "Grabando…")
    assert has_element?(view, "#recording-live-#{id}", "El audio se guarda")
    refute has_element?(view, "#session-recordings-empty")

    render_hook(hook, "chunk", %{"id" => id, "seq" => 0, "data" => Base.encode64("AAA")})
    assert_reply(view, %{ok: true, seq: 0})
    # A resend after a reconnect is acknowledged without a duplicate.
    render_hook(hook, "chunk", %{"id" => id, "seq" => 0, "data" => Base.encode64("AAA")})
    assert_reply(view, %{ok: true, seq: 0})
    render_hook(hook, "chunk", %{"id" => id, "seq" => 1, "data" => Base.encode64("BBB")})
    assert_reply(view, %{ok: true, seq: 1})
    assert chunk_seqs(id) == [0, 1]

    render_hook(hook, "chunk", %{"id" => id, "seq" => 2, "data" => "not base64!"})
    assert_reply(view, %{error: "invalid_chunk"})
    assert chunk_seqs(id) == [0, 1]

    render_hook(hook, "finish", %{"id" => id})
    assert_reply(view, %{ok: true})

    assert Repo.get!(SessionRecording, id).status == "transcribing"
    assert_enqueued(worker: SessionTranscriptionWorker, args: %{"session_recording_id" => id})
    assert has_element?(view, "#recordings-#{id}", "Transcribiendo")

    render_hook(hook, "chunk", %{"id" => id, "seq" => 2, "data" => Base.encode64("late")})
    assert_reply(view, %{error: "not_recording"})
  end

  test "start without consent stores nothing", %{conn: conn, patient: patient} do
    {:ok, view, _html} = live(conn, ~p"/patients/#{patient.id}/sessions")

    view
    |> element("#session-recorder")
    |> render_hook("start", %{"content_type" => "audio/webm"})

    assert_reply(view, %{error: "consent_required"})
    assert Repo.aggregate(SessionRecording, :count) == 0
  end

  test "chunks and finish for another patient's recording are refused", %{
    conn: conn,
    patient: patient
  } do
    other_professional = create_professional!()
    other_patient = create_patient!(other_professional)

    {:ok, foreign} =
      ClinicalRecord.start_session_recording(other_professional, other_patient.id, %{
        consent: true,
        content_type: "audio/webm"
      })

    {:ok, view, _html} = live(conn, ~p"/patients/#{patient.id}/sessions")
    hook = element(view, "#session-recorder")

    render_hook(hook, "chunk", %{"id" => foreign.id, "seq" => 0, "data" => Base.encode64("AAA")})
    assert_reply(view, %{error: "invalid_chunk"})

    render_hook(hook, "finish", %{"id" => foreign.id})
    assert_reply(view, %{error: "finish_failed"})

    assert chunk_seqs(foreign.id) == []
    assert Repo.get!(SessionRecording, foreign.id).status == "recording"
  end

  test "a recording left by a previous page load shows it was interrupted", %{
    conn: conn,
    professional: professional,
    patient: patient
  } do
    {:ok, recording} =
      ClinicalRecord.start_session_recording(professional, patient.id, %{
        consent: true,
        content_type: "audio/webm"
      })

    {:ok, view, _html} = live(conn, ~p"/patients/#{patient.id}/sessions")

    assert has_element?(
             view,
             "#recording-live-#{recording.id}",
             "Grabación interrumpida: se procesará automáticamente"
           )
  end

  test "status changes arrive live", %{conn: conn, professional: professional, patient: patient} do
    {:ok, view, _html} = live(conn, ~p"/patients/#{patient.id}/sessions")
    recording = create_recording!(professional, patient)

    assert render(view) =~ "Transcribiendo"
    assert has_element?(view, "#recordings-#{recording.id}")
  end

  test "a diarized recording asks who is who and then shows the transcript", %{
    conn: conn,
    professional: professional,
    patient: patient
  } do
    TranscriptionStub.set_result(%{
      text: "¿Cómo dormiste? Mal, me desperté varias veces.",
      language: "es",
      duration: 75.0,
      segments: [
        %{start: 0.0, end: 2.0, text: "¿Cómo dormiste?", speaker: 0},
        %{start: 62.0, end: 75.0, text: "Mal, me desperté varias veces.", speaker: 1}
      ]
    })

    recording = create_recording!(professional, patient)
    transcribe!(recording)

    {:ok, view, _html} = live(conn, ~p"/patients/#{patient.id}/sessions")
    assert has_element?(view, "#recordings-#{recording.id}", "Falta identificar hablantes")

    view |> element("#show-speakers-#{recording.id}") |> render_click()

    assert has_element?(view, "#speaker-#{recording.id}-0", "¿Cómo dormiste?")
    assert has_element?(view, "#speaker-#{recording.id}-1", "Mal, me desperté varias veces.")

    view
    |> form("#speakers-form-#{recording.id}", %{
      "speakers" => %{"0" => "therapist", "1" => "patient"}
    })
    |> render_submit()

    assert has_element?(view, "#recordings-#{recording.id}", "Lista")
    assert Repo.get!(SessionRecording, recording.id).status == "ready"

    view |> element("#show-transcript-#{recording.id}") |> render_click()

    transcript = view |> element("#transcript-#{recording.id}") |> render()
    assert transcript =~ "00:00"
    assert transcript =~ "Profesional"
    assert transcript =~ "¿Cómo dormiste?"
    assert transcript =~ "01:02"
    assert transcript =~ "Paciente"
  end

  test "an unattributed transcript shows the Sesión label", %{
    conn: conn,
    professional: professional,
    patient: patient
  } do
    TranscriptionStub.set_result(%{
      text: "Una sola voz.",
      language: "es",
      duration: 3.0,
      segments: [%{start: 0.0, end: 3.0, text: "Una sola voz.", speaker: nil}]
    })

    recording = create_recording!(professional, patient)
    transcribe!(recording)

    {:ok, view, _html} = live(conn, ~p"/patients/#{patient.id}/sessions")
    view |> element("#show-transcript-#{recording.id}") |> render_click()

    assert view |> element("#transcript-#{recording.id}") |> render() =~ "Sesión"
  end

  test "a failed recording without audio explains it cannot be retried", %{
    conn: conn,
    professional: professional,
    patient: patient
  } do
    TranscriptionStub.set_result({:error, :timeout})
    recording = create_recording!(professional, patient)

    :ok =
      perform_job(SessionTranscriptionWorker, %{"session_recording_id" => recording.id},
        attempt: 3
      )

    {:ok, view, _html} = live(conn, ~p"/patients/#{patient.id}/sessions")

    assert has_element?(view, "#recording-error-#{recording.id}", "no respondió a tiempo")
    assert has_element?(view, "#recording-error-#{recording.id}", "no se puede reintentar")
    refute has_element?(view, "#retry-recording-#{recording.id}")
  end

  test "explains when transcription is not configured", %{conn: conn, patient: patient} do
    Application.put_env(:alethea, :ai_whisper, Alethea.AI.Whisper.Disabled)

    {:ok, view, _html} = live(conn, ~p"/patients/#{patient.id}/sessions")

    assert has_element?(view, "#transcription-disabled-notice")
    assert has_element?(view, "#consent-confirmed[disabled]")
    assert has_element?(view, "#session-recorder[data-enabled='false']")
  end

  defp register_and_log_in_professional(%{conn: conn}) do
    professional = create_professional!()
    %{conn: log_in_professional(conn, professional), professional: professional}
  end

  defp log_in_professional(conn, professional) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:professional_id, professional.id)
  end
end
