defmodule AletheaWeb.SessionRecordingLiveTest do
  use AletheaWeb.ConnCase, async: false
  use Oban.Testing, repo: Alethea.Repo

  import Alethea.RagFixtures
  import Phoenix.LiveViewTest

  alias Alethea.ClinicalRecord
  alias Alethea.ClinicalRecord.SessionRecording
  alias Alethea.Repo
  alias Alethea.TranscriptionStub
  alias AletheaJobs.SessionTranscriptionWorker

  setup [:register_and_log_in_professional]

  setup %{professional: professional} do
    TranscriptionStub.install(%{text: "", language: "es", duration: nil, segments: []})
    %{patient: create_patient!(professional)}
  end

  defp create_recording!(professional, patient) do
    {:ok, recording} =
      ClinicalRecord.create_session_recording(professional, patient.id, %{
        audio: "audio-bytes",
        content_type: "audio/webm",
        consent: true
      })

    recording
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

  test "renders the page with capture disabled until consent is confirmed", %{
    conn: conn,
    patient: patient
  } do
    {:ok, view, html} = live(conn, ~p"/patients/#{patient.id}/sessions")

    assert html =~ "Sesiones grabadas · #{patient.alias}"
    assert has_element?(view, "#back-to-dashboard-link[href='/dashboard/patients/#{patient.id}']")
    assert has_element?(view, "#session-recordings-empty")
    assert has_element?(view, "#session-recorder[data-enabled='false']")
    assert has_element?(view, "#upload-form input[type=file][disabled]")
    refute has_element?(view, "#transcription-disabled-notice")

    view
    |> form("#consent-form", %{"consent" => %{"confirmed" => "true"}})
    |> render_change()

    assert has_element?(view, "#session-recorder[data-enabled='true']")
    refute has_element?(view, "#upload-form input[type=file][disabled]")
  end

  test "uploading an audio file after consent creates a transcribing recording", %{
    conn: conn,
    professional: professional,
    patient: patient
  } do
    {:ok, view, _html} = live(conn, ~p"/patients/#{patient.id}/sessions")

    view
    |> form("#consent-form", %{"consent" => %{"confirmed" => "true"}})
    |> render_change()

    audio =
      file_input(view, "#upload-form", :audio, [
        %{name: "sesion.webm", content: "webm-audio-bytes", type: "audio/webm"}
      ])

    render_upload(audio, "sesion.webm")

    assert [%SessionRecording{} = recording] = Repo.all(SessionRecording)
    assert recording.status == "transcribing"
    assert recording.content_type == "audio/webm"
    assert recording.professional_id == professional.id

    assert_enqueued(
      worker: SessionTranscriptionWorker,
      args: %{"session_recording_id" => recording.id}
    )

    assert has_element?(view, "#recordings-#{recording.id}", "Transcribiendo")
    refute has_element?(view, "#session-recordings-empty")
  end

  test "an upload without consent stores nothing", %{conn: conn, patient: patient} do
    {:ok, view, _html} = live(conn, ~p"/patients/#{patient.id}/sessions")

    audio =
      file_input(view, "#upload-form", :audio, [
        %{name: "sesion.webm", content: "webm-audio-bytes", type: "audio/webm"}
      ])

    assert_raise ArgumentError, ~r/disabled/, fn -> render_upload(audio, "sesion.webm") end
    assert Repo.aggregate(SessionRecording, :count) == 0
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
    assert has_element?(view, "#upload-form input[type=file][disabled]")
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
