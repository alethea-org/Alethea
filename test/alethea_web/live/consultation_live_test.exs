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

  alias Alethea.AI.{ClinicalConsultationChainMock, ClinicalHypothesisChainMock}
  alias Alethea.Clinical.Message
  alias Alethea.ClinicalRecord.Rag.Consultation
  alias Alethea.ClinicalRecord.Rag.Consultation.{Answer, Hypothesis}
  alias Alethea.Repo

  @seeded_excerpt "El paciente reporta mejoría del ánimo esta semana y mayor actividad social."
  @synthesis "Según los fragmentos citados, el paciente sostiene la mejoría del ánimo."
  @linked_excerpt "Cumplió la caminata pactada el martes por la mañana."
  @plain_excerpt "Durmió siete horas seguidas y se levantó sin alarma."
  @linked_occurred_at ~U[2026-01-15 10:00:00.000000Z]
  @plain_occurred_at ~U[2026-02-03 18:30:00.000000Z]

  # #235b — same interpretive/prose fixtures #235a's live_test.exs already
  # established for HypothesisPolicy classification, reused verbatim here
  # so the web-layer E2E describe classifies identically.
  @interpretive_query "¿qué relación hay con el trabajo?"
  @valid_hypothesis_prose "Podría existir una relación entre las caminatas pactadas y la mejoría del ánimo."
  @diagnostic_prose "El paciente presenta un trastorno de ansiedad generalizada."

  setup [:register_and_log_in_professional]

  setup %{professional: professional} do
    patient = create_patient!(professional)

    on_exit(fn ->
      reset_fake_outcome()
      reset_fake_hypothesis()
    end)

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
      assert has_element?(view, "section.consultation__sources-panel")

      synthesis_html = view |> element("section.consultation__synthesis") |> render()
      sources_html = view |> element("section.consultation__sources-panel") |> render()

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

      # Migrated (#235c/R10) to render through the unified
      # `AletheaWeb.CoreComponents.citation/1` — a `<details>` per
      # source, not the old hand-rolled `<ol><li>`. Date drops to
      # day-level ISO (#235c task 3.2, decision accepted): citation/1
      # never renders time-of-day.
      linked_item = view |> element("#turn-0-sources details", @linked_excerpt) |> render()

      assert linked_item =~ @linked_excerpt
      assert linked_item =~ "Observación del clínico"
      assert linked_item =~ "2026-01-15"

      assert linked_item =~
               ~s(href="/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review")

      assert linked_item =~ "Ver conducta objetivo"

      plain_item = view |> element("#turn-0-sources details", @plain_excerpt) |> render()

      assert plain_item =~ @plain_excerpt
      assert plain_item =~ "Nota clínica"
      assert plain_item =~ "2026-02-03"
      refute plain_item =~ "<a"
    end

    test "a source without a target behavior renders no dangling link and no error (#235c, R10)",
         %{
           conn: conn,
           professional: professional,
           patient: patient
         } do
      insert_chunk!(professional, patient, @plain_excerpt, near_vector(),
        source_resource_type: "clinical_note",
        target_behavior_id: nil,
        occurred_at: @plain_occurred_at
      )

      stub_query_embedding(near_vector())

      expect(ClinicalConsultationChainMock, :run, fn _params ->
        {:ok, %{synthesis: @synthesis}}
      end)

      {:ok, view, _html} = live(conn, ~p"/patients/#{patient.id}/consultation")

      submit_query(view, "¿qué hizo el paciente esta semana?")
      html = render_async(view)

      assert html =~ @plain_excerpt
      refute html =~ "Ver conducta objetivo"

      plain_item = view |> element("#turn-0-sources details", @plain_excerpt) |> render()
      refute plain_item =~ "<a"
    end

    test "a patient_message source renders the patient-voice label with its date (sdd/telegram-rag-ingestion-262 #262, Slice 1)",
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

      item = view |> element("#turn-0-sources details", @plain_excerpt) |> render()

      assert item =~ @plain_excerpt
      assert item =~ "Mensaje del paciente"
      # #235c task 3.2: `citation/1` renders day-level ISO dates only.
      assert item =~ "2026-02-03"
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
      refute has_element?(view, "section.consultation__sources-panel")
      refute html =~ @seeded_excerpt
    end
  end

  describe "per-turn Fuentes (#235c on the B2 thread)" do
    test "the same source cited on two turns never repeats a DOM id", %{
      conn: conn,
      patient: patient
    } do
      set_fake_outcome(:synthesis)
      {:ok, view, _html} = live(conn, ~p"/patients/#{patient.id}/consultation")

      submit_query(view, "¿cómo viene el paciente?")
      render_async(view)
      submit_query(view, "¿y durante esta semana?")
      html = render_async(view)

      assert has_element?(view, "#turn-0-sources details")
      assert has_element?(view, "#turn-1-sources details")

      ids = html |> LazyHTML.from_fragment() |> LazyHTML.query("[id]") |> LazyHTML.attribute("id")

      assert ids == Enum.uniq(ids)
    end
  end

  describe "hypothesis panel over the real pipeline (#235)" do
    setup [:use_live_consultation, :set_mox_global, :verify_on_exit!]

    test "an interpretive turn's HTML contains the structural hypothesis panel section (R4)", %{
      conn: conn,
      professional: professional,
      patient: patient
    } do
      insert_chunk!(professional, patient, @seeded_excerpt, near_vector())
      stub_query_embedding(near_vector())

      stub(ClinicalConsultationChainMock, :run, fn _params -> {:ok, %{synthesis: @synthesis}} end)

      stub(ClinicalHypothesisChainMock, :run, fn _params ->
        {:ok, %{hypothesis: @valid_hypothesis_prose}}
      end)

      {:ok, view, _html} = live(conn, ~p"/patients/#{patient.id}/consultation")

      submit_query(view, @interpretive_query)
      render_async(view)

      assert has_element?(view, "section.review-hypothesis-panel")
    end

    test "a factual turn's HTML contains no hypothesis panel tag anywhere, not even hidden (R4)",
         %{conn: conn, professional: professional, patient: patient} do
      insert_chunk!(professional, patient, @seeded_excerpt, near_vector())
      stub_query_embedding(near_vector())

      expect(ClinicalConsultationChainMock, :run, 1, fn _params ->
        {:ok, %{synthesis: @synthesis}}
      end)

      expect(ClinicalHypothesisChainMock, :run, 0, fn _params -> :never end)

      {:ok, view, _html} = live(conn, ~p"/patients/#{patient.id}/consultation")

      submit_query(view, "¿cómo viene el paciente?")
      html = render_async(view)

      refute html =~ "review-hypothesis-panel"
    end

    test "the disclaimer precedes the statement and the citation's excerpt is the exact server-derived fragment (R5)",
         %{conn: conn, professional: professional, patient: patient} do
      insert_chunk!(professional, patient, @seeded_excerpt, near_vector())
      stub_query_embedding(near_vector())

      stub(ClinicalConsultationChainMock, :run, fn _params -> {:ok, %{synthesis: @synthesis}} end)

      stub(ClinicalHypothesisChainMock, :run, fn _params ->
        {:ok, %{hypothesis: @valid_hypothesis_prose}}
      end)

      {:ok, view, _html} = live(conn, ~p"/patients/#{patient.id}/consultation")

      submit_query(view, @interpretive_query)
      html = render_async(view)

      {disclaimer_pos, _} = :binary.match(html, "Disclaimer clínico")
      {statement_pos, _} = :binary.match(html, @valid_hypothesis_prose)
      assert disclaimer_pos < statement_pos

      panel_html = view |> element("section.review-hypothesis-panel") |> render()
      assert panel_html =~ "<details"
      assert panel_html =~ "citation__summary"
      refute panel_html =~ " open"

      # #235c task 3.0: the excerpt is always in the DOM — native
      # <details> hides it visually until opened, so a real click
      # works with zero JS. Asserting presence here, directly on the
      # panel's own render, is now the complete proof (no ground-truth
      # workaround needed — that was only required while the excerpt
      # was structurally absent from the collapsed render).
      assert panel_html =~ @seeded_excerpt

      assert {:ok, %Answer{hypothesis: %Hypothesis{sources: [source]}}} =
               Consultation.answer(professional, patient.id, @interpretive_query, history: [])

      short_chunk_id = source.reference.chunk_id |> to_string() |> String.slice(0, 8)
      source_ref = "#{source.reference.resource_type}/#{short_chunk_id}"

      assert panel_html =~ ~s(id="citation-#{source_ref}")
    end

    test "diagnostic candidate prose yields hypothesis: nil and no panel in the DOM (R8 render half)",
         %{conn: conn, professional: professional, patient: patient} do
      insert_chunk!(professional, patient, @seeded_excerpt, near_vector())
      stub_query_embedding(near_vector())

      stub(ClinicalConsultationChainMock, :run, fn _params -> {:ok, %{synthesis: @synthesis}} end)

      stub(ClinicalHypothesisChainMock, :run, fn _params ->
        {:ok, %{hypothesis: @diagnostic_prose}}
      end)

      {:ok, view, _html} = live(conn, ~p"/patients/#{patient.id}/consultation")

      submit_query(view, @interpretive_query)
      html = render_async(view)

      assert html =~ "consultation-synthesis"
      refute html =~ "review-hypothesis-panel"
    end

    test "#consultation-synthesis and the hypothesis panel are DOM siblings, neither nested (R12)",
         %{conn: conn, professional: professional, patient: patient} do
      insert_chunk!(professional, patient, @seeded_excerpt, near_vector())
      stub_query_embedding(near_vector())

      stub(ClinicalConsultationChainMock, :run, fn _params -> {:ok, %{synthesis: @synthesis}} end)

      stub(ClinicalHypothesisChainMock, :run, fn _params ->
        {:ok, %{hypothesis: @valid_hypothesis_prose}}
      end)

      {:ok, view, _html} = live(conn, ~p"/patients/#{patient.id}/consultation")

      submit_query(view, @interpretive_query)
      html = render_async(view)

      lazy = LazyHTML.from_fragment(html)

      assert lazy
             |> LazyHTML.query("div.consultation > div#consultation-synthesis")
             |> Enum.count() == 1

      assert lazy
             |> LazyHTML.query("div.consultation > section.review-hypothesis-panel")
             |> Enum.count() == 1

      assert lazy
             |> LazyHTML.query("div#consultation-synthesis section.review-hypothesis-panel")
             |> Enum.count() == 0

      assert lazy
             |> LazyHTML.query("section.review-hypothesis-panel div#consultation-synthesis")
             |> Enum.count() == 0
    end
  end

  describe "hypothesis panel via Consultation.Fake (#235b)" do
    test "renders when the Fake carries a hypothesis (Judgment Day W1: selected_hypothesis/1 pass-through was previously untested)",
         %{conn: conn, patient: patient} do
      set_fake_outcome(:synthesis)
      set_fake_hypothesis(canned_hypothesis!())

      {:ok, view, _html} = live(conn, ~p"/patients/#{patient.id}/consultation")

      submit_query(view, "¿cómo viene el paciente?")
      html = render_async(view)

      assert html =~ "consultation-synthesis"
      assert has_element?(view, "section.review-hypothesis-panel")
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
