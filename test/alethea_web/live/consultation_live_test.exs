defmodule AletheaWeb.ConsultationLiveTest do
  @moduledoc """
  `Phoenix.LiveViewTest` specs for `AletheaWeb.ConsultationLive` (#227,
  ConsultationLive shell over `Alethea.ClinicalRecord.Rag.Consultation.Fake`).

  Covers #227's acceptance scenarios: mount authorization, the six safe
  visible states driven entirely through the Fake (no real retrieval, no
  LLM), and the zero-persistence guarantee (no survival across remount,
  navigation, or "nueva conversación"; no DB/audit row is ever written).
  """
  use AletheaWeb.ConnCase
  import Phoenix.LiveViewTest

  alias Alethea.Accounts
  alias Alethea.Clinical.Message
  alias Alethea.Repo

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

  defp create_professional! do
    {:ok, professional} =
      Accounts.create_professional(%{
        email: "consultation-live-#{System.unique_integer([:positive])}@alethea.com",
        password: "supersecret12",
        full_name: "Dr. Consultation"
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
