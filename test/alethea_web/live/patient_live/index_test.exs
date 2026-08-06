defmodule AletheaWeb.PatientLive.IndexTest do
  use AletheaWeb.ConnCase
  import Phoenix.LiveViewTest

  alias Alethea.Accounts

  setup [:register_and_log_in_professional]

  describe "registration form (WhatsApp retirement, #107)" do
    test "does not render a WhatsApp number input or its privacy copy", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/patients/new")

      # The alias field is still present — the form renders.
      assert has_element?(view, "input[name='patient[alias]']")

      # No WhatsApp input nor its channel-specific privacy copy.
      refute has_element?(view, "input[name='patient[whatsapp_number]']")
      refute html =~ "Número de WhatsApp"
      refute html =~ "número de WhatsApp"
    end

    test "submitting only the alias creates the patient", %{
      conn: conn,
      professional: professional
    } do
      {:ok, view, _html} = live(conn, ~p"/patients/new")

      html =
        view
        |> form("#patient-form", patient: %{alias: "Solo Alias"})
        |> render_submit()

      assert html =~ "Paciente registrado exitosamente."

      patients = Accounts.list_patients(professional.id)
      assert Enum.any?(patients, &(&1.alias == "Solo Alias"))
    end
  end

  defp register_and_log_in_professional(%{conn: conn}) do
    {:ok, professional} =
      Accounts.create_professional(%{
        email: "test-#{System.unique_integer()}@alethea.com",
        password: "password1234",
        full_name: "Dra. Test"
      })

    %{conn: log_in_professional(conn, professional), professional: professional}
  end

  defp log_in_professional(conn, professional) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:professional_id, professional.id)
  end
end
