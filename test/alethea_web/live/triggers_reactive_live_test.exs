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

  defp fill_reactive_form(view, condition, instruction) do
    view
    |> form("#reactive-trigger-form", %{
      "reactive_trigger" => %{"condition" => condition, "instruction" => instruction}
    })
    |> render_change()
  end
end
