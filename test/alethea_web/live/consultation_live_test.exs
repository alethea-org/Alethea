defmodule AletheaWeb.ConsultationLiveTest do
  @moduledoc """
  `Phoenix.LiveViewTest` specs for `AletheaWeb.ConsultationLive` (#227,
  ConsultationLive shell over `Alethea.ClinicalRecord.Rag.Consultation.Fake`).

  Covers #227's acceptance scenarios: mount authorization, the six safe
  visible states driven entirely through the Fake (no real retrieval, no
  LLM), and the zero-persistence guarantee (no survival across remount,
  navigation, or "nueva conversación"; no DB/audit row is ever written).

  #234a adds the integration pass over the real pipeline
  (`Rag.Consultation.Live` + seeded chunks + `ClinicalConsultationChainMock`):
  the grounded answer must render *Síntesis basada en evidencia* and
  *Fuentes* as two visually distinct labeled sections.
  """
  # async: false — the #234a describe block swaps the global
  # `:clinical_consultation` slot through `Application.put_env/3` and runs Mox
  # in `:global` mode so the LiveView process sees the expectations. Both make
  # this module unsafe to run concurrently with anything reading those slots.
  use AletheaWeb.ConnCase, async: false

  import Alethea.RagFixtures
  import Mox
  import Phoenix.LiveViewTest

  alias Alethea.AI.ClinicalConsultationChainMock
  alias Alethea.Clinical.Message
  alias Alethea.ClinicalRecord.Rag.Consultation
  alias Alethea.Repo

  @seeded_excerpt "El paciente reporta mejoría del ánimo esta semana y mayor actividad social."
  @synthesis "Según los fragmentos citados, el paciente sostiene la mejoría del ánimo."
  @linked_excerpt "Cumplió la caminata pactada el martes por la mañana."
  @plain_excerpt "Durmió siete horas seguidas y se levantó sin alarma."
  @linked_occurred_at ~U[2026-01-15 10:00:00.000000Z]
  @plain_occurred_at ~U[2026-02-03 18:30:00.000000Z]

  setup [:register_and_log_in_professional]

  setup %{professional: professional} do
    patient = create_patient!(professional)
    on_exit(fn -> reset_fake_outcome() end)
    %{patient: patient}
  end

  describe "mount — authorization" do
    test "a non-treating professional is redirected instead of seeing any data", %{
      patient: patient
    } do
      stranger = create_professional!()
      stranger_conn = log_in_professional(build_conn(), stranger)

      set_fake_outcome(:unauthorized)

      assert {:error, {:live_redirect, %{to: "/patients"}}} =
               live(stranger_conn, ~p"/patients/#{patient.id}/consultation")
    end

    test "a treating professional reaches the idle state with no answer or error", %{
      conn: conn,
      patient: patient
    } do
      {:ok, _view, html} = live(conn, ~p"/patients/#{patient.id}/consultation")

      assert html =~ "consultation-idle"
      refute html =~ "consultation-synthesis"
      refute html =~ "consultation-provider-error"
    end
  end

  describe "safe visible states (driven through Consultation.Fake)" do
    test "retrieving renders while the async answer is pending", %{conn: conn, patient: patient} do
      {:ok, view, _html} = live(conn, ~p"/patients/#{patient.id}/consultation")

      html = submit_query(view, "¿cómo viene el paciente?")

      assert html =~ "consultation-retrieving"
    end

    test "synthesis renders the answer text and its sources", %{conn: conn, patient: patient} do
      set_fake_outcome(:synthesis)
      {:ok, view, _html} = live(conn, ~p"/patients/#{patient.id}/consultation")

      submit_query(view, "¿cómo viene el paciente?")
      html = render_async(view)

      assert html =~ "consultation-synthesis"
      assert html =~ "mejoría sostenida del ánimo"
      assert html =~ "El paciente reporta mejoría del ánimo esta semana"
    end

    test "no_evidence renders when the record does not support an answer", %{
      conn: conn,
      patient: patient
    } do
      set_fake_outcome(:no_evidence)
      {:ok, view, _html} = live(conn, ~p"/patients/#{patient.id}/consultation")

      submit_query(view, "¿algo sin evidencia?")
      html = render_async(view)

      assert html =~ "consultation-no-evidence"
      refute html =~ "consultation-synthesis"
    end

    test "stale renders the pending count and asks to retry", %{conn: conn, patient: patient} do
      set_fake_outcome(:stale, pending: 4)
      {:ok, view, _html} = live(conn, ~p"/patients/#{patient.id}/consultation")

      submit_query(view, "¿algo desactualizado?")
      html = render_async(view)

      assert html =~ "consultation-stale"
      assert html =~ "4"
    end

    test "provider_failure renders a safe state with no partial synthesis", %{
      conn: conn,
      patient: patient
    } do
      set_fake_outcome(:provider_failure)
      {:ok, view, _html} = live(conn, ~p"/patients/#{patient.id}/consultation")

      submit_query(view, "¿cómo viene el paciente?")
      html = render_async(view)

      assert html =~ "consultation-provider-error"
      refute html =~ "consultation-synthesis"
    end
  end

  describe "grounded answer over the real pipeline (#234a)" do
    setup [:use_live_consultation, :set_mox_global, :verify_on_exit!]

    test "synthesis and sources render as two distinct labeled sections", %{
      conn: conn,
      professional: professional,
      patient: patient
    } do
      insert_chunk!(professional, patient, @seeded_excerpt, near_vector())
      stub_query_embedding(near_vector())

      expect(ClinicalConsultationChainMock, :run, fn %{question: _question, excerpts: excerpts} ->
        assert excerpts != []
        {:ok, %{synthesis: @synthesis}}
      end)

      {:ok, view, _html} = live(conn, ~p"/patients/#{patient.id}/consultation")

      submit_query(view, "¿cómo viene el paciente?")
      html = render_async(view)

      assert has_element?(view, "section.consultation__synthesis")
      assert has_element?(view, "ol.consultation__sources")

      synthesis_html = view |> element("section.consultation__synthesis") |> render()
      sources_html = view |> element("ol.consultation__sources") |> render()

      assert synthesis_html =~ @synthesis
      refute synthesis_html =~ @seeded_excerpt

      assert sources_html =~ @seeded_excerpt
      refute sources_html =~ @synthesis

      assert html =~ "Síntesis basada en evidencia"
      assert html =~ "Fuentes"
    end

    test "each source renders its excerpt, kind, date and reference", %{
      conn: conn,
      professional: professional,
      patient: patient
    } do
      target_behavior = create_target_behavior!(professional, patient)
      clear_pending_outbox!(patient)

      insert_chunk!(professional, patient, @linked_excerpt, near_vector(),
        source_resource_type: "clinician_observation",
        target_behavior_id: target_behavior.id,
        occurred_at: @linked_occurred_at
      )

      insert_chunk!(professional, patient, @plain_excerpt, near_vector(),
        source_resource_type: "clinical_note",
        occurred_at: @plain_occurred_at
      )

      stub_query_embedding(near_vector())

      expect(ClinicalConsultationChainMock, :run, fn _params ->
        {:ok, %{synthesis: @synthesis}}
      end)

      {:ok, view, _html} = live(conn, ~p"/patients/#{patient.id}/consultation")

      submit_query(view, "¿qué hizo el paciente esta semana?")
      render_async(view)

      linked_item = view |> element("ol.consultation__sources li", @linked_excerpt) |> render()

      assert linked_item =~ @linked_excerpt
      assert linked_item =~ "Observación del clínico"
      assert linked_item =~ "15/01/2026 10:00"

      assert linked_item =~
               ~s(href="/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      plain_item = view |> element("ol.consultation__sources li", @plain_excerpt) |> render()

      assert plain_item =~ @plain_excerpt
      assert plain_item =~ "Nota clínica"
      assert plain_item =~ "03/02/2026 18:30"
      refute plain_item =~ "<a"
    end

    test "a patient_message source renders the patient-voice label with its timestamp (sdd/telegram-rag-ingestion-262 #262, Slice 1)",
         %{
           conn: conn,
           professional: professional,
           patient: patient
         } do
      clear_pending_outbox!(patient)

      insert_chunk!(professional, patient, @plain_excerpt, near_vector(),
        source_resource_type: "patient_message",
        occurred_at: @plain_occurred_at
      )

      stub_query_embedding(near_vector())

      expect(ClinicalConsultationChainMock, :run, fn _params ->
        {:ok, %{synthesis: @synthesis}}
      end)

      {:ok, view, _html} = live(conn, ~p"/patients/#{patient.id}/consultation")

      submit_query(view, "¿qué reporto el paciente esta semana?")
      render_async(view)

      item = view |> element("ol.consultation__sources li", @plain_excerpt) |> render()

      assert item =~ @plain_excerpt
      assert item =~ "Mensaje del paciente"
      assert item =~ "03/02/2026 18:30"
    end

    test "a provider failure renders the safe state with no synthesis and no sources", %{
      conn: conn,
      professional: professional,
      patient: patient
    } do
      insert_chunk!(professional, patient, @seeded_excerpt, near_vector())
      stub_query_embedding(near_vector())

      expect(ClinicalConsultationChainMock, :run, fn _params -> {:error, :timeout} end)

      {:ok, view, _html} = live(conn, ~p"/patients/#{patient.id}/consultation")

      submit_query(view, "¿cómo viene el paciente?")
      html = render_async(view)

      assert html =~ "consultation-provider-error"
      refute has_element?(view, "section.consultation__synthesis")
      refute has_element?(view, "ol.consultation__sources")
      refute html =~ @seeded_excerpt
    end
  end

  describe "zero persistence" do
    test "does not survive remount: a second mount starts empty", %{conn: conn, patient: patient} do
      set_fake_outcome(:synthesis)
      {:ok, view, _html} = live(conn, ~p"/patients/#{patient.id}/consultation")

      submit_query(view, "¿cómo viene el paciente?")
      render_async(view)

      {:ok, _second_view, html} = live(conn, ~p"/patients/#{patient.id}/consultation")

      assert html =~ "consultation-idle"
      refute html =~ "consultation-synthesis"
    end

    test "'nueva conversación' discards prior history and follow-up context", %{
      conn: conn,
      patient: patient
    } do
      set_fake_outcome(:synthesis)
      {:ok, view, _html} = live(conn, ~p"/patients/#{patient.id}/consultation")

      submit_query(view, "¿cómo viene el paciente?")
      render_async(view)

      html =
        view
        |> element("#consultation-new-conversation")
        |> render_click()

      assert html =~ "consultation-idle"
      refute html =~ "consultation-synthesis"
    end

    test "no conversation content is written anywhere", %{conn: conn, patient: patient} do
      before_count = Repo.aggregate(Message, :count)

      set_fake_outcome(:synthesis)
      {:ok, view, _html} = live(conn, ~p"/patients/#{patient.id}/consultation")

      submit_query(view, "¿cómo viene el paciente?")
      render_async(view)

      assert Repo.aggregate(Message, :count) == before_count
    end
  end

  defp submit_query(view, query) do
    view
    |> form("#consultation-ask-form", consultation: %{query: query})
    |> render_submit()
  end

  defp set_fake_outcome(outcome, opts \\ []) do
    Application.put_env(:alethea, :consultation_fake_outcome, outcome, persistent: true)

    if pending = opts[:pending] do
      Application.put_env(:alethea, :consultation_fake_pending, pending, persistent: true)
    end
  end

  defp reset_fake_outcome do
    Application.put_env(:alethea, :consultation_fake_outcome, :synthesis, persistent: true)
    Application.delete_env(:alethea, :consultation_fake_pending)
  end

  defp use_live_consultation(_context) do
    Application.put_env(:alethea, :clinical_consultation, Consultation.Live, persistent: true)

    on_exit(fn ->
      Application.put_env(:alethea, :clinical_consultation, Consultation.Fake, persistent: true)
    end)

    :ok
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
