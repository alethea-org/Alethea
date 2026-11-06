defmodule AletheaWeb.TriggersReactiveLiveTest do
  @moduledoc """
  Reactive tab of the patient triggers page (#448): a professional writes a
  condition and an instruction, reviews the drafted preview, and approves
  it; reactive triggers are listed and managed apart from scheduled ones.
  """

  use AletheaWeb.ConnCase, async: false
  use Oban.Testing, repo: Alethea.Repo

  import Mox
  import Phoenix.LiveViewTest
  import Alethea.RagFixtures

  alias Alethea.Accounts
  alias Alethea.AI.TriggerPreviewChainMock
  alias Alethea.Clinical
  alias Alethea.Repo
  alias Alethea.Triggers
  alias Alethea.Triggers.Trigger
  alias AletheaJobs.ActiveTriggerWorker

  @condition "Habla de una pelea con su madre"
  @instruction "Retomar el ejercicio de comunicación asertiva"
  @draft "¿Pudiste usar lo que practicamos para hablar con calma?"

  setup :verify_on_exit!

  setup %{conn: conn} do
    Repo.delete_all(Oban.Job)

    original = Application.get_env(:alethea, :trigger_preview_chain)
    Application.put_env(:alethea, :trigger_preview_chain, TriggerPreviewChainMock)

    on_exit(fn ->
      if original,
        do: Application.put_env(:alethea, :trigger_preview_chain, original),
        else: Application.delete_env(:alethea, :trigger_preview_chain)
    end)

    professional = create_professional!()
    {:ok, kek} = Accounts.load_professional_kek(professional)

    {:ok, patient} =
      Accounts.create_patient(
        %{
          "alias" => "Paciente #{System.unique_integer([:positive])}",
          "professional_id" => professional.id,
          "timezone" => "America/Santiago"
        },
        kek
      )

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> Plug.Conn.put_session(:professional_id, professional.id)

    %{conn: conn, professional: professional, patient: patient}
  end

  test "switches to the reactive tab and shows its empty state", %{conn: conn, patient: patient} do
    {:ok, view, _html} = live(conn, ~p"/patients/#{patient.id}/triggers")

    assert has_element?(view, "#tab-reactive")
    view |> element("#tab-reactive") |> render_click()

    assert has_element?(view, "#reactive-tab-panel")
    refute has_element?(view, "#reactive-tab-panel.hidden")
    assert has_element?(view, "#active-tab-panel.hidden")
    assert has_element?(view, "#reactive-triggers-empty")
  end

  test "drafts a preview from the instruction and approves a reactive trigger", %{
    conn: conn,
    patient: patient
  } do
    expect(TriggerPreviewChainMock, :run, fn %{instruction: @instruction} ->
      {:ok, %{draft: @draft}}
    end)

    {:ok, view, _html} = live(conn, ~p"/patients/#{patient.id}/triggers")
    view |> element("#tab-reactive") |> render_click()

    fill_reactive_form(view, @condition, @instruction)
    view |> form("#reactive-trigger-form") |> render_submit()

    assert has_element?(view, "#reactive-trigger-preview-draft", @draft)

    view |> element("#approve-reactive-trigger-button") |> render_click()

    assert [%Trigger{kind: "reactive", status: "active"} = trigger] = Repo.all(Trigger)
    assert trigger.cooldown_hours == 24
    assert is_nil(trigger.scheduled_at)

    {:ok, dek} = Clinical.patient_dek(patient, "test_check")
    assert {:ok, @condition} = Alethea.Encryption.PatientVault.decrypt(trigger.condition, dek)
    assert {:ok, @draft} = Alethea.Encryption.PatientVault.decrypt(trigger.approved_text, dek)

    refute_enqueued(worker: ActiveTriggerWorker)

    refute has_element?(view, "#reactive-triggers-empty")
    assert has_element?(view, "#reactive-trigger-#{trigger.id}", @condition)
    assert has_element?(view, "#reactive-trigger-#{trigger.id}", @draft)
    refute has_element?(view, "#active-trigger-#{trigger.id}")
    refute has_element?(view, "#reactive-trigger-preview-card")
  end

  test "approval requires a preview", %{conn: conn, patient: patient} do
    {:ok, view, _html} = live(conn, ~p"/patients/#{patient.id}/triggers")

    html = render_click(view, "approve_reactive_trigger", %{})

    assert html =~ "Debes generar una vista previa antes de aprobar."
    assert Repo.aggregate(Trigger, :count) == 0
  end

  test "a preview requires both condition and instruction", %{conn: conn, patient: patient} do
    expect(TriggerPreviewChainMock, :run, 0, fn _ -> flunk("must not draft") end)

    {:ok, view, _html} = live(conn, ~p"/patients/#{patient.id}/triggers")

    fill_reactive_form(view, "", @instruction)
    html = view |> form("#reactive-trigger-form") |> render_submit()
    assert html =~ "La condición no puede estar vacía."

    fill_reactive_form(view, @condition, "")
    html = view |> form("#reactive-trigger-form") |> render_submit()
    assert html =~ "La instrucción no puede estar vacía."
  end

  test "editing the condition or instruction after the preview discards it", %{
    conn: conn,
    patient: patient
  } do
    expect(TriggerPreviewChainMock, :run, fn _ -> {:ok, %{draft: @draft}} end)

    {:ok, view, _html} = live(conn, ~p"/patients/#{patient.id}/triggers")

    fill_reactive_form(view, @condition, @instruction)
    view |> form("#reactive-trigger-form") |> render_submit()
    assert has_element?(view, "#reactive-trigger-preview-card")

    fill_reactive_form(view, "Otra condición", @instruction)
    refute has_element?(view, "#reactive-trigger-preview-card")

    html = render_click(view, "approve_reactive_trigger", %{})
    assert html =~ "Debes generar una vista previa antes de aprobar."
    assert Repo.aggregate(Trigger, :count) == 0
  end

  test "lists reactive triggers only under the reactive tab and deactivates them", %{
    conn: conn,
    professional: professional,
    patient: patient
  } do
    {:ok, trigger} =
      Triggers.create_and_approve_reactive_trigger(professional, patient.id, %{
        "condition" => @condition,
        "instruction" => @instruction,
        "approved_text" => @draft
      })

    {:ok, view, _html} = live(conn, ~p"/patients/#{patient.id}/triggers")

    assert has_element?(view, "#reactive-trigger-#{trigger.id}")
    refute has_element?(view, "#active-trigger-#{trigger.id}")
    assert has_element?(view, "#active-triggers-empty")

    view |> element("#deactivate-reactive-trigger-button-#{trigger.id}") |> render_click()

    assert Repo.get!(Trigger, trigger.id).status == "inactive"
    assert has_element?(view, "#reactive-trigger-status-badge-#{trigger.id}", "Inactivo")

    view |> element("#activate-reactive-trigger-button-#{trigger.id}") |> render_click()

    assert Repo.get!(Trigger, trigger.id).status == "active"
    assert has_element?(view, "#reactive-trigger-status-badge-#{trigger.id}", "Activo")
  end

  test "a reactive firing in the history is labelled and has no produced-message link", %{
    conn: conn,
    professional: professional,
    patient: patient
  } do
    {:ok, trigger} =
      Triggers.create_and_approve_reactive_trigger(professional, patient.id, %{
        "condition" => @condition,
        "instruction" => @instruction,
        "approved_text" => @draft
      })

    {:ok, message} =
      Clinical.save_message(patient, "Pelea con mi madre", nil, "inbound", "spontaneous")

    {:ok, firing} =
      Triggers.record_reactive_firing(trigger.id, message.id, DateTime.utc_now())

    {:ok, view, _html} = live(conn, ~p"/patients/#{patient.id}/triggers")
    view |> element("#tab-history") |> render_click()

    assert has_element?(view, "#firing-#{firing.id}", "Reactivo")
    refute has_element?(view, "#firing-message-link-#{firing.id}")
  end

  describe "cooldown, fire-once and limit (#450)" do
    @limit_flash "Este paciente ya tiene 1 triggers reactivos activos. Desactiva uno antes de crear o activar otro."

    defp put_limit(limit) do
      original = Application.get_env(:alethea, :max_active_reactive_triggers)
      Application.put_env(:alethea, :max_active_reactive_triggers, limit)

      on_exit(fn ->
        if original,
          do: Application.put_env(:alethea, :max_active_reactive_triggers, original),
          else: Application.delete_env(:alethea, :max_active_reactive_triggers)
      end)
    end

    defp create_reactive!(professional, patient, extra \\ %{}) do
      {:ok, trigger} =
        Triggers.create_and_approve_reactive_trigger(
          professional,
          patient.id,
          Map.merge(
            %{
              "condition" => @condition,
              "instruction" => @instruction,
              "approved_text" => @draft
            },
            extra
          )
        )

      trigger
    end

    test "creates a trigger with a custom cooldown and fire-once", %{conn: conn, patient: patient} do
      expect(TriggerPreviewChainMock, :run, fn _ -> {:ok, %{draft: @draft}} end)

      {:ok, view, _html} = live(conn, ~p"/patients/#{patient.id}/triggers")
      assert has_element?(view, "#reactive-trigger-cooldown-input[value='24']")
      assert has_element?(view, "#reactive-trigger-fire-once-input")

      view
      |> form("#reactive-trigger-form", %{
        "reactive_trigger" => %{
          "condition" => @condition,
          "instruction" => @instruction,
          "cooldown_hours" => "6",
          "fire_once" => "true"
        }
      })
      |> render_submit()

      view |> element("#approve-reactive-trigger-button") |> render_click()

      assert [%Trigger{cooldown_hours: 6, fire_once: true} = trigger] = Repo.all(Trigger)
      assert has_element?(view, "#reactive-trigger-fire-once-badge-#{trigger.id}")
      assert has_element?(view, "#reactive-trigger-#{trigger.id}", "6 h")
    end

    test "edits condition, cooldown and fire-once keeping the approval", %{
      conn: conn,
      professional: professional,
      patient: patient
    } do
      trigger = create_reactive!(professional, patient)
      {:ok, view, _html} = live(conn, ~p"/patients/#{patient.id}/triggers")

      refute has_element?(view, "#reactive-trigger-fire-once-badge-#{trigger.id}")
      view |> element("#edit-reactive-trigger-button-#{trigger.id}") |> render_click()
      assert has_element?(view, "#reactive-trigger-edit-form-#{trigger.id}")

      view
      |> form("#reactive-trigger-edit-form-#{trigger.id}", %{
        "edit_reactive" => %{
          "condition" => "Habla de su trabajo",
          "cooldown_hours" => "3",
          "fire_once" => "true"
        }
      })
      |> render_submit()

      refute has_element?(view, "#reactive-trigger-edit-form-#{trigger.id}")
      assert has_element?(view, "#reactive-trigger-fire-once-badge-#{trigger.id}")

      {:ok, updated} = Triggers.get_trigger(professional, patient.id, trigger.id)
      assert updated.decrypted_condition == "Habla de su trabajo"
      assert updated.cooldown_hours == 3
      assert updated.fire_once
      assert updated.decrypted_approved_text == @draft
      assert updated.status == "active"
    end

    test "an empty condition or invalid cooldown edit is rejected", %{
      conn: conn,
      professional: professional,
      patient: patient
    } do
      trigger = create_reactive!(professional, patient)
      {:ok, view, _html} = live(conn, ~p"/patients/#{patient.id}/triggers")
      view |> element("#edit-reactive-trigger-button-#{trigger.id}") |> render_click()

      html =
        view
        |> form("#reactive-trigger-edit-form-#{trigger.id}", %{
          "edit_reactive" => %{"condition" => "  ", "cooldown_hours" => "5"}
        })
        |> render_submit()

      assert html =~ "La condición no puede estar vacía."
      assert has_element?(view, "#reactive-trigger-edit-form-#{trigger.id}")

      html =
        view
        |> form("#reactive-trigger-edit-form-#{trigger.id}", %{
          "edit_reactive" => %{"condition" => "Nueva", "cooldown_hours" => "0"}
        })
        |> render_submit()

      assert html =~ "El enfriamiento debe ser de al menos 1 hora."

      {:ok, unchanged} = Triggers.get_trigger(professional, patient.id, trigger.id)
      assert unchanged.decrypted_condition == @condition
      assert unchanged.cooldown_hours == 24
    end

    test "creating past the limit shows the limit message and creates nothing", %{
      conn: conn,
      professional: professional,
      patient: patient
    } do
      put_limit(1)
      create_reactive!(professional, patient)
      expect(TriggerPreviewChainMock, :run, fn _ -> {:ok, %{draft: @draft}} end)

      {:ok, view, _html} = live(conn, ~p"/patients/#{patient.id}/triggers")
      fill_reactive_form(view, "Otra condición", @instruction)
      view |> form("#reactive-trigger-form") |> render_submit()

      html = view |> element("#approve-reactive-trigger-button") |> render_click()

      assert html =~ @limit_flash
      assert Repo.aggregate(Trigger, :count) == 1
    end

    test "activating past the limit shows the limit message and stays inactive", %{
      conn: conn,
      professional: professional,
      patient: patient
    } do
      create_reactive!(professional, patient)
      second = create_reactive!(professional, patient, %{"condition" => "Otra"}) |> inactive!()
      put_limit(1)

      {:ok, view, _html} = live(conn, ~p"/patients/#{patient.id}/triggers")

      html = view |> element("#activate-reactive-trigger-button-#{second.id}") |> render_click()

      assert html =~ @limit_flash
      assert Repo.get!(Trigger, second.id).status == "inactive"
      assert has_element?(view, "#reactive-trigger-status-badge-#{second.id}", "Inactivo")
    end

    test "a fired fire-once trigger renders as inactive with its badge", %{
      conn: conn,
      professional: professional,
      patient: patient
    } do
      trigger = create_reactive!(professional, patient, %{"fire_once" => "true"})
      trigger |> Ecto.Changeset.change(status: "inactive") |> Repo.update!()

      {:ok, view, _html} = live(conn, ~p"/patients/#{patient.id}/triggers")

      assert has_element?(view, "#reactive-trigger-status-badge-#{trigger.id}", "Inactivo")
      assert has_element?(view, "#reactive-trigger-fire-once-badge-#{trigger.id}")
    end

    defp inactive!(trigger) do
      trigger |> Ecto.Changeset.change(status: "inactive") |> Repo.update!()
    end
  end

  defp fill_reactive_form(view, condition, instruction) do
    view
    |> form("#reactive-trigger-form", %{
      "reactive_trigger" => %{"condition" => condition, "instruction" => instruction}
    })
    |> render_change()
  end
end
