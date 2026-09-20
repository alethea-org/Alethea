defmodule AletheaWeb.ConsultationLiveFollowupTest do
  @moduledoc """
  B2 acceptance for #233 over the LiveView surface — the psychologist
  must be able to chain two turns in one session, each producing its own
  synthesis + sources, with no reuse of citations as evidence and a clean
  reset on "nueva conversación".

  Runs against the real pipeline (`Rag.Consultation.Live`) so we cover
  #233 + #234a in the same seam, mirroring the patterns from
  `consultation_live_test.exs`.
  """
  # async: false — same reason as `consultation_live_test.exs`: we swap the
  # `:clinical_consultation` slot, run Mox in `:global` mode, and rely on
  # sequenced answers to follow-ups.
  use AletheaWeb.ConnCase, async: false

  import Alethea.RagFixtures
  import Mox
  import Phoenix.LiveViewTest

  alias Alethea.AI.ClinicalConsultationChainMock
  alias Alethea.ClinicalRecord.Rag.Consultation

  @seeded_excerpt_a "Paciente reporto mejora del sueno durante la semana."
  @seeded_excerpt_b "Paciente volvio a hacer su caminata diaria despues del alta."

  setup [
    :register_and_log_in_professional,
    :use_live_consultation,
    :set_mox_from_context,
    :verify_on_exit!
  ]

  setup %{professional: professional} do
    patient = create_patient!(professional)
    clear_pending_outbox!(patient)
    insert_chunk!(professional, patient, @seeded_excerpt_a, near_vector())
    insert_chunk!(professional, patient, @seeded_excerpt_b, far_vector())
    %{patient: patient}
  end

  describe "follow-up cycle (#233, #236)" do
    test "two turns each render their own synthesis and sources in chained order without reusing citations",
         %{
           conn: conn,
           patient: patient
         } do
      stub_query_embedding_by_query(%{
        "turno uno" => near_vector(),
        "turno dos" => far_vector()
      })

      expect(ClinicalConsultationChainMock, :run, 2, fn %{question: question, excerpts: excerpts} ->
        cond do
          question =~ "uno" ->
            assert excerpts == [@seeded_excerpt_a]
            {:ok, %{synthesis: "Sintesis inicial sobre sueno."}}

          question =~ "dos" ->
            assert excerpts == [@seeded_excerpt_b]
            {:ok, %{synthesis: "Sintesis de seguimiento sobre caminatas."}}

          true ->
            flunk("unexpected question: #{inspect(question)} with excerpts #{inspect(excerpts)}")
        end
      end)

      {:ok, view, _html} = live(conn, ~p"/patients/#{patient.id}/consultation")

      submit_query(view, "turno uno")
      html_one = render_async(view)

      assert has_element?(view, "#consultation-synthesis")
      assert has_element?(view, "#turn-0")
      assert has_element?(view, "#turn-0 .consultation__turn-query-text", "turno uno")
      assert has_element?(view, "#turn-0-synthesis", "Sintesis inicial sobre sueno.")
      assert has_element?(view, "#turn-0-sources", @seeded_excerpt_a)
      refute has_element?(view, "#turn-0-sources", @seeded_excerpt_b)
      refute html_one =~ @seeded_excerpt_b

      submit_query(view, "turno dos")
      _html_two = render_async(view)

      assert has_element?(view, "#consultation-synthesis")

      # Both turn 0 and turn 1 are present in chained order
      assert has_element?(view, "#turn-0")
      assert has_element?(view, "#turn-0 .consultation__turn-query-text", "turno uno")
      assert has_element?(view, "#turn-0-synthesis", "Sintesis inicial sobre sueno.")
      assert has_element?(view, "#turn-0-sources", @seeded_excerpt_a)

      assert has_element?(view, "#turn-1")
      assert has_element?(view, "#turn-1 .consultation__turn-query-text", "turno dos")
      assert has_element?(view, "#turn-1-synthesis", "Sintesis de seguimiento sobre caminatas.")
      assert has_element?(view, "#turn-1-sources", @seeded_excerpt_b)

      # In turn 1's sources element, refute @seeded_excerpt_a
      turn_1_sources_html = render(element(view, "#turn-1-sources"))
      refute turn_1_sources_html =~ @seeded_excerpt_a
      assert turn_1_sources_html =~ @seeded_excerpt_b
    end

    test "chained turns (3 turns): N follow-ups can be chained sequentially", %{
      conn: conn,
      professional: professional,
      patient: patient
    } do
      seeded_excerpt_c = "Paciente refiere descanso reparador y regularidad."
      insert_chunk!(professional, patient, seeded_excerpt_c, third_vector())

      stub_query_embedding_by_query(%{
        "pregunta 1" => near_vector(),
        "pregunta 2" => far_vector(),
        "pregunta 3" => third_vector()
      })

      expect(ClinicalConsultationChainMock, :run, 3, fn %{question: question, excerpts: excerpts} ->
        cond do
          question =~ "1" ->
            assert excerpts == [@seeded_excerpt_a]
            {:ok, %{synthesis: "Sintesis 1"}}

          question =~ "2" ->
            assert excerpts == [@seeded_excerpt_b]
            {:ok, %{synthesis: "Sintesis 2"}}

          question =~ "3" ->
            assert excerpts == [seeded_excerpt_c]
            {:ok, %{synthesis: "Sintesis 3"}}
        end
      end)

      {:ok, view, _html} = live(conn, ~p"/patients/#{patient.id}/consultation")

      submit_query(view, "pregunta 1")
      render_async(view)

      submit_query(view, "pregunta 2")
      render_async(view)

      submit_query(view, "pregunta 3")
      render_async(view)

      # All 3 turns exist in the stream in sequential order
      assert has_element?(view, "#turn-0")
      assert has_element?(view, "#turn-0 .consultation__turn-query-text", "pregunta 1")
      assert has_element?(view, "#turn-0-synthesis", "Sintesis 1")
      assert has_element?(view, "#turn-0-sources", @seeded_excerpt_a)

      assert has_element?(view, "#turn-1")
      assert has_element?(view, "#turn-1 .consultation__turn-query-text", "pregunta 2")
      assert has_element?(view, "#turn-1-synthesis", "Sintesis 2")
      assert has_element?(view, "#turn-1-sources", @seeded_excerpt_b)

      assert has_element?(view, "#turn-2")
      assert has_element?(view, "#turn-2 .consultation__turn-query-text", "pregunta 3")
      assert has_element?(view, "#turn-2-synthesis", "Sintesis 3")
      assert has_element?(view, "#turn-2-sources", seeded_excerpt_c)
    end

    test "nueva conversación reset: clears synthesis, idle is present, all turn elements are gone",
         %{
           conn: conn,
           patient: patient
         } do
      stub_query_embedding_by_query(%{
        "turno uno" => far_vector(),
        "post reset" => near_vector()
      })

      expect(ClinicalConsultationChainMock, :run, 2, fn %{question: question} ->
        if question =~ "uno" do
          {:ok, %{synthesis: "Sintesis inicial."}}
        else
          {:ok, %{synthesis: "Sintesis despues del reset."}}
        end
      end)

      {:ok, view, _html} = live(conn, ~p"/patients/#{patient.id}/consultation")

      submit_query(view, "turno uno")
      render_async(view)

      assert has_element?(view, "#consultation-synthesis")
      assert has_element?(view, "#turn-0")

      view
      |> element("#consultation-new-conversation")
      |> render_click()

      assert has_element?(view, "#consultation-idle")
      refute has_element?(view, "#consultation-synthesis")
      refute has_element?(view, "#turn-0")
      refute has_element?(view, "#turn-1")
      refute has_element?(view, "#turn-2")

      submit_query(view, "post reset")
      html_after_reset = render_async(view)

      assert html_after_reset =~ "Sintesis despues del reset."
      refute html_after_reset =~ "Sintesis inicial."
      assert has_element?(view, "#turn-0-synthesis", "Sintesis despues del reset.")
    end

    test "logout / remount zero-persistence", %{
      conn: conn,
      professional: professional,
      patient: patient
    } do
      stub_query_embedding_by_query(%{
        "turno uno" => near_vector()
      })

      expect(ClinicalConsultationChainMock, :run, 1, fn _params ->
        {:ok, %{synthesis: "Sintesis antes de logout."}}
      end)

      {:ok, view, _html} = live(conn, ~p"/patients/#{patient.id}/consultation")

      submit_query(view, "turno uno")
      render_async(view)

      assert has_element?(view, "#turn-0")

      # Simulate logout and a new session mount for the same patient
      new_conn = log_in_professional(build_conn(), professional)
      {:ok, new_view, html} = live(new_conn, ~p"/patients/#{patient.id}/consultation")

      assert has_element?(new_view, "#consultation-idle")
      assert html =~ "consultation-idle"
      refute has_element?(new_view, "#consultation-synthesis")
      refute has_element?(new_view, "#turn-0")
      refute has_element?(new_view, "#consultation-messages")
      refute html =~ "Sintesis antes de logout."
    end
  end

  describe "safe blocked states in follow-ups (#236)" do
    test "turn 2 yielding :no_evidence displays empty state, keeps turn 1 in stream, and allows retry",
         %{
           conn: conn,
           patient: patient
         } do
      stub_query_embedding_by_query(%{
        "turno uno" => near_vector(),
        "sin evidencia" => orthogonal_vector(),
        "reintento" => far_vector()
      })

      expect(ClinicalConsultationChainMock, :run, 2, fn %{question: question} ->
        cond do
          question =~ "uno" ->
            {:ok, %{synthesis: "Sintesis turno uno"}}

          question =~ "reintento" ->
            {:ok, %{synthesis: "Sintesis reintento"}}
        end
      end)

      {:ok, view, _html} = live(conn, ~p"/patients/#{patient.id}/consultation")

      # Turn 1 succeeds
      submit_query(view, "turno uno")
      render_async(view)

      assert has_element?(view, "#turn-0")
      assert has_element?(view, "#turn-0-synthesis", "Sintesis turno uno")

      # Turn 2 yields no evidence (orthogonal vector has cosine similarity 0 < 0.35)
      submit_query(view, "sin evidencia")
      html_blocked = render_async(view)

      assert has_element?(view, "#consultation-no-evidence")

      assert html_blocked =~
               "El registro no cuenta con evidencia suficiente para responder esta consulta."

      # Turn 1 remains visible in the stream
      assert has_element?(view, "#turn-0")
      assert has_element?(view, "#turn-0-synthesis", "Sintesis turno uno")
      refute has_element?(view, "#turn-1")

      # Turn counter did not advance: retrying records at turn 1
      submit_query(view, "reintento")
      render_async(view)

      assert has_element?(view, "#turn-0")
      assert has_element?(view, "#turn-1")
      assert has_element?(view, "#turn-1-synthesis", "Sintesis reintento")
      assert has_element?(view, "#turn-1-sources", @seeded_excerpt_b)
      refute has_element?(view, "#consultation-no-evidence")
    end

    test "turn 2 yielding :stale displays notice with pending count and keeps turn 1 in stream",
         %{
           conn: conn,
           professional: professional,
           patient: patient
         } do
      stub_query_embedding_by_query(%{
        "turno uno" => near_vector(),
        "turno pendiente" => far_vector()
      })

      expect(ClinicalConsultationChainMock, :run, 1, fn %{question: question} ->
        assert question =~ "uno"
        {:ok, %{synthesis: "Sintesis turno uno"}}
      end)

      {:ok, view, _html} = live(conn, ~p"/patients/#{patient.id}/consultation")

      submit_query(view, "turno uno")
      render_async(view)

      assert has_element?(view, "#turn-0")

      # Insert pending outbox job so next turn triggers :stale
      insert_pending_job!(professional, patient)

      submit_query(view, "turno pendiente")
      html_stale = render_async(view)

      assert has_element?(view, "#consultation-stale")
      assert html_stale =~ "La indexación del paciente está pendiente (1 elementos)"
      # Turn 1 remains visible in stream
      assert has_element?(view, "#turn-0")
      assert has_element?(view, "#turn-0-synthesis", "Sintesis turno uno")
      refute has_element?(view, "#turn-1")
    end

    test "turn 2 yielding :provider_failure displays error and keeps turn 1 in stream", %{
      conn: conn,
      patient: patient
    } do
      stub_query_embedding_by_query(%{
        "turno uno" => near_vector(),
        "turno falla" => far_vector()
      })

      expect(ClinicalConsultationChainMock, :run, 2, fn %{question: question} ->
        cond do
          question =~ "uno" ->
            {:ok, %{synthesis: "Sintesis turno uno"}}

          question =~ "falla" ->
            {:error, :timeout}
        end
      end)

      {:ok, view, _html} = live(conn, ~p"/patients/#{patient.id}/consultation")

      submit_query(view, "turno uno")
      render_async(view)

      assert has_element?(view, "#turn-0")

      submit_query(view, "turno falla")
      html_failure = render_async(view)

      assert has_element?(view, "#consultation-provider-error")
      assert html_failure =~ "No se pudo generar una respuesta. Intentá nuevamente."
      # Turn 1 remains visible in stream
      assert has_element?(view, "#turn-0")
      assert has_element?(view, "#turn-0-synthesis", "Sintesis turno uno")
      refute has_element?(view, "#turn-1")
    end
  end

  # Helpers -------------------------------------------------------------------

  defp stub_query_embedding_by_query(map) do
    Application.put_env(:alethea, :ai_embeddings, Alethea.AI.EmbeddingsMock, persistent: true)

    on_exit(fn ->
      Application.put_env(:alethea, :ai_embeddings, Alethea.AI.Embeddings.Fake, persistent: true)
    end)

    Alethea.AI.EmbeddingsMock
    |> stub(:embed, fn query, [] -> {:ok, Map.fetch!(map, query)} end)
    |> stub(:dimensions, fn -> 1024 end)
    |> stub(:model, fn -> "fake-embeddings-bge-m3" end)
  end

  defp far_vector, do: [0.0, 1.0 | List.duplicate(0.0, 1022)]
  defp third_vector, do: [0.0, 0.0, 1.0 | List.duplicate(0.0, 1021)]
  defp orthogonal_vector, do: [0.0, 0.0, 0.0, 1.0 | List.duplicate(0.0, 1020)]

  defp submit_query(view, query) do
    view
    |> form("#consultation-ask-form", consultation: %{query: query})
    |> render_submit()
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
