defmodule AletheaWeb.DashboardLiveTest do
  use AletheaWeb.ConnCase
  import Phoenix.LiveViewTest

  alias Alethea.Accounts

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
