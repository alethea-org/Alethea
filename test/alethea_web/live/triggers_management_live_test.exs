defmodule AletheaWeb.TriggersManagementLiveTest do
  use AletheaWeb.ConnCase, async: false
  use Oban.Testing, repo: Alethea.Repo

  import Mox
  import Phoenix.LiveViewTest
  import Alethea.RagFixtures

  alias Alethea.Accounts
  alias Alethea.Repo
  alias Alethea.Triggers
  alias Alethea.Triggers.Trigger
  alias AletheaJobs.ActiveTriggerWorker

  setup :verify_on_exit!
  setup [:register_and_log_in_professional]

  setup %{professional: professional} do
    Repo.delete_all(Oban.Job)

    {:ok, kek} = Accounts.load_professional_kek(professional)
    patient_int = System.unique_integer([:positive])

    {:ok, patient} =
      Accounts.create_patient(
        %{
          "alias" => "Paciente Mgmt #{patient_int}",
          "professional_id" => professional.id,
          "timezone" => "America/Santiago"
        },
        kek
      )

    %{patient: patient, kek: kek}
  end

  defp register_and_log_in_professional(%{conn: conn}) do
    professional = create_professional!()
    %{conn: log_in_professional(conn, professional), professional: professional}
  end

  defp log_in_professional(conn, professional) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:professional_id, professional.id)
  end

  defp create_foreign_patient do
    {:ok, other_pro} =
      Accounts.create_professional(%{
        email: "foreign-pro-#{System.unique_integer([:positive])}@test.local",
        password: "supersecret123",
        full_name: "Dra. Otra"
      })

    {:ok, kek} = Accounts.load_professional_kek(other_pro)

    {:ok, patient} =
      Accounts.create_patient(
        %{
          "alias" => "Paciente Foráneo",
          "professional_id" => other_pro.id,
          "timezone" => "America/Santiago"
        },
        kek
      )

    %{patient: patient, professional: other_pro}
  end

  defp create_test_trigger(professional, patient, opts \\ []) do
    future_date = Keyword.get(opts, :date, Date.utc_today() |> Date.add(3))
    time = Keyword.get(opts, :time, ~T[14:00:00])
    inst = Keyword.get(opts, :instruction, "Instrucción base de prueba")
    app_text = Keyword.get(opts, :approved_text, "Texto base aprobado")

    {:ok, trigger} =
      Triggers.create_and_approve_trigger(professional, patient.id, %{
        instruction: inst,
        approved_text: app_text,
        date: future_date,
        time: time
      })

    trigger
  end

  describe "trigger activation and deactivation (S1, S5, S6)" do
    test "professional can deactivate an active trigger (S1)", %{
      conn: conn,
      patient: patient,
      professional: professional
    } do
      trigger = create_test_trigger(professional, patient)
      assert trigger.status == "active"
      assert_enqueued(worker: ActiveTriggerWorker, args: %{"trigger_id" => trigger.id})

      {:ok, view, _html} = live(conn, ~p"/patients/#{patient.id}/triggers")

      assert has_element?(view, "#trigger-status-badge-#{trigger.id}", "Activo")
      assert has_element?(view, "#deactivate-trigger-button-#{trigger.id}")
      refute has_element?(view, "#activate-trigger-button-#{trigger.id}")

      # Deactivate trigger
      view
      |> element("#deactivate-trigger-button-#{trigger.id}")
      |> render_click()

      # Assert DB status is inactive and Oban job was pruned
      updated = Repo.get!(Trigger, trigger.id)
      assert updated.status == "inactive"
      refute_enqueued(worker: ActiveTriggerWorker, args: %{"trigger_id" => trigger.id})

      # Assert UI updated
      assert has_element?(view, "#trigger-status-badge-#{trigger.id}", "Inactivo")
      assert has_element?(view, "#activate-trigger-button-#{trigger.id}")
      refute has_element?(view, "#deactivate-trigger-button-#{trigger.id}")
    end

    test "professional can reactivate an inactive trigger (S1, S6)", %{
      conn: conn,
      patient: patient,
      professional: professional
    } do
      trigger = create_test_trigger(professional, patient)
      {:ok, inactive_trigger} = Triggers.deactivate_trigger(professional, patient.id, trigger.id)
      assert inactive_trigger.status == "inactive"
      Repo.delete_all(Oban.Job)

      {:ok, view, _html} = live(conn, ~p"/patients/#{patient.id}/triggers")

      assert has_element?(view, "#trigger-status-badge-#{trigger.id}", "Inactivo")
      assert has_element?(view, "#activate-trigger-button-#{trigger.id}")

      # Reactivate trigger
      view
      |> element("#activate-trigger-button-#{trigger.id}")
      |> render_click()

      # Assert DB status is active and Oban job is enqueued
      reactivated = Repo.get!(Trigger, trigger.id)
      assert reactivated.status == "active"
      assert_enqueued(worker: ActiveTriggerWorker, args: %{"trigger_id" => trigger.id})

      # Assert UI reflects active state
      assert has_element?(view, "#trigger-status-badge-#{trigger.id}", "Activo")
      assert has_element?(view, "#deactivate-trigger-button-#{trigger.id}")
    end

    test "reactivating an expired one-shot trigger returns actionable error and stays inactive (S6)",
         %{
           conn: conn,
           patient: patient,
           professional: professional
         } do
      trigger = create_test_trigger(professional, patient)

      # Deactivate and artificially move scheduled_at into the past
      {:ok, _} = Triggers.deactivate_trigger(professional, patient.id, trigger.id)

      past_dt =
        DateTime.utc_now()
        |> DateTime.add(-2, :day)
        |> DateTime.truncate(:second)

      trigger
      |> Ecto.Changeset.change(%{scheduled_at: past_dt})
      |> Repo.update!()

      {:ok, view, _html} = live(conn, ~p"/patients/#{patient.id}/triggers")

      # Attempt activation
      html =
        view
        |> element("#activate-trigger-button-#{trigger.id}")
        |> render_click()

      # Shows actionable error
      assert html =~ "El horario programado ya venció"

      # Status in DB remains inactive
      assert Repo.get!(Trigger, trigger.id).status == "inactive"
    end

    test "reactivating an unapproved trigger returns actionable error (S2)", %{
      conn: conn,
      patient: patient,
      professional: professional
    } do
      trigger = create_test_trigger(professional, patient)

      # Update instruction so approved_text is cleared to nil
      {:ok, updated} =
        Triggers.update_trigger_instruction(
          professional,
          patient.id,
          trigger.id,
          "Nueva instruccion no aprobada"
        )

      assert is_nil(updated.approved_text)
      {:ok, _} = Triggers.deactivate_trigger(professional, patient.id, trigger.id)

      {:ok, view, _html} = live(conn, ~p"/patients/#{patient.id}/triggers")

      # Attempt activation
      html =
        view
        |> element("#activate-trigger-button-#{trigger.id}")
        |> render_click()

      assert html =~ "No se puede activar un trigger sin mensaje aprobado"
      assert Repo.get!(Trigger, trigger.id).status == "inactive"
    end
  end

  describe "instruction edit and re-approval workflow (S2, S3, S5)" do
    test "editing instruction persists immediately, clears approval in DB, and increments revision even when preview fails (S2)",
         %{
           conn: conn,
           patient: patient,
           professional: professional
         } do
      trigger = create_test_trigger(professional, patient)
      assert trigger.approval_revision == 1

      # Configure preview mock to fail
      Application.put_env(:alethea, :trigger_preview_chain, Alethea.AI.TriggerPreviewChainMock)

      expect(Alethea.AI.TriggerPreviewChainMock, :run, fn _ ->
        {:error, :llm_unavailable}
      end)

      {:ok, view, _html} = live(conn, ~p"/patients/#{patient.id}/triggers")

      # Click edit button
      view
      |> element("#edit-trigger-button-#{trigger.id}")
      |> render_click()

      assert has_element?(view, "#edit-trigger-form-#{trigger.id}")
      assert has_element?(view, "#edit-instruction-input-#{trigger.id}")

      # Submit new instruction
      html =
        view
        |> form("#edit-trigger-form-#{trigger.id}", %{
          "edit_trigger" => %{
            "instruction" => "Nueva instrucción clínica modificada"
          }
        })
        |> render_submit()

      # Preview generation failed
      assert html =~ "No se pudo generar la vista previa"

      # Crucial security guarantee: instruction edit was persisted FIRST,
      # approval was CLEARED in DB, and revision incremented
      reloaded = Repo.get!(Trigger, trigger.id)
      assert is_nil(reloaded.approved_text)
      assert is_nil(reloaded.draft_message)
      assert reloaded.approval_revision == 2
      refute_enqueued(worker: ActiveTriggerWorker, args: %{"trigger_id" => trigger.id})

      # Trigger shows "Requiere aprobación" in UI
      assert has_element?(view, "#trigger-approval-badge-#{trigger.id}", "Requiere aprobación")
    end

    test "full regeneration of preview and reapproval flow (S2, S3)", %{
      conn: conn,
      patient: patient,
      professional: professional
    } do
      trigger = create_test_trigger(professional, patient)

      Application.put_env(:alethea, :trigger_preview_chain, Alethea.AI.TriggerPreviewChainMock)

      expect(Alethea.AI.TriggerPreviewChainMock, :run, fn %{instruction: inst} ->
        assert inst == "Instrucción terapéutica actualizada"
        {:ok, %{draft: "Hola! Este es el nuevo mensaje regenerado."}}
      end)

      {:ok, view, _html} = live(conn, ~p"/patients/#{patient.id}/triggers")

      # 1. Open edit form
      view
      |> element("#edit-trigger-button-#{trigger.id}")
      |> render_click()

      # 2. Change instruction and generate preview
      view
      |> form("#edit-trigger-form-#{trigger.id}", %{
        "edit_trigger" => %{
          "instruction" => "Instrucción terapéutica actualizada"
        }
      })
      |> render_submit()

      # Preview card appears with generated text
      assert has_element?(view, "#edit-preview-card-#{trigger.id}")
      assert has_element?(view, "#edit-preview-draft-#{trigger.id}")
      assert render(view) =~ "Hola! Este es el nuevo mensaje regenerado."

      # In DB, instruction is saved, approved_text is nil, rev is 2
      in_flight = Repo.get!(Trigger, trigger.id)
      assert is_nil(in_flight.approved_text)
      assert in_flight.approval_revision == 2

      # 3. Explicitly approve the new preview
      view
      |> element("#approve-edit-button-#{trigger.id}")
      |> render_click()

      # Flash success
      assert render(view) =~ "Trigger actualizado y aprobado exitosamente."

      # Edit section closed
      refute has_element?(view, "#edit-trigger-section-#{trigger.id}")
      refute has_element?(view, "#trigger-approval-badge-#{trigger.id}")

      # DB has new approved_text and re-enqueued ActiveTriggerWorker
      final_trigger = Repo.get!(Trigger, trigger.id)
      assert final_trigger.approval_revision == 2
      assert final_trigger.status == "active"
      assert_enqueued(worker: ActiveTriggerWorker, args: %{"trigger_id" => trigger.id})
    end

    test "submitting unchanged instruction preserves existing approved text and revision (S2)", %{
      conn: conn,
      patient: patient,
      professional: professional
    } do
      trigger =
        create_test_trigger(professional, patient,
          instruction: "Instruccion original idéntica",
          approved_text: "Mensaje original intacto"
        )

      assert trigger.approval_revision == 1

      Application.put_env(:alethea, :trigger_preview_chain, Alethea.AI.TriggerPreviewChainMock)

      expect(Alethea.AI.TriggerPreviewChainMock, :run, fn _ ->
        {:ok, %{draft: "Mensaje nuevo generado"}}
      end)

      {:ok, view, _html} = live(conn, ~p"/patients/#{patient.id}/triggers")

      # Open edit
      view |> element("#edit-trigger-button-#{trigger.id}") |> render_click()

      # Submit unchanged instruction
      view
      |> form("#edit-trigger-form-#{trigger.id}", %{
        "edit_trigger" => %{
          "instruction" => "Instruccion original idéntica"
        }
      })
      |> render_submit()

      # DB trigger still has revision 1 and original approved text
      persisted = Repo.get!(Trigger, trigger.id)
      assert persisted.approval_revision == 1
      refute is_nil(persisted.approved_text)
    end

    test "concurrent edit triggers stale revision error and requires new preview (S2, S5)", %{
      conn: conn,
      patient: patient,
      professional: professional
    } do
      trigger = create_test_trigger(professional, patient)

      Application.put_env(:alethea, :trigger_preview_chain, Alethea.AI.TriggerPreviewChainMock)

      expect(Alethea.AI.TriggerPreviewChainMock, :run, fn _ ->
        {:ok, %{draft: "Draft antes de concurrencia"}}
      end)

      {:ok, view, _html} = live(conn, ~p"/patients/#{patient.id}/triggers")

      # Open edit and generate preview
      view |> element("#edit-trigger-button-#{trigger.id}") |> render_click()

      view
      |> form("#edit-trigger-form-#{trigger.id}", %{
        "edit_trigger" => %{
          "instruction" => "Instrucción que va a ser adelantada"
        }
      })
      |> render_submit()

      assert has_element?(view, "#edit-preview-card-#{trigger.id}")

      # Simulate concurrent edit bumping approval_revision in DB
      trigger
      |> Ecto.Changeset.change(%{approval_revision: 99})
      |> Repo.update!()

      # Attempt approval with stale snapshot
      html =
        view
        |> element("#approve-edit-button-#{trigger.id}")
        |> render_click()

      assert html =~ "modificado concurrentemente"
      refute has_element?(view, "#edit-preview-card-#{trigger.id}")
    end

    test "forged client params during approval event are ignored in favor of server snapshot", %{
      conn: conn,
      patient: patient,
      professional: professional
    } do
      trigger = create_test_trigger(professional, patient)

      # Attempt to send forged approved_text directly via event without generating preview
      {:ok, view, _html} = live(conn, ~p"/patients/#{patient.id}/triggers")

      html =
        render_click(view, "approve_edit", %{
          "id" => trigger.id,
          "approved_text" => "FORGED INJECTED CONTENT",
          "expected_revision" => 1
        })

      assert html =~ "Debes generar una vista previa antes de aprobar"

      # Trigger in DB was NOT modified with forged content
      persisted = Repo.get!(Trigger, trigger.id)
      assert persisted.approval_revision == 1
    end

    test "editing an inactive trigger preserves inactive status through reapproval until therapist activates (S1)",
         %{
           conn: conn,
           patient: patient,
           professional: professional
         } do
      trigger = create_test_trigger(professional, patient)
      {:ok, _} = Triggers.deactivate_trigger(professional, patient.id, trigger.id)
      assert Repo.get!(Trigger, trigger.id).status == "inactive"

      Application.put_env(:alethea, :trigger_preview_chain, Alethea.AI.TriggerPreviewChainMock)

      expect(Alethea.AI.TriggerPreviewChainMock, :run, fn _ ->
        {:ok, %{draft: "Nuevo mensaje para trigger inactivo"}}
      end)

      {:ok, view, _html} = live(conn, ~p"/patients/#{patient.id}/triggers")

      # Edit and approve
      view |> element("#edit-trigger-button-#{trigger.id}") |> render_click()

      view
      |> form("#edit-trigger-form-#{trigger.id}", %{
        "edit_trigger" => %{
          "instruction" => "Nueva instrucción para inactivo"
        }
      })
      |> render_submit()

      view |> element("#approve-edit-button-#{trigger.id}") |> render_click()

      # Trigger must STILL be inactive in DB
      reapproved = Repo.get!(Trigger, trigger.id)
      assert reapproved.status == "inactive"
      refute_enqueued(worker: ActiveTriggerWorker, args: %{"trigger_id" => trigger.id})

      # UI shows inactive badge and activate button
      assert has_element?(view, "#trigger-status-badge-#{trigger.id}", "Inactivo")
      assert has_element?(view, "#activate-trigger-button-#{trigger.id}")

      # Now activate
      view |> element("#activate-trigger-button-#{trigger.id}") |> render_click()
      assert Repo.get!(Trigger, trigger.id).status == "active"
      assert_enqueued(worker: ActiveTriggerWorker, args: %{"trigger_id" => trigger.id})
    end

    test "editing params change invalidates displayed preview if instruction differs", %{
      conn: conn,
      patient: patient,
      professional: professional
    } do
      trigger = create_test_trigger(professional, patient)

      Application.put_env(:alethea, :trigger_preview_chain, Alethea.AI.TriggerPreviewChainMock)

      expect(Alethea.AI.TriggerPreviewChainMock, :run, fn _ ->
        {:ok, %{draft: "Draft inicial"}}
      end)

      {:ok, view, _html} = live(conn, ~p"/patients/#{patient.id}/triggers")

      view |> element("#edit-trigger-button-#{trigger.id}") |> render_click()

      # Generate preview for instruction 1
      view
      |> form("#edit-trigger-form-#{trigger.id}", %{
        "edit_trigger" => %{
          "instruction" => "Instruccion inicial"
        }
      })
      |> render_submit()

      assert has_element?(view, "#edit-preview-card-#{trigger.id}")

      # Modify instruction in form
      view
      |> form("#edit-trigger-form-#{trigger.id}", %{
        "edit_trigger" => %{
          "instruction" => "Instruccion cambiada tras preview"
        }
      })
      |> render_change()

      # Preview card must be invalidated immediately
      refute has_element?(view, "#edit-preview-card-#{trigger.id}")
    end

    test "canceling edit restores card without edit form", %{
      conn: conn,
      patient: patient,
      professional: professional
    } do
      trigger = create_test_trigger(professional, patient)

      {:ok, view, _html} = live(conn, ~p"/patients/#{patient.id}/triggers")

      view |> element("#edit-trigger-button-#{trigger.id}") |> render_click()
      assert has_element?(view, "#edit-trigger-form-#{trigger.id}")

      view |> element("#cancel-edit-button-#{trigger.id}") |> render_click()
      refute has_element?(view, "#edit-trigger-form-#{trigger.id}")
      assert has_element?(view, "#edit-trigger-button-#{trigger.id}")
    end

    test "switching edit from trigger A to trigger B removes A's edit form and preview while opening B (correctness-stream-reinsert-edit-switch)",
         %{
           conn: conn,
           patient: patient,
           professional: professional
         } do
      future_date = Date.utc_today() |> Date.add(4)

      t_a =
        create_test_trigger(professional, patient,
          date: future_date,
          time: ~T[10:00:00],
          instruction: "Instruccion A original",
          approved_text: "Texto A aprobado"
        )

      t_b =
        create_test_trigger(professional, patient,
          date: future_date,
          time: ~T[11:00:00],
          instruction: "Instruccion B original",
          approved_text: "Texto B aprobado"
        )

      Application.put_env(:alethea, :trigger_preview_chain, Alethea.AI.TriggerPreviewChainMock)

      expect(Alethea.AI.TriggerPreviewChainMock, :run, fn %{
                                                            instruction:
                                                              "Instruccion A modificada"
                                                          } ->
        {:ok, %{draft: "Vista previa para A"}}
      end)

      {:ok, view, _html} = live(conn, ~p"/patients/#{patient.id}/triggers")

      # 1. Open edit on trigger A and generate preview
      view |> element("#edit-trigger-button-#{t_a.id}") |> render_click()
      assert has_element?(view, "#edit-trigger-form-#{t_a.id}")

      view
      |> form("#edit-trigger-form-#{t_a.id}", %{
        "edit_trigger" => %{
          "instruction" => "Instruccion A modificada"
        }
      })
      |> render_submit()

      assert has_element?(view, "#edit-preview-card-#{t_a.id}")

      # 2. Switch edit to trigger B
      view |> element("#edit-trigger-button-#{t_b.id}") |> render_click()

      # A's edit form and preview card MUST be absent from DOM
      refute has_element?(view, "#edit-trigger-section-#{t_a.id}")
      refute has_element?(view, "#edit-trigger-form-#{t_a.id}")
      refute has_element?(view, "#edit-preview-card-#{t_a.id}")

      # B's edit form must be present and usable
      assert has_element?(view, "#edit-trigger-section-#{t_b.id}")
      assert has_element?(view, "#edit-trigger-form-#{t_b.id}")
      assert has_element?(view, "#edit-instruction-input-#{t_b.id}")

      # Verify no unintended persisted changes on B from merely selecting B
      reloaded_b = Repo.get!(Trigger, t_b.id)
      assert reloaded_b.approval_revision == 1
      refute is_nil(reloaded_b.approved_text)
    end
  end

  describe "authorization and non-owner protections (S5)" do
    test "unauthorized foreign professional cannot deactivate or activate triggers via event injection",
         %{conn: conn, patient: patient, professional: professional} do
      # Create patient and trigger owned by professional A
      trigger = create_test_trigger(professional, patient)

      # Log in as foreign professional B
      foreign = create_foreign_patient()
      foreign_conn = log_in_professional(conn, foreign.professional)

      # Accessing foreign patient triggers page is blocked
      assert {:error, {:live_redirect, %{to: "/patients"}}} =
               live(foreign_conn, ~p"/patients/#{patient.id}/triggers")

      # Attempting event on foreign trigger from own triggers page fails cleanly
      {:ok, foreign_view, _html} =
        live(foreign_conn, ~p"/patients/#{foreign.patient.id}/triggers")

      # Foreign professional tries to deactivate professional A's trigger
      html = render_click(foreign_view, "deactivate_trigger", %{"id" => trigger.id})
      assert html =~ "No estás autorizado" or html =~ "no encontrado"

      # Professional A's trigger remains active
      assert Repo.get!(Trigger, trigger.id).status == "active"
    end
  end

  describe "listing of inactive, unapproved, and fired triggers" do
    test "mount displays active, inactive, unapproved, and fired triggers appropriately", %{
      conn: conn,
      patient: patient,
      professional: professional
    } do
      future_date = Date.utc_today() |> Date.add(5)

      # 1. Active trigger
      t1 = create_test_trigger(professional, patient, date: future_date, time: ~T[10:00:00])

      # 2. Inactive trigger
      t2 = create_test_trigger(professional, patient, date: future_date, time: ~T[11:00:00])
      {:ok, _} = Triggers.deactivate_trigger(professional, patient.id, t2.id)

      # 3. Unapproved trigger
      t3 = create_test_trigger(professional, patient, date: future_date, time: ~T[12:00:00])

      {:ok, _} =
        Triggers.update_trigger_instruction(
          professional,
          patient.id,
          t3.id,
          "Instruccion modificada pendiente"
        )

      # 4. Fired trigger
      t4 = create_test_trigger(professional, patient, date: future_date, time: ~T[13:00:00])

      t4
      |> Ecto.Changeset.change(%{status: "fired"})
      |> Repo.update!()

      {:ok, view, _html} = live(conn, ~p"/patients/#{patient.id}/triggers")

      # Assert all 4 triggers are present in active triggers stream
      assert has_element?(view, "#trigger-status-badge-#{t1.id}", "Activo")
      assert has_element?(view, "#deactivate-trigger-button-#{t1.id}")

      assert has_element?(view, "#trigger-status-badge-#{t2.id}", "Inactivo")
      assert has_element?(view, "#activate-trigger-button-#{t2.id}")

      assert has_element?(view, "#trigger-approval-badge-#{t3.id}", "Requiere aprobación")

      # Fired trigger is read-only
      assert has_element?(view, "#trigger-status-badge-#{t4.id}", "Finalizado")
      refute has_element?(view, "#edit-trigger-button-#{t4.id}")
      refute has_element?(view, "#activate-trigger-button-#{t4.id}")
      refute has_element?(view, "#deactivate-trigger-button-#{t4.id}")
    end
  end
end
