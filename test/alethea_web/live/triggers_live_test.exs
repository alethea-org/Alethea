defmodule AletheaWeb.TriggersLiveTest do
  use AletheaWeb.ConnCase, async: false
  use Oban.Testing, repo: Alethea.Repo

  import Mox
  import Phoenix.LiveViewTest
  import Alethea.RagFixtures

  alias Alethea.Accounts
  alias Alethea.Clinical
  alias Alethea.Clinical.Message
  alias Alethea.Encryption.PatientVault
  alias Alethea.Repo
  alias Alethea.Triggers
  alias Alethea.Triggers.TriggerFiring
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
          "alias" => "Paciente #{patient_int}",
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

  defp safe_start_pacer do
    case Process.whereis(Alethea.Telegram.Pacer) do
      nil ->
        :ok

      pid ->
        try do
          GenServer.stop(pid, :normal, 5_000)
        catch
          :exit, _ -> :ok
        end
    end

    Alethea.Telegram.Pacer.start_link([])
  end

  defp create_foreign_patient do
    {:ok, other_pro} =
      Accounts.create_professional(%{
        email: "other-#{System.unique_integer([:positive])}@test.local",
        password: "supersecret123",
        full_name: "Dr. Otro"
      })

    {:ok, kek} = Accounts.load_professional_kek(other_pro)

    {:ok, patient} =
      Accounts.create_patient(
        %{
          "alias" => "Paciente Ajeno",
          "professional_id" => other_pro.id,
          "timezone" => "America/Santiago"
        },
        kek
      )

    %{patient: patient, professional: other_pro}
  end

  describe "authorization and malformed UUID handling (S5, S9, B6)" do
    test "redirects non-owning professional attempting to access triggers page", %{conn: conn} do
      foreign = create_foreign_patient()

      assert {:error, {:live_redirect, %{to: "/patients"}}} =
               live(conn, ~p"/patients/#{foreign.patient.id}/triggers")
    end

    test "redirects non-owning professional attempting to view a produced message", %{conn: conn} do
      foreign = create_foreign_patient()
      fake_msg_id = Ecto.UUID.generate()

      assert {:error, {:live_redirect, %{to: "/patients"}}} =
               live(conn, ~p"/patients/#{foreign.patient.id}/triggers/messages/#{fake_msg_id}")
    end

    test "redirects safely when patient_id is a malformed UUID (B6)", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/patients"}}} =
               live(conn, ~p"/patients/malformed-patient-uuid/triggers")
    end

    test "redirects safely when message_id or patient_id is malformed in message view (B6)", %{
      conn: conn,
      patient: patient
    } do
      expected_target = "/patients/#{patient.id}/triggers"

      assert {:error, {:live_redirect, %{to: ^expected_target}}} =
               live(conn, ~p"/patients/#{patient.id}/triggers/messages/malformed-msg-uuid")

      assert {:error, {:live_redirect, %{to: "/patients"}}} =
               live(
                 conn,
                 ~p"/patients/malformed-patient-uuid/triggers/messages/#{Ecto.UUID.generate()}"
               )
    end
  end

  describe "triggers page (S1, S2, S6, S10)" do
    test "renders active tab, creation form, and empty state", %{conn: conn, patient: patient} do
      {:ok, view, _html} = live(conn, ~p"/patients/#{patient.id}/triggers")

      assert has_element?(view, "#tab-active")
      assert has_element?(view, "#tab-history")
      assert has_element?(view, "#trigger-form")
      assert has_element?(view, "#trigger-instruction-input")
      assert has_element?(view, "#trigger-date-input")
      assert has_element?(view, "#trigger-time-input")
      assert has_element?(view, "#generate-preview-button")
      assert has_element?(view, "#active-triggers-empty")
      refute has_element?(view, "#trigger-preview-card")
    end

    test "generates clinically neutral preview and approves it, scheduling send (S2, S6)", %{
      conn: conn,
      patient: patient
    } do
      Application.put_env(:alethea, :trigger_preview_chain, Alethea.AI.TriggerPreviewChainMock)

      expect(Alethea.AI.TriggerPreviewChainMock, :run, fn %{instruction: inst} ->
        assert inst =~ "respiración"
        {:ok, %{draft: "Hola! ¿Pudiste hacer los ejercicios de respiración hoy?"}}
      end)

      {:ok, view, _html} = live(conn, ~p"/patients/#{patient.id}/triggers")

      future_date = Date.utc_today() |> Date.add(2) |> Date.to_iso8601()
      time = "16:30"

      # 1. Fill form and generate preview
      view
      |> form("#trigger-form", %{
        "trigger" => %{
          "instruction" => "Preguntar por ejercicios de respiración",
          "date" => future_date,
          "time" => time
        }
      })
      |> render_change()

      html =
        view
        |> element("#generate-preview-button")
        |> render_click()

      assert html =~ "Hola! ¿Pudiste hacer los ejercicios de respiración hoy?"
      assert has_element?(view, "#trigger-preview-card")
      assert has_element?(view, "#trigger-preview-draft")
      assert has_element?(view, "#approve-trigger-button")

      # 2. Approve preview (freezes server-owned draft, encrypts per patient, schedules Oban)
      view
      |> element("#approve-trigger-button")
      |> render_click()

      # Assert trigger listed in active stream
      refute has_element?(view, "#active-triggers-empty")
      assert has_element?(view, "#active-triggers")
      assert render(view) =~ "Hola! ¿Pudiste hacer los ejercicios de respiración hoy?"

      # Oban job scheduled
      assert_enqueued(worker: ActiveTriggerWorker)
    end

    test "displays error on past date", %{conn: conn, patient: patient} do
      {:ok, view, _html} = live(conn, ~p"/patients/#{patient.id}/triggers")

      past_date = Date.utc_today() |> Date.add(-1) |> Date.to_iso8601()

      view
      |> form("#trigger-form", %{
        "trigger" => %{
          "instruction" => "Recordatorio pasado",
          "date" => past_date,
          "time" => "10:00"
        }
      })
      |> render_change()

      # Mock preview chain
      Application.put_env(:alethea, :trigger_preview_chain, Alethea.AI.TriggerPreviewChainMock)

      expect(Alethea.AI.TriggerPreviewChainMock, :run, fn _ ->
        {:ok, %{draft: "Texto borrador"}}
      end)

      view |> element("#generate-preview-button") |> render_click()

      # Attempt approval with past date
      html = view |> element("#approve-trigger-button") |> render_click()
      assert html =~ "futuro"
    end

    test "editing instruction invalidates preview draft and prevents approving stale preview (B2)",
         %{conn: conn, patient: patient} do
      Application.put_env(:alethea, :trigger_preview_chain, Alethea.AI.TriggerPreviewChainMock)

      expect(Alethea.AI.TriggerPreviewChainMock, :run, fn %{instruction: "Instruccion A"} ->
        {:ok, %{draft: "Draft para A"}}
      end)

      {:ok, view, _html} = live(conn, ~p"/patients/#{patient.id}/triggers")

      future_date = Date.utc_today() |> Date.add(2) |> Date.to_iso8601()

      # Generate preview for Instruccion A
      view
      |> form("#trigger-form", %{
        "trigger" => %{
          "instruction" => "Instruccion A",
          "date" => future_date,
          "time" => "16:30"
        }
      })
      |> render_change()

      view |> element("#generate-preview-button") |> render_click()
      assert has_element?(view, "#trigger-preview-card")
      assert render(view) =~ "Draft para A"

      # Edit instruction to Instruccion B
      view
      |> form("#trigger-form", %{
        "trigger" => %{
          "instruction" => "Instruccion B",
          "date" => future_date,
          "time" => "16:30"
        }
      })
      |> render_change()

      # Preview draft must be invalidated immediately
      refute has_element?(view, "#trigger-preview-card")

      # Attempting to approve must fail and not schedule anything
      html = render(view)
      refute html =~ "Draft para A"
      refute_enqueued(worker: ActiveTriggerWorker)
    end

    test "normal form submit triggers preview generation (B2)", %{conn: conn, patient: patient} do
      Application.put_env(:alethea, :trigger_preview_chain, Alethea.AI.TriggerPreviewChainMock)

      expect(Alethea.AI.TriggerPreviewChainMock, :run, fn %{instruction: "Instruccion submit"} ->
        {:ok, %{draft: "Draft via submit"}}
      end)

      {:ok, view, _html} = live(conn, ~p"/patients/#{patient.id}/triggers")

      future_date = Date.utc_today() |> Date.add(2) |> Date.to_iso8601()

      # Submit form normally
      view
      |> form("#trigger-form", %{
        "trigger" => %{
          "instruction" => "Instruccion submit",
          "date" => future_date,
          "time" => "16:30"
        }
      })
      |> render_submit()

      assert has_element?(view, "#trigger-preview-card")
      assert render(view) =~ "Draft via submit"
    end

    test "duplicate click on approve does not schedule twice (B2)", %{
      conn: conn,
      patient: patient
    } do
      Application.put_env(:alethea, :trigger_preview_chain, Alethea.AI.TriggerPreviewChainMock)

      expect(Alethea.AI.TriggerPreviewChainMock, :run, fn _ ->
        {:ok, %{draft: "Mensaje unico"}}
      end)

      {:ok, view, _html} = live(conn, ~p"/patients/#{patient.id}/triggers")

      future_date = Date.utc_today() |> Date.add(2) |> Date.to_iso8601()

      view
      |> form("#trigger-form", %{
        "trigger" => %{
          "instruction" => "Instruccion unica",
          "date" => future_date,
          "time" => "10:00"
        }
      })
      |> render_submit()

      # First approve
      view |> element("#approve-trigger-button") |> render_click()

      # Second approve click immediately
      render_click(view, "approve_trigger", %{})

      # Only 1 trigger in DB and 1 job enqueued
      assert Repo.aggregate(Alethea.Triggers.Trigger, :count, :id) == 1
      assert Enum.count(Repo.all(Oban.Job)) == 1
    end
  end

  describe "firing history and produced message view (S4, S8)" do
    test "displays firing history with link to produced message, and message view displays decrypted text",
         %{conn: conn, patient: patient, professional: professional} do
      future_date = Date.utc_today() |> Date.add(1)

      {:ok, trigger} =
        Triggers.create_and_approve_trigger(professional, patient.id, %{
          instruction: "Instruccion de prueba",
          approved_text: "Mensaje final entregado al paciente",
          date: future_date,
          time: ~T[11:00:00]
        })

      # Create produced message
      {:ok, dek} = Clinical.patient_dek(patient, "test_msg")
      {:ok, enc} = PatientVault.encrypt("Mensaje final entregado al paciente", dek)

      message =
        %Message{}
        |> Message.changeset(%{
          patient_id: patient.id,
          direction: "outbound",
          behavior_type: "spontaneous",
          encrypted_content: enc,
          timestamp: DateTime.utc_now() |> DateTime.truncate(:second)
        })
        |> Ecto.Changeset.put_change(:trigger_id, trigger.id)
        |> Ecto.Changeset.put_change(:delivery_state, "sent")
        |> Repo.insert!()

      firing =
        %TriggerFiring{}
        |> TriggerFiring.changeset(%{
          trigger_id: trigger.id,
          message_id: message.id,
          status: "fired",
          fired_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })
        |> Repo.insert!()

      {:ok, view, _html} = live(conn, ~p"/patients/#{patient.id}/triggers")

      # Switch to history tab
      view |> element("#tab-history") |> render_click()

      assert has_element?(view, "#trigger-firings")
      assert has_element?(view, "#firing-#{firing.id}")
      assert has_element?(view, "#firing-message-link-#{firing.id}")

      # Follow link to produced message view
      {:ok, msg_view, _html} =
        view
        |> element("#firing-message-link-#{firing.id}")
        |> render_click()
        |> follow_redirect(conn, ~p"/patients/#{patient.id}/triggers/messages/#{message.id}")

      assert has_element?(msg_view, "#produced-message-view")
      assert has_element?(msg_view, "#produced-message-body")
      assert render(msg_view) =~ "Mensaje final entregado al paciente"
      assert has_element?(msg_view, "#back-to-triggers-link")
    end

    test "truthful history shows queued before Telegram ack and sent after TelegramOutboundWorker with Fake (B4)",
         %{conn: conn, patient: patient, professional: professional} do
      {:ok, _} = safe_start_pacer()
      start_supervised!(Alethea.Telegram.Client.Fake)
      Alethea.Telegram.Client.Fake.reset()
      Application.put_env(:alethea, :telegram_client, Alethea.Telegram.Client.Fake)

      # Provision foundation patient for telegram
      {:ok, foundation_pro} =
        Alethea.Foundation.Accounts.find_or_provision_foundation_professional(professional)

      {:ok, foundation_patient} =
        Alethea.Foundation.Accounts.create_patient(foundation_pro, %{
          alias: patient.alias,
          legacy_patient_id: patient.id
        })

      foundation_patient =
        foundation_patient
        |> Ecto.Changeset.change(%{telegram_chat_id_hash: String.duplicate("d", 64)})
        |> Repo.update!()

      {:ok, _} =
        Alethea.Foundation.Accounts.store_encrypted_telegram_chat_id(
          foundation_patient,
          123_456_789
        )

      future_date = Date.utc_today() |> Date.add(1)

      {:ok, trigger} =
        Triggers.create_and_approve_trigger(professional, patient.id, %{
          instruction: "Instruccion veraz",
          approved_text: "Mensaje veraz",
          date: future_date,
          time: ~T[10:00:00]
        })

      # Make trigger due and fire it via ActiveTriggerWorker
      due_at = DateTime.utc_now() |> DateTime.add(-10, :second) |> DateTime.truncate(:second)

      trigger
      |> Ecto.Changeset.change(%{scheduled_at: due_at})
      |> Repo.update!()

      Repo.delete_all(Oban.Job)
      assert :ok = perform_job(ActiveTriggerWorker, %{"trigger_id" => trigger.id})

      # Message is pending delivery before Telegram ack
      firing = Repo.get_by!(TriggerFiring, trigger_id: trigger.id)
      message = Repo.get!(Message, firing.message_id)
      assert message.delivery_state == "pending"

      # Open LiveView on history tab: must show "En cola", NOT "Enviado"
      {:ok, view, _html} = live(conn, ~p"/patients/#{patient.id}/triggers")
      view |> element("#tab-history") |> render_click()

      history_html = render(view)
      assert history_html =~ "En cola"
      refute history_html =~ "pt-pill--sent"
      refute history_html =~ "Enviado"

      # Execute TelegramOutboundWorker to deliver via Fake
      assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :telegram_outbound)
      assert Repo.get!(Message, message.id).delivery_state == "sent"

      # Refresh LiveView history: now reflects "Enviado"
      {:ok, view2, _html} = live(conn, ~p"/patients/#{patient.id}/triggers")
      view2 |> element("#tab-history") |> render_click()

      updated_history_html = render(view2)
      assert updated_history_html =~ "Enviado"
      assert updated_history_html =~ "pt-pill--sent"
      refute updated_history_html =~ "pt-pill--queued"

      # Navigate to source message view
      {:ok, msg_view, _html} =
        view2
        |> element("#firing-message-link-#{firing.id}")
        |> render_click()
        |> follow_redirect(conn, ~p"/patients/#{patient.id}/triggers/messages/#{message.id}")

      assert render(msg_view) =~ "Mensaje veraz"
      assert render(msg_view) =~ "sent"
    end
  end
end
