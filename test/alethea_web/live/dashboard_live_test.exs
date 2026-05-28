defmodule AletheaWeb.DashboardLiveTest do
  use AletheaWeb.ConnCase
  import Phoenix.LiveViewTest
  alias Alethea.Accounts
  alias Alethea.Repo
  alias Alethea.Accounts.AuditLog

  setup [:register_and_log_in_professional]

  describe "Dashboard Index" do
    test "renders dashboard with mock data in dev environment", %{conn: conn, professional: professional} do
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

      # Simular alerta de crisis para un paciente que ya existe en el mock (p2: Maria Garcia)
      Phoenix.PubSub.broadcast(
        Alethea.PubSub,
        "crisis:alerts",
        {:crisis_detected, "p2", :high, ["intento de daño"]}
      )

      # Verificar que aparece el toast y el paciente se mueve a alertas
      assert render(view) =~ "Alerta Critica: El paciente Maria Garcia ha entrado en crisis"
      assert view |> element("#critical-patient-p2") |> has_element?()
    end
  end

  describe "Patient Detail" do
    setup do
      Application.put_env(:alethea, :use_mock_data, true)
      on_exit(fn -> Application.put_env(:alethea, :use_mock_data, false) end)
      :ok
    end

    test "loads patient details and logs profile view", %{conn: conn, professional: professional} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/patients/p1")

      assert render(view) =~ "Juan Perez"
      assert render(view) =~ "Weekly Pre-Session Report"
      assert render(view) =~ "Tendencias del Estado de Ánimo"

      # Verificar log de auditoría
      assert Repo.get_by(AuditLog, 
        action: "VIEW_PATIENT_PROFILE", 
        professional_id: professional.id, 
        resource_id: "p1"
      )
    end

    test "decrypts chat history and logs audit action", %{conn: conn, professional: professional} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/patients/p1")

      view
      |> element("#decrypt-chat-button")
      |> render_click()

      assert render(view) =~ "CONTENIDO DESCIFRADO (MOCK)"
      
      # Verificar log de auditoría
      assert Repo.get_by(AuditLog, 
        action: "VIEW_CHAT_HISTORY", 
        professional_id: professional.id, 
        resource_id: "p1"
      )
    end

    test "saves session schedule correctly", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/patients/p1")

      view
      |> form("#dashboard-patient-detail form", %{day: "2", time: "18:00"})
      |> render_submit()

      assert render(view) =~ "Horario de sesión actualizado correctamente"
      # En mock data p1 es Lunes (1), verificamos que cambió a Martes (2)
      assert render(view) =~ "Martes"
    end
  end

  describe "Authorization" do
    test "restricts access to non-existent patients in real mode", %{conn: conn} do
      Application.put_env(:alethea, :use_mock_data, false)
      on_exit(fn -> Application.put_env(:alethea, :use_mock_data, false) end)

      {:ok, view, _html} = live(conn, ~p"/dashboard/patients/#{Ecto.UUID.generate()}")
      
      assert render(view) =~ "Paciente no encontrado"
      assert_patched(view, ~p"/dashboard")
    end
  end

  defp register_and_log_in_professional(%{conn: conn}) do
    {:ok, professional} = Accounts.create_professional(%{
      email: "test-#{System.unique_integer()}@alethea.com",
      password: "password1234",
      full_name: "Dr. Gregory House"
    })

    # Simular KEK cargada para los tests que no pasan por on_mount real
    # En LiveViewTest, el on_mount se ejecuta normalmente si usamos live/2
    
    %{conn: log_in_professional(conn, professional), professional: professional}
  end

  defp log_in_professional(conn, professional) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:professional_id, professional.id)
  end
end
