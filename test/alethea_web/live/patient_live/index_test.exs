defmodule AletheaWeb.PatientLive.IndexTest do
  use AletheaWeb.ConnCase

  import Alethea.RagFixtures
  import Alethea.FoundationTestHelper
  import Phoenix.LiveViewTest

  alias Alethea.Accounts
  alias Alethea.Repo

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

  describe "patient card navigation (#234a)" do
    test "the card offers the grounded consultation as the clinical-record entry", %{
      conn: conn,
      professional: professional
    } do
      patient = create_patient!(professional)

      {:ok, view, html} = live(conn, ~p"/patients")

      assert has_element?(
               view,
               ~s(a[href="/patients/#{patient.id}/consultation"]),
               "Consulta clínica"
             )

      refute has_element?(view, ~s(a[href="/patients/#{patient.id}/clinical-search"]))
      refute html =~ "Búsqueda clínica"
    end
  end

  describe "crisis alert stream update via legacy_patient_id (#286)" do
    test "updates the patient's urgent_intervention in the stream without raising Ecto.NoResultsError",
         %{conn: conn, professional: professional} do
      legacy_patient = legacy_patient_fixture(professional)

      foundation_professional = professional_fixture()

      foundation_patient =
        patient_fixture(foundation_professional)
        |> Ecto.Changeset.change(%{legacy_patient_id: legacy_patient.id})
        |> Repo.update!()

      {:ok, view, _html} = live(conn, ~p"/patients")

      send(
        view.pid,
        {:crisis_detected,
         %{
           patient_id: foundation_patient.id,
           legacy_patient_id: legacy_patient.id,
           level: :high,
           triggers: ["autolesión"]
         }}
      )

      assert Process.alive?(view.pid)
      assert render(view) =~ legacy_patient.alias
    end

    test "raising Accounts.get_patient!(foundation_patient_id) would fail without legacy_patient_id (documents #286 bug shape)",
         %{professional: professional} do
      legacy_patient = legacy_patient_fixture(professional)

      foundation_professional = professional_fixture()

      foundation_patient =
        patient_fixture(foundation_professional)
        |> Ecto.Changeset.change(%{legacy_patient_id: legacy_patient.id})
        |> Repo.update!()

      assert_raise Ecto.NoResultsError, fn ->
        Accounts.get_patient!(foundation_patient.id)
      end
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
