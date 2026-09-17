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

  setup [:register_and_log_in_professional, :use_live_consultation, :set_mox_from_context, :verify_on_exit!]

  setup %{professional: professional} do
    patient = create_patient!(professional)
    clear_pending_outbox!(patient)
    insert_chunk!(professional, patient, @seeded_excerpt_a, near_vector())
    insert_chunk!(professional, patient, @seeded_excerpt_b, far_vector())
    %{patient: patient}
  end

  describe "follow-up cycle (#233)" do
    test "two turns each render their own synthesis and sources without reusing citations", %{
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
      assert html_one =~ "Sintesis inicial sobre sueno."
      assert html_one =~ @seeded_excerpt_a
      refute html_one =~ @seeded_excerpt_b

      submit_query(view, "turno dos")
      html_two = render_async(view)

      assert has_element?(view, "#consultation-synthesis")
      assert html_two =~ "Sintesis de seguimiento sobre caminatas."
      refute html_two =~ "Sintesis inicial sobre sueno."

      # Server-derived sources per turn — the second turn re-derives from
      # the fresh retrieval. The new chunk must appear; the previous chunk
      # must not be reused as evidence for the follow-up.
      assert html_two =~ @seeded_excerpt_b
      refute html_two =~ @seeded_excerpt_a
    end

    test "the consultation-new-conversation button clears follow-up context but preserves the patient", %{
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

      html_after_reset =
        view
        |> element("#consultation-new-conversation")
        |> render_click()

      assert html_after_reset =~ "consultation-idle"
      refute has_element?(view, "#consultation-synthesis")

      submit_query(view, "post reset")
      html_after_reset = render_async(view)

      assert html_after_reset =~ "Sintesis despues del reset."
      refute html_after_reset =~ "Sintesis inicial."
    end
  end

  # Helpers -------------------------------------------------------------------

  defp stub_query_embedding_by_query(map) do
    Application.put_env(:alethea, :ai_embeddings, Alethea.AI.EmbeddingsMock, persistent: true)

    on_exit(fn ->
      Application.put_env(:alethea, :ai_embeddings, Alethea.AI.Embeddings.Fake,
        persistent: true
      )
    end)

    Alethea.AI.EmbeddingsMock
    |> stub(:embed, fn query, [] -> {:ok, Map.fetch!(map, query)} end)
    |> stub(:dimensions, fn -> 1024 end)
    |> stub(:model, fn -> "fake-embeddings-bge-m3" end)
  end

  defp far_vector, do: [0.0, 1.0 | List.duplicate(0.0, 1022)]

  defp submit_query(view, query) do
    view
    |> form("#consultation-ask-form", consultation: %{query: query})
    |> render_submit()
  end

  defp use_live_consultation(_context) do
    Application.put_env(:alethea, :clinical_consultation, Consultation.Live, persistent: true)

    on_exit(fn ->
      Application.put_env(:alethea, :clinical_consultation, Consultation.Fake,
        persistent: true
      )
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
