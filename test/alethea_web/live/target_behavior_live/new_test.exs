defmodule AletheaWeb.TargetBehaviorLive.NewTest do
  use AletheaWeb.ConnCase, async: false
  use Oban.Testing, repo: Alethea.Repo

  import Alethea.RagFixtures, only: [create_patient!: 1]
  import Phoenix.LiveViewTest

  alias Alethea.Accounts
  alias Alethea.ClinicalRecord
  alias Alethea.ClinicalRecord.TargetBehavior
  alias Alethea.Repo
  alias AletheaJobs.ClinicalRecordOutboxWorker

  @password "supersecret12"

  setup [:register_and_log_in_professional]

  setup %{professional: professional} do
    patient = create_patient!(professional)
    %{patient: patient}
  end

  describe "new target behavior" do
    test "renders an authenticated patient-scoped form", %{conn: conn, patient: patient} do
      {:ok, view, _html} = live(conn, ~p"/patients/#{patient.id}/target_behaviors/new")

      assert has_element?(view, "#new-target-behavior-page", patient.alias)
      assert has_element?(view, "#target-behavior-form")
      assert has_element?(view, "#target-behavior-description-input")

      assert has_element?(
               view,
               "#cancel-target-behavior-link[href='/dashboard/patients/#{patient.id}']"
             )
    end

    test "rejects a blank description without persistence", %{conn: conn, patient: patient} do
      {:ok, view, _html} = live(conn, ~p"/patients/#{patient.id}/target_behaviors/new")

      html =
        view
        |> form("#target-behavior-form", %{
          "target_behavior" => %{"description" => "   "}
        })
        |> render_submit()

      assert html =~ "La descripción de la conducta objetivo no puede estar vacía."
      assert Repo.aggregate(TargetBehavior, :count) == 0
      refute_enqueued(worker: ClinicalRecordOutboxWorker)
    end

    test "trims, creates, confirms, and continues to the behavior workbench", %{
      conn: conn,
      professional: professional,
      patient: patient
    } do
      {:ok, view, _html} = live(conn, ~p"/patients/#{patient.id}/target_behaviors/new")

      result =
        view
        |> form("#target-behavior-form", %{
          "target_behavior" => %{"description" => "  Evita responder ante consignas nuevas  "}
        })
        |> render_submit()

      [created] = Repo.all(TargetBehavior)
      expected_path = ~p"/patients/#{patient.id}/target_behaviors/#{created.id}/review"

      assert {:ok, review_view, _html} = follow_redirect(result, conn, expected_path)
      assert has_element?(review_view, "#flash-info", "Conducta objetivo creada exitosamente.")

      assert {:ok, [behavior]} = ClinicalRecord.list_target_behaviors(professional, patient.id)
      assert behavior.id == created.id
      assert behavior.description == "Evita responder ante consignas nuevas"
      refute created.encrypted_description == "Evita responder ante consignas nuevas"

      assert_enqueued(
        worker: ClinicalRecordOutboxWorker,
        args: %{
          "event" => "target_behavior_created",
          "patient_id" => patient.id,
          "professional_id" => professional.id
        }
      )

      {:ok, dashboard_view, _html} = live(conn, ~p"/dashboard/patients/#{patient.id}")

      assert has_element?(
               dashboard_view,
               "#target-behavior-#{created.id}",
               "Evita responder ante consignas nuevas"
             )

      assert has_element?(
               dashboard_view,
               "#target-behavior-review-link-#{created.id}[href='#{expected_path}']"
             )
    end

    test "cancel returns to the patient dashboard without persistence", %{
      conn: conn,
      patient: patient
    } do
      {:ok, view, _html} = live(conn, ~p"/patients/#{patient.id}/target_behaviors/new")

      result =
        view
        |> element("#cancel-target-behavior-link")
        |> render_click()

      assert {:ok, dashboard_view, _html} =
               follow_redirect(result, conn, ~p"/dashboard/patients/#{patient.id}")

      assert has_element?(dashboard_view, "#target-behaviors-section")
      assert Repo.aggregate(TargetBehavior, :count) == 0
      refute_enqueued(worker: ClinicalRecordOutboxWorker)
    end

    test "denies a professional who does not treat the patient before creation", %{
      patient: patient
    } do
      other_professional = create_professional!()
      other_conn = log_in_professional(build_conn(), other_professional)

      assert Repo.aggregate(TargetBehavior, :count) == 0

      assert {:error, {:live_redirect, %{to: "/patients"}}} =
               live(other_conn, ~p"/patients/#{patient.id}/target_behaviors/new")

      assert Repo.aggregate(TargetBehavior, :count) == 0
      refute_enqueued(worker: ClinicalRecordOutboxWorker)
    end
  end

  defp register_and_log_in_professional(%{conn: conn}) do
    professional = create_professional!()
    %{conn: log_in_professional(conn, professional), professional: professional}
  end

  defp create_professional! do
    {:ok, professional} =
      Accounts.create_professional(%{
        email: "new-target-behavior-#{System.unique_integer([:positive])}@alethea.com",
        password: @password,
        full_name: "Dra. Conductas"
      })

    professional
  end

  defp log_in_professional(conn, professional) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:professional_id, professional.id)
  end
end
