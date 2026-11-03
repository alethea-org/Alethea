defmodule AletheaWeb.DashboardTriggersSummaryLiveTest do
  use AletheaWeb.ConnCase, async: false
  use Oban.Testing, repo: Alethea.Repo

  import Phoenix.LiveViewTest

  alias Alethea.Accounts
  alias Alethea.Clinical
  alias Alethea.Encryption.PatientVault
  alias Alethea.Repo
  alias Alethea.Triggers
  alias Alethea.Triggers.Trigger

  setup [:register_and_log_in_professional]

  setup %{professional: professional} do
    Application.put_env(:alethea, :use_mock_data, false)
    on_exit(fn -> Application.put_env(:alethea, :use_mock_data, false) end)

    {:ok, kek} = Accounts.load_professional_kek(professional)
    patient_int = System.unique_integer([:positive])

    {:ok, patient} =
      Accounts.create_patient(
        %{
          "alias" => "Paciente Dashboard #{patient_int}",
          "professional_id" => professional.id,
          "timezone" => "America/Santiago"
        },
        kek
      )

    %{patient: patient, kek: kek}
  end

  defp register_and_log_in_professional(%{conn: conn}) do
    {:ok, professional} =
      Accounts.create_professional(%{
        email: "pro-dash-#{System.unique_integer([:positive])}@test.local",
        password: "supersecret123",
        full_name: "Dr. Dashboard"
      })

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> Plug.Conn.put_session(:professional_id, professional.id)

    %{conn: conn, professional: professional}
  end

  defp create_patient_for_pro(professional, kek, name) do
    {:ok, patient} =
      Accounts.create_patient(
        %{
          "alias" => name,
          "professional_id" => professional.id,
          "timezone" => "America/Santiago"
        },
        kek
      )

    patient
  end

  defp create_trigger!(professional, patient, attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    future = DateTime.add(now, 3600, :second)

    {:ok, dek} = Clinical.patient_dek(patient, "test")
    {:ok, enc_inst} = PatientVault.encrypt("Instrucción", dek)
    {:ok, enc_draft} = PatientVault.encrypt("Borrador", dek)

    enc_approved =
      if Map.get(attrs, :approved, true) do
        {:ok, enc} = PatientVault.encrypt("Aprobado", dek)
        enc
      else
        nil
      end

    params = %{
      patient_id: patient.id,
      professional_id: professional.id,
      instruction: enc_inst,
      draft_message: enc_draft,
      approved_text: enc_approved,
      scheduled_at: Map.get(attrs, :scheduled_at, future),
      timezone: patient.timezone || "America/Santiago",
      status: Map.get(attrs, :status, "active"),
      schedule_type: Map.get(attrs, :schedule_type, "once"),
      approval_revision: Map.get(attrs, :approval_revision, 1)
    }

    %Trigger{}
    |> Trigger.changeset(params)
    |> Repo.insert!()
  end

  describe "Triggers summary card on dashboard (S4, S5)" do
    test "renders card with empty state and zero metrics for patient with no triggers", %{
      conn: conn,
      patient: patient
    } do
      {:ok, view, _html} = live(conn, ~p"/dashboard/patients/#{patient.id}")

      assert has_element?(view, "#triggers-summary-card")
      assert has_element?(view, "#triggers-summary-empty")
      assert has_element?(view, "#triggers-card-manage-link")
      assert has_element?(view, "#trigger-metric-active", "0")
      assert has_element?(view, "#trigger-metric-inactive", "0")
      assert has_element?(view, "#trigger-metric-fired", "0")
      refute has_element?(view, "#trigger-metric-needs-approval")
    end

    test "links directly to the patient's triggers management page", %{
      conn: conn,
      patient: patient
    } do
      {:ok, view, _html} = live(conn, ~p"/dashboard/patients/#{patient.id}")

      assert has_element?(
               view,
               "#triggers-card-manage-link[href='/patients/#{patient.id}/triggers']"
             )
    end

    test "renders current counts by status and kind with approval-required kept separate", %{
      conn: conn,
      professional: professional,
      patient: patient
    } do
      create_trigger!(professional, patient, %{status: "active", approved: true})
      create_trigger!(professional, patient, %{status: "active", approved: false})
      create_trigger!(professional, patient, %{status: "inactive", approved: true})
      create_trigger!(professional, patient, %{status: "fired", approved: true})

      {:ok, view, _html} = live(conn, ~p"/dashboard/patients/#{patient.id}")

      assert has_element?(view, "#triggers-summary-card")
      refute has_element?(view, "#triggers-summary-empty")

      # Total badge shows 4
      assert has_element?(view, "#triggers-total-badge", "4")

      # Status metrics
      assert has_element?(view, "#trigger-metric-active", "2")
      assert has_element?(view, "#trigger-metric-inactive", "1")
      assert has_element?(view, "#trigger-metric-fired", "1")
      assert has_element?(view, "#trigger-metric-needs-approval", "1")

      # Kind breakdown
      assert has_element?(view, "#trigger-kind-active-total", "4")
      assert has_element?(view, "#trigger-kind-active-status-active", "2")
      assert has_element?(view, "#trigger-kind-active-status-inactive", "1")
      assert has_element?(view, "#trigger-kind-active-status-fired", "1")
      assert has_element?(view, "#trigger-kind-active-needs-approval", "1")

      # Reactive kind is present and shows 0
      assert has_element?(view, "#trigger-kind-reactive-total", "0")
      assert has_element?(view, "#trigger-kind-reactive-status-active", "0")
      assert has_element?(view, "#trigger-kind-reactive-status-inactive", "0")
      assert has_element?(view, "#trigger-kind-reactive-status-fired", "0")
    end

    test "refreshes counts and prevents leakage when selecting another patient", %{
      conn: conn,
      professional: professional,
      patient: patient1,
      kek: kek
    } do
      patient2 = create_patient_for_pro(professional, kek, "Paciente Segundo")

      # Patient 1 has 2 triggers, Patient 2 has none
      create_trigger!(professional, patient1, %{status: "active"})
      create_trigger!(professional, patient1, %{status: "inactive"})

      {:ok, view, _html} = live(conn, ~p"/dashboard/patients/#{patient1.id}")

      assert has_element?(view, "#trigger-metric-active", "1")
      assert has_element?(view, "#trigger-metric-inactive", "1")
      assert has_element?(view, "#triggers-total-badge", "2")

      # Switch to Patient 2
      view
      |> element("a[href='/dashboard/patients/#{patient2.id}']")
      |> render_click()

      # Counts must reflect Patient 2 (0 triggers), no leakage from Patient 1
      assert has_element?(view, "#triggers-summary-empty")
      assert has_element?(view, "#trigger-metric-active", "0")
      assert has_element?(view, "#trigger-metric-inactive", "0")
      assert has_element?(view, "#triggers-total-badge", "0")
    end

    test "refreshes counts when returning to the dashboard after trigger changes", %{
      conn: conn,
      professional: professional,
      patient: patient
    } do
      {:ok, view, _html} = live(conn, ~p"/dashboard/patients/#{patient.id}")

      assert has_element?(view, "#triggers-summary-empty")
      assert has_element?(view, "#trigger-metric-active", "0")

      # Simulate trigger creation in DB
      trigger = create_trigger!(professional, patient, %{status: "active"})

      # Re-navigate/patch to dashboard
      {:ok, view, _html} = live(conn, ~p"/dashboard/patients/#{patient.id}")

      assert has_element?(view, "#trigger-metric-active", "1")
      refute has_element?(view, "#triggers-summary-empty")

      # Deactivate trigger
      Triggers.deactivate_trigger(professional, patient.id, trigger.id)

      # Return to dashboard
      {:ok, view, _html} = live(conn, ~p"/dashboard/patients/#{patient.id}")

      assert has_element?(view, "#trigger-metric-active", "0")
      assert has_element?(view, "#trigger-metric-inactive", "1")
    end

    test "enforces ownership: foreign patient triggers are not accessible", %{
      conn: conn
    } do
      # Create foreign professional and patient
      {:ok, other_pro} =
        Accounts.create_professional(%{
          email: "foreign-pro-#{System.unique_integer([:positive])}@test.local",
          password: "supersecret123",
          full_name: "Dr. Foreign"
        })

      {:ok, other_kek} = Accounts.load_professional_kek(other_pro)

      foreign_patient =
        create_patient_for_pro(other_pro, other_kek, "Paciente Foráneo")

      create_trigger!(other_pro, foreign_patient, %{status: "active"})

      # The logged-in professional attempts to visit foreign patient's dashboard
      assert {:error, {:live_redirect, %{to: "/dashboard"}}} =
               live(conn, ~p"/dashboard/patients/#{foreign_patient.id}")
    end
  end
end
