defmodule AletheaWeb.DashboardLiveSessionsPaginationTest do
  use AletheaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Alethea.FoundationTestHelper

  alias Alethea.Accounts
  alias Alethea.Clinical.Summary
  alias Alethea.Repo

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

      %Summary{}
      |> Summary.changeset(%{
        period_start: period_end,
        period_end: period_end,
        summary_text: "Sesión número #{n}.",
        status_level: "Estable",
        type: "session",
        patient_id: patient.id
      })
      |> Repo.insert!()
    end
  end
end
