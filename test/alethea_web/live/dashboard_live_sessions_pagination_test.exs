defmodule AletheaWeb.DashboardLiveSessionsPaginationTest do
  use AletheaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Alethea.FoundationTestHelper

  alias Alethea.Accounts

  setup [:register_and_log_in_professional]

  setup %{professional: professional} do
    Application.put_env(:alethea, :use_mock_data, false)
    on_exit(fn -> Application.put_env(:alethea, :use_mock_data, false) end)

    %{patient: legacy_patient_fixture(professional)}
  end

  describe "Sesiones anteriores pagination" do
    test "renders only the first 20 of 25 sessions and loads the rest on demand", %{
      conn: conn,
      patient: patient
    } do
      insert_sessions(patient, 25)

      {:ok, view, _html} = live(conn, ~p"/dashboard/patients/#{patient.id}")

      assert has_element?(view, "#session-summaries-panel.scroll-panel")
      assert session_item_count(view) == 20
      assert has_element?(view, "#load-more-session-summaries", "Cargar más")
      assert render(view) =~ "Sesión número 1."
      refute render(view) =~ "Sesión número 21."

      view |> element("#load-more-session-summaries") |> render_click()

      assert session_item_count(view) == 25
      assert render(view) =~ "Sesión número 25."
      refute has_element?(view, "#load-more-session-summaries")
    end

    test "firing load more twice does not duplicate sessions", %{conn: conn, patient: patient} do
      insert_sessions(patient, 25)

      {:ok, view, _html} = live(conn, ~p"/dashboard/patients/#{patient.id}")

      render_hook(view, "load_more_session_summaries", %{})
      render_hook(view, "load_more_session_summaries", %{})

      assert session_item_count(view) == 25
    end

    test "with 20 or fewer sessions there is no load more button", %{
      conn: conn,
      patient: patient
    } do
      insert_sessions(patient, 20)

      {:ok, view, _html} = live(conn, ~p"/dashboard/patients/#{patient.id}")

      assert session_item_count(view) == 20
      refute has_element?(view, "#load-more-session-summaries")
    end

    test "with no sessions the empty state is shown", %{conn: conn, patient: patient} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/patients/#{patient.id}")

      assert render(view) =~ "Sin sesiones con seguimiento clínico aún."
      refute has_element?(view, "#load-more-session-summaries")
      assert session_item_count(view) == 0
    end
  end

  describe "summary key resolution (security-audit-run-2 S6c)" do
    test "one dashboard load unwraps the patient key once for all summaries", %{
      conn: conn,
      patient: patient
    } do
      insert_sessions(patient, 3)

      {:ok, _weekly} =
        Alethea.Clinical.save_summary(%{
          period_start: DateTime.utc_now() |> DateTime.truncate(:second),
          period_end: DateTime.utc_now() |> DateTime.truncate(:second),
          summary_text: "Semana estable.",
          status_level: "Estable",
          type: "weekly",
          patient_id: patient.id
        })

      {:ok, view, _html} = live(conn, ~p"/dashboard/patients/#{patient.id}")
      before = audit_counts(patient)

      send(view.pid, {:emotion_trends_updated, patient.id})
      html = render(view)

      assert html =~ "Semana estable."
      assert html =~ "Sesión número 1."

      after_load = audit_counts(patient)
      assert after_load.kek_load - before.kek_load == 1
      assert after_load.summary_decrypt - before.summary_decrypt == 1
    end
  end

  defp audit_counts(patient) do
    import Ecto.Query

    logs = Alethea.Repo.all(from(a in Alethea.Accounts.AuditLog))

    %{
      kek_load: Enum.count(logs, &(&1.action == "KEK_LOAD")),
      summary_decrypt:
        Enum.count(
          logs,
          &(&1.action == "PII_DECRYPT" and &1.resource_id == patient.id and
              reason(&1) == "summary_loading")
        )
    }
  end

  defp reason(%{details: details}), do: details["reason"] || details[:reason]

  defp session_item_count(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#session-summaries .pta-timeline__item")
    |> Enum.count()
  end

  defp register_and_log_in_professional(%{conn: conn}) do
    {:ok, professional} =
      Accounts.create_professional(%{
        email: "test-#{System.unique_integer([:positive])}@alethea.com",
        password: "password1234",
        full_name: "Dra. Paginada"
      })

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> Plug.Conn.put_session(:professional_id, professional.id)

    %{conn: conn, professional: professional}
  end

  # Session n ends n hours ago, so session 1 is the newest.
  defp insert_sessions(patient, count) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    for n <- 1..count do
      period_end = DateTime.add(now, -n, :hour)

      {:ok, summary} =
        Alethea.Clinical.save_summary(%{
          period_start: period_end,
          period_end: period_end,
          summary_text: "Sesión número #{n}.",
          status_level: "Estable",
          type: "session",
          patient_id: patient.id
        })

      summary
    end
  end
end
