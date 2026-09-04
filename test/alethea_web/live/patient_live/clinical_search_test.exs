defmodule AletheaWeb.PatientLive.ClinicalSearchTest do
  @moduledoc """
  `Phoenix.LiveViewTest` specs for `AletheaWeb.PatientLive.ClinicalSearch`
  (sdd/clinical-rag-projection, GitHub #196, WU5/PR5, Phase 7 tasks
  7.1-7.2).

  Covers the spec's UI-facing acceptance scenarios for the
  non-authoritative RAG projection view:
  - Access control: a non-treating professional is denied (reuses
    `Retrieval.search/4`'s authz, the same check every other
    patient-scoped surface uses).
  - Empty states: `:never_indexed` (zero chunks) vs `:no_match`
    (chunks exist, none score above the relevance threshold) — see
    `AletheaWeb.PatientLive.ClinicalSearch`'s moduledoc for why this
    threshold exists (`Retrieval.search/4` ranks, it does not filter).
  - Every result carries a persistent (non-dismissible)
    `badge badge--non-authoritative` and a citation resolving to the
    source row.
  - Results re-`stream/3` with `reset: true` per query (a second,
    differently-matching query replaces the first query's results,
    it does not accumulate them).
  """
  use AletheaWeb.ConnCase
  import Phoenix.LiveViewTest
  import Mox

  alias Alethea.Accounts
  alias Alethea.ClinicalRecord.Rag.Indexer
  alias Alethea.Encryption.PatientVault

  setup :verify_on_exit!
  setup [:register_and_log_in_professional]

  setup %{professional: professional} do
    patient = create_patient!(professional)
    %{patient: patient}
  end

  describe "mount — access control" do
    test "a non-treating professional is redirected instead of seeing any data", %{
      patient: patient
    } do
      stranger = create_professional!()
      stranger_conn = log_in_professional(build_conn(), stranger)

      assert {:error, {:live_redirect, %{to: "/patients"}}} =
               live(stranger_conn, ~p"/patients/#{patient.id}/clinical-search")
    end
  end

  describe "empty states" do
    test "a patient with zero chunks shows the never_indexed state, not a generic no-results state",
         %{conn: conn, patient: patient} do
      {:ok, _view, html} = live(conn, ~p"/patients/#{patient.id}/clinical-search")

      assert html =~ "clinical-search-never-indexed"
      refute html =~ "clinical-search-no-match"
      refute html =~ "badge--non-authoritative"
    end

    test "chunks exist but none score above the relevance threshold shows no_match, not never_indexed",
         %{conn: conn, professional: professional, patient: patient} do
      insert_chunk!(
        professional,
        patient,
        "Nota rutinaria sobre horarios de sesión",
        far_vector()
      )

      stub_query_embedding(near_vector())

      {:ok, view, _html} = live(conn, ~p"/patients/#{patient.id}/clinical-search")

      html =
        view
        |> form("#clinical-search-form", search: %{query: "ideación suicida activa"})
        |> render_submit()

      assert html =~ "clinical-search-no-match"
      refute html =~ "clinical-search-never-indexed"
      refute html =~ "badge--non-authoritative"
    end
  end

  describe "matching results — persistent badge + citation" do
    test "a genuinely matching result renders the non-authoritative badge and a source citation",
         %{conn: conn, professional: professional, patient: patient} do
      target_behavior = create_target_behavior!(professional, patient)

      chunk_id =
        insert_chunk!(
          professional,
          patient,
          "El paciente presenta evitacion social recurrente en la ultima semana",
          near_vector(),
          target_behavior.id
        )

      stub_query_embedding(near_vector())

      {:ok, view, _html} = live(conn, ~p"/patients/#{patient.id}/clinical-search")

      html =
        view
        |> form("#clinical-search-form", search: %{query: "evitacion social"})
        |> render_submit()

      assert html =~ "evitacion social recurrente"
      assert has_element?(view, ".badge--non-authoritative")
      # Non-dismissible: no close/dismiss control is rendered alongside it.
      refute html =~ ~r/badge--non-authoritative.*?(phx-click="dismiss"|data-dismiss)/s

      assert has_element?(
               view,
               "a[href='/patients/#{patient.id}/target_behaviors/#{target_behavior.id}/review']"
             )

      refute html =~ "clinical-search-no-match"
      refute html =~ "clinical-search-never-indexed"
      assert chunk_id
    end
  end

  describe "results re-stream with reset per query" do
    test "a second, differently-matching query replaces the first query's results", %{
      conn: conn,
      professional: professional,
      patient: patient
    } do
      insert_chunk!(professional, patient, "Primera nota sobre evitacion social", e0())
      insert_chunk!(professional, patient, "Segunda nota sobre ansiedad generalizada", e1())

      stub_query_embedding_by_content(%{"primera" => e0(), "segunda" => e1()})

      {:ok, view, _html} = live(conn, ~p"/patients/#{patient.id}/clinical-search")

      html_first =
        view
        |> form("#clinical-search-form", search: %{query: "primera evitacion"})
        |> render_submit()

      assert html_first =~ "Primera nota sobre evitacion social"
      refute html_first =~ "Segunda nota sobre ansiedad generalizada"

      html_second =
        view
        |> form("#clinical-search-form", search: %{query: "segunda ansiedad"})
        |> render_submit()

      assert html_second =~ "Segunda nota sobre ansiedad generalizada"
      refute html_second =~ "Primera nota sobre evitacion social"
    end
  end

  # --- fixtures -----------------------------------------------------------

  defp e0, do: [1.0 | List.duplicate(0.0, 1023)]
  defp e1, do: [0.0, 1.0 | List.duplicate(0.0, 1022)]
  defp near_vector, do: e0()
  defp far_vector, do: e1()

  defp stub_query_embedding(vector) do
    stub_query_embedding_by_content(%{}, vector)
  end

  defp stub_query_embedding_by_content(by_content, default \\ far_vector()) do
    original = Application.get_env(:alethea, :ai_embeddings)
    Application.put_env(:alethea, :ai_embeddings, Alethea.AI.EmbeddingsMock, persistent: true)

    on_exit(fn ->
      Application.put_env(:alethea, :ai_embeddings, original, persistent: true)
    end)

    Alethea.AI.EmbeddingsMock
    |> stub(:embed, fn query, [] ->
      vector =
        Enum.find_value(by_content, default, fn {needle, v} ->
          if String.contains?(query, needle), do: v
        end)

      {:ok, vector}
    end)
    |> stub(:dimensions, fn -> 1024 end)
    |> stub(:model, fn -> "fake-embeddings-bge-m3" end)
  end

  defp insert_chunk!(professional, patient, text, vector, target_behavior_id \\ nil) do
    resource_id = Ecto.UUID.generate()
    {:ok, kek} = Accounts.load_professional_kek(professional)
    {:ok, dek} = Accounts.load_patient_dek(patient, kek)
    {:ok, ciphertext} = PatientVault.encrypt(text, dek)

    attrs = [
      %{
        source_resource_type: "clinical_note",
        source_resource_id: resource_id,
        chunk_index: 0,
        encrypted_content: ciphertext,
        embedding: vector,
        embedding_model: "fake-embeddings-bge-m3",
        token_count: 10,
        full_event: true,
        source_occurred_at: DateTime.utc_now(),
        patient_id: patient.id,
        professional_id: professional.id,
        target_behavior_id: target_behavior_id
      }
    ]

    {:ok, _rows} = Indexer.replace_chunks({"clinical_note", resource_id}, attrs)
    resource_id
  end

  defp create_target_behavior!(professional, patient) do
    {:ok, target_behavior} =
      Alethea.ClinicalRecord.create_target_behavior(
        professional,
        patient.id,
        "Conducta objetivo"
      )

    target_behavior
  end

  defp create_professional! do
    {:ok, professional} =
      Accounts.create_professional(%{
        email: "clinical-search-#{System.unique_integer([:positive])}@alethea.com",
        password: "supersecret12",
        full_name: "Dr. Clinical Search"
      })

    professional
  end

  defp create_patient!(professional) do
    {:ok, kek} = Accounts.load_professional_kek(professional)

    {:ok, patient} =
      Accounts.create_patient(
        %{
          "alias" => "Paciente #{System.unique_integer([:positive])}",
          "professional_id" => professional.id
        },
        kek
      )

    patient
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
