defmodule AletheaWeb.ConsultationLiveTest do
  @moduledoc """
  `Phoenix.LiveViewTest` specs for `AletheaWeb.ConsultationLive` (#227,
  sdd/grounded-clinical-chat-initial). This slice is the authorized
  LiveView SHELL consuming `Alethea.ClinicalRecord.Rag.Consultation.Fake`
  only — no real retrieval, no LLM, no `Consultation.Live`.

  Covers the spec's #227 scenarios:
  - Authorized per-patient surface: an unauthorized professional is
    redirected to `/patients` and sees no consultation content.
  - The six safe visible states (idle, retrieving, synthesis,
    indexed-no-evidence, stale-pending showing the count, provider-error).
  - No persistence: conversation state lives only in socket assigns and
    does not survive a remount, navigation, or a new conversation, and no
    ETS / DB / audit row is written.
  """
  use AletheaWeb.ConnCase
  import Phoenix.LiveViewTest

  alias Alethea.Accounts
  alias Alethea.ClinicalRecord.Rag.Chunk
  alias Alethea.Accounts.AuditLog
  alias Alethea.Repo

  @password "supersecret12"

  setup [:register_and_log_in_professional]

  setup %{professional: professional} do
    patient = create_patient!(professional)
    %{patient: patient, path: ~p"/patients/#{patient.id}/consultation"}
  end

  describe "mount — authorization" do
    test "an unauthorized professional is redirected to /patients with no content", %{
      conn: conn,
      path: path
    } do
      # #227 drives authorization through the Fake; the real per-professional
      # check against the patient lands in #232 (`Consultation.Live`).
      put_fake_outcome(:unauthorized)

      assert {:error, {:live_redirect, %{to: "/patients"}}} = live(conn, path)
    end

    test "the treating professional reaches the idle state", %{conn: conn, path: path} do
      {:ok, view, html} = live(conn, path)

      assert has_element?(view, "#consultation-idle")
      refute html =~ "Síntesis basada en evidencia"
      refute has_element?(view, "[id^='consultation-provider-error']")
    end
  end

  describe "the six safe visible states" do
    test "idle renders on a freshly mounted conversation", %{conn: conn, path: path} do
      {:ok, view, _html} = live(conn, path)

      assert has_element?(view, "#consultation-idle")
      refute has_element?(view, "#consultation-retrieving")
    end

    test "retrieving renders while the turn is in flight", %{conn: conn, path: path} do
      put_fake_outcome(:synthesis)
      {:ok, view, _html} = live(conn, path)

      html =
        view
        |> form("#consultation-form", consultation: %{query: "¿cómo va el ánimo?"})
        |> render_submit()

      assert html =~ "consultation-retrieving"
      refute html =~ "consultation-idle"
    end

    test "synthesis shows the synthesis text and the sources list", %{conn: conn, path: path} do
      put_fake_outcome(:synthesis)
      {:ok, view, _html} = live(conn, path)

      view
      |> form("#consultation-form", consultation: %{query: "¿cómo va el ánimo?"})
      |> render_submit()

      render_async(view)
      html = render(view)

      assert has_element?(view, "[id^='consultation-synthesis']")
      assert html =~ "Síntesis basada en evidencia"
      assert html =~ "mejoría sostenida del ánimo"
      assert html =~ "El paciente reporta mejoría del ánimo esta semana"
    end

    test "indexed-no-evidence renders a blocked state with no synthesized answer", %{
      conn: conn,
      path: path
    } do
      put_fake_outcome(:no_evidence)
      {:ok, view, _html} = live(conn, path)

      view
      |> form("#consultation-form", consultation: %{query: "¿tiene ideación suicida?"})
      |> render_submit()

      render_async(view)
      html = render(view)

      assert has_element?(view, "[id^='consultation-no-evidence']")
      refute html =~ "Síntesis basada en evidencia"
    end

    test "stale-pending renders the pending count and a retry prompt", %{conn: conn, path: path} do
      put_fake_outcome(:stale, pending: 5)
      {:ok, view, _html} = live(conn, path)

      view
      |> form("#consultation-form", consultation: %{query: "¿cómo durmió?"})
      |> render_submit()

      render_async(view)
      html = render(view)

      assert has_element?(view, "[id^='consultation-stale']")
      assert html =~ "5"
      assert html =~ "pendiente"
    end

    test "provider-error renders a safe state with no partial synthesis", %{
      conn: conn,
      path: path
    } do
      put_fake_outcome(:provider_failure)
      {:ok, view, _html} = live(conn, path)

      view
      |> form("#consultation-form", consultation: %{query: "¿qué pasó?"})
      |> render_submit()

      render_async(view)
      html = render(view)

      assert has_element?(view, "[id^='consultation-provider-error']")
      refute html =~ "Síntesis basada en evidencia"
    end
  end

  describe "no persistence of conversation state" do
    test "conversation state does not survive a remount", %{conn: conn, path: path} do
      put_fake_outcome(:synthesis)
      {:ok, view, _html} = live(conn, path)

      view
      |> form("#consultation-form", consultation: %{query: "primera pregunta sobre el ánimo"})
      |> render_submit()

      render_async(view)
      assert render(view) =~ "Síntesis basada en evidencia"

      {:ok, remounted, html} = live(conn, path)

      assert has_element?(remounted, "#consultation-idle")
      refute html =~ "Síntesis basada en evidencia"
      refute html =~ "primera pregunta sobre el ánimo"
    end

    test "navigating away and back yields an empty conversation", %{conn: conn, path: path} do
      put_fake_outcome(:synthesis)
      {:ok, view, _html} = live(conn, path)

      view
      |> form("#consultation-form", consultation: %{query: "pregunta antes de navegar"})
      |> render_submit()

      render_async(view)

      {:ok, _patients_view, _} = live(conn, ~p"/patients")
      {:ok, back, html} = live(conn, path)

      assert has_element?(back, "#consultation-idle")
      refute html =~ "pregunta antes de navegar"
    end

    test "a new conversation discards prior turns and follow-up context", %{
      conn: conn,
      path: path
    } do
      put_fake_outcome(:synthesis)
      {:ok, view, _html} = live(conn, path)

      view
      |> form("#consultation-form", consultation: %{query: "pregunta que será descartada"})
      |> render_submit()

      render_async(view)
      assert render(view) =~ "pregunta que será descartada"

      html = view |> element("#consultation-new") |> render_click()

      refute html =~ "pregunta que será descartada"
      refute html =~ "Síntesis basada en evidencia"
      assert has_element?(view, "#consultation-idle")
    end

    test "no conversation content is written to ETS, the database, or audit logs", %{
      conn: conn,
      path: path
    } do
      put_fake_outcome(:synthesis)

      {:ok, view, _html} = live(conn, path)

      # Snapshot AFTER mount so the shared auth layer's KEK_ACCESS audit
      # row (written on every authenticated LiveView mount, unrelated to
      # this surface) is excluded — what must write nothing is the turns.
      audit_after_mount = Repo.aggregate(AuditLog, :count)
      chunks_after_mount = Repo.aggregate(Chunk, :count)

      for query <- ["turno uno", "turno dos", "turno tres"] do
        view
        |> form("#consultation-form", consultation: %{query: query})
        |> render_submit()

        render_async(view)
      end

      assert render(view) =~ "Síntesis basada en evidencia"
      assert Repo.aggregate(AuditLog, :count) == audit_after_mount
      assert Repo.aggregate(Chunk, :count) == chunks_after_mount
      assert :ets.info(:conversation_memory, :size) in [0, :undefined]
    end
  end

  # --- helpers ----------------------------------------------------------

  defp put_fake_outcome(outcome, opts \\ []) do
    Application.put_env(:alethea, :consultation_fake_outcome, outcome)

    if pending = Keyword.get(opts, :pending) do
      Application.put_env(:alethea, :consultation_fake_pending, pending)
    end

    on_exit(fn ->
      Application.delete_env(:alethea, :consultation_fake_outcome)
      Application.delete_env(:alethea, :consultation_fake_pending)
    end)
  end

  defp create_professional! do
    {:ok, professional} =
      Accounts.create_professional(%{
        email: "consultation-live-#{System.unique_integer([:positive])}@alethea.com",
        password: @password,
        full_name: "Dr. Consultation Live"
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
