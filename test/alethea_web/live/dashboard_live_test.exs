defmodule AletheaWeb.DashboardLiveTest do
  use AletheaWeb.ConnCase
  use Oban.Testing, repo: Alethea.Repo
  import Phoenix.LiveViewTest

  alias Alethea.Accounts
  alias Alethea.Repo
  alias AletheaJobs.SessionReminderWorker

  setup [:register_and_log_in_professional]

  describe "Dashboard Index" do
    test "renders dashboard with mock data in dev environment", %{
      conn: conn,
      professional: professional
    } do
      Application.put_env(:alethea, :use_mock_data, true)
      on_exit(fn -> Application.put_env(:alethea, :use_mock_data, false) end)

      {:ok, _view, html} = live(conn, ~p"/dashboard")

      assert html =~ "Centro de Control"
      assert html =~ professional.full_name
      assert html =~ "Juan Perez"
    end

    test "receives real-time crisis alerts via PubSub", %{conn: conn} do
      Application.put_env(:alethea, :use_mock_data, true)
      on_exit(fn -> Application.put_env(:alethea, :use_mock_data, false) end)

      {:ok, view, _html} = live(conn, ~p"/dashboard")

      # Simular alerta de crisis
      send(view.pid, {:crisis_detected, %{patient_id: "p2", level: :high}})

      assert render(view) =~ "Alerta Critica: El paciente Maria Garcia ha entrado en crisis"
      assert has_element?(view, "#critical-patient-p2")
    end
  end

  describe "Patient Detail" do
    setup do
      Application.put_env(:alethea, :use_mock_data, true)
      on_exit(fn -> Application.put_env(:alethea, :use_mock_data, false) end)
      :ok
    end

    test "loads patient details and logs profile view", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/patients/p1")

      assert render(view) =~ "Juan Perez"
      assert render(view) =~ "Weekly Pre-Session Report"
      assert render(view) =~ "Tendencias Emocionales"
    end

    @tag :skip
    test "decrypts chat history and logs audit action", %{conn: conn, professional: _professional} do
      Application.put_env(:alethea, :use_mock_data, true)
      on_exit(fn -> Application.put_env(:alethea, :use_mock_data, false) end)

      {:ok, view, _html} = live(conn, ~p"/dashboard/patients/p1")

      view
      |> element("#decrypt-chat-button")
      |> render_click()

      assert render(view) =~ "CONTENIDO DESCIFRADO (MOCK)"
    end

    test "saves session schedule correctly", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/patients/p1")

      view
      |> form("#schedule-form", %{day: "2", time: "18:00"})
      |> render_submit()

      assert render(view) =~ "Horario de sesión actualizado correctamente"
      assert render(view) =~ "Martes"
    end
  end

  describe "Welcome message" do
    setup do
      Application.put_env(:alethea, :use_mock_data, true)
      on_exit(fn -> Application.put_env(:alethea, :use_mock_data, false) end)
      :ok
    end

    test "saves a custom welcome message", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/patients/p1")

      view
      |> form("#welcome-message-form", %{welcome_message: "¡Hola! Bienvenido a tu espacio."})
      |> render_submit()

      assert render(view) =~ "Mensaje de bienvenida actualizado."
      assert render(view) =~ "¡Hola! Bienvenido a tu espacio."
    end
  end

  describe "save_session_schedule (real mode, #102 reminder cancellation)" do
    test "cancels the pending reminder and shows the success flash", %{
      conn: conn,
      professional: professional
    } do
      Application.put_env(:alethea, :use_mock_data, false)
      on_exit(fn -> Application.put_env(:alethea, :use_mock_data, false) end)

      {:ok, kek} = Accounts.load_professional_kek(professional)

      {:ok, patient} =
        Accounts.create_patient(
          %{
            "alias" => "alias-#{System.unique_integer([:positive])}",
            "professional_id" => professional.id
          },
          kek
        )

      {:ok, job} =
        %{
          "patient_id" => patient.id,
          "session_date" => "2099-01-10",
          "chat_id" => 555_666_777,
          "chat_id_hash" => String.duplicate("b", 64)
        }
        |> SessionReminderWorker.new(scheduled_at: DateTime.add(DateTime.utc_now(), 3, :day))
        |> Oban.insert()

      {:ok, view, _html} = live(conn, ~p"/dashboard/patients/#{patient.id}")

      view
      |> form("#schedule-form", %{day: "2", time: "18:00"})
      |> render_submit()

      assert render(view) =~ "Horario de sesión actualizado correctamente"
      assert Repo.get(Oban.Job, job.id).state == "cancelled"
    end
  end

  describe "Weekly Pre-Session Report (real mode)" do
    setup %{professional: professional} do
      Application.put_env(:alethea, :use_mock_data, false)
      on_exit(fn -> Application.put_env(:alethea, :use_mock_data, false) end)

      {:ok, patient} =
        Accounts.create_patient(%{
          alias: "Paciente Real",
          professional_id: professional.id
        })

      %{patient: patient}
    end

    test "renders the latest weekly summary", %{conn: conn, patient: patient} do
      period_start = DateTime.utc_now() |> DateTime.add(-9, :day) |> DateTime.truncate(:second)

      {:ok, _summary} =
        Alethea.Clinical.save_summary(%{
          period_start: period_start,
          period_end: DateTime.add(period_start, 7, :day),
          summary_text: "La semana estuvo marcada por una mejora del sueño.",
          status_level: "stable",
          type: "weekly",
          patient_id: patient.id
        })

      {:ok, _view, html} = live(conn, ~p"/dashboard/patients/#{patient.id}")

      assert html =~ "La semana estuvo marcada por una mejora del sueño."
      refute html =~ "Sin reportes semanales aún."
    end

    test "falls back to the empty state when there is no weekly summary", %{
      conn: conn,
      patient: patient
    } do
      {:ok, _view, html} = live(conn, ~p"/dashboard/patients/#{patient.id}")

      assert html =~ "Sin reportes semanales aún."
    end
  end

  describe "Authorization" do
    test "restricts access to non-existent patients in real mode", %{conn: conn} do
      Application.put_env(:alethea, :use_mock_data, false)
      on_exit(fn -> Application.put_env(:alethea, :use_mock_data, false) end)

      assert {:error, {:live_redirect, %{to: "/dashboard", flash: %{"error" => msg}}}} =
               live(conn, ~p"/dashboard/patients/#{Ecto.UUID.generate()}")

      assert msg =~ "Paciente no encontrado"
    end
  end

  defp register_and_log_in_professional(%{conn: conn}) do
    {:ok, professional} =
      Accounts.create_professional(%{
        email: "test-#{System.unique_integer()}@alethea.com",
        password: "password1234",
        full_name: "Dr. Gregory House"
      })

    %{conn: log_in_professional(conn, professional), professional: professional}
  end

  defp log_in_professional(conn, professional) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:professional_id, professional.id)
  end
end
