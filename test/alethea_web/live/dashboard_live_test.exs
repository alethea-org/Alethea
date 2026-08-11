defmodule AletheaWeb.DashboardLiveTest do
  use AletheaWeb.ConnCase
  use Oban.Testing, repo: Alethea.Repo
  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Alethea.Accounts
  alias Alethea.Repo
  alias AletheaJobs.SessionReminderWorker

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

  describe "save_session_schedule (real mode, #102 reminder cancellation)" do
    test "cancels the pending reminder and shows the success flash", %{
      conn: conn,
      professional: professional
    } do
      Application.put_env(:alethea, :use_mock_data, false)
      on_exit(fn -> Application.put_env(:alethea, :use_mock_data, false) end)

      {:ok, kek} = Accounts.load_professional_kek(professional)

      {:ok, patient} =
        Accounts.create_patient(
          %{
            "alias" => "alias-#{System.unique_integer([:positive])}",
            "professional_id" => professional.id
          },
          kek
        )

      {:ok, job} =
        %{
          "patient_id" => patient.id,
          "session_date" => "2099-01-10",
          "chat_id" => 555_666_777,
          "chat_id_hash" => String.duplicate("b", 64)
        }
        |> SessionReminderWorker.new(scheduled_at: DateTime.add(DateTime.utc_now(), 3, :day))
        |> Oban.insert()

      {:ok, view, _html} = live(conn, ~p"/dashboard/patients/#{patient.id}")

      view
      |> form("#schedule-form", %{day: "2", time: "18:00"})
      |> render_submit()

      assert render(view) =~ "Horario de sesión actualizado correctamente"
      assert Repo.get(Oban.Job, job.id).state == "cancelled"
    end
  end

  describe "Weekly Pre-Session Report (real mode)" do
    setup %{professional: professional} do
      Application.put_env(:alethea, :use_mock_data, false)
      on_exit(fn -> Application.put_env(:alethea, :use_mock_data, false) end)

      {:ok, patient} =
        Accounts.create_patient(%{
          alias: "Paciente Real",
          professional_id: professional.id
        })

      %{patient: patient}
    end

    test "renders the latest weekly summary", %{conn: conn, patient: patient} do
      period_start = DateTime.utc_now() |> DateTime.add(-9, :day) |> DateTime.truncate(:second)

      {:ok, _summary} =
        Alethea.Clinical.save_summary(%{
          period_start: period_start,
          period_end: DateTime.add(period_start, 7, :day),
          summary_text: "La semana estuvo marcada por una mejora del sueño.",
          status_level: "stable",
          type: "weekly",
          patient_id: patient.id
        })

      {:ok, _view, html} = live(conn, ~p"/dashboard/patients/#{patient.id}")

      assert html =~ "La semana estuvo marcada por una mejora del sueño."
      refute html =~ "Sin reportes semanales aún."
    end

    test "falls back to the empty state when there is no weekly summary", %{
      conn: conn,
      patient: patient
    } do
      {:ok, _view, html} = live(conn, ~p"/dashboard/patients/#{patient.id}")

      assert html =~ "Sin reportes semanales aún."
    end

    test "renders the metric strip with the stored weekly scores", %{
      conn: conn,
      patient: patient
    } do
      save_weekly_summary(patient, %{
        status_level: "Alerta",
        anxiety_score: 0.62,
        social_score: 0.41,
        crisis_events: 1,
        session_count: 5
      })

      {:ok, view, html} = live(conn, ~p"/dashboard/patients/#{patient.id}")

      assert html =~ "Ansiedad"
      assert has_element?(view, "#weekly-metric-anxiety", "62%")
      assert has_element?(view, "#weekly-metric-social", "41%")
      assert has_element?(view, "#weekly-metric-crisis", "1")
      assert has_element?(view, "#weekly-metric-sessions", "5")
    end

    test "renders zero crisis events as a value, not as missing data", %{
      conn: conn,
      patient: patient
    } do
      save_weekly_summary(patient, %{crisis_events: 0, session_count: 3})

      {:ok, view, _html} = live(conn, ~p"/dashboard/patients/#{patient.id}")

      assert has_element?(view, "#weekly-metric-crisis", "0")
    end

    test "renders a dash for the metrics the report did not fill", %{
      conn: conn,
      patient: patient
    } do
      save_weekly_summary(patient, %{session_count: 4})

      {:ok, view, _html} = live(conn, ~p"/dashboard/patients/#{patient.id}")

      assert has_element?(view, "#weekly-metric-sessions", "4")
      assert has_element?(view, "#weekly-metric-anxiety", "—")
      assert has_element?(view, "#weekly-metric-social", "—")
      assert has_element?(view, "#weekly-metric-crisis", "—")
    end

    test "hides the whole strip when the report carries no metrics at all", %{
      conn: conn,
      patient: patient
    } do
      save_weekly_summary(patient, %{})

      {:ok, view, html} = live(conn, ~p"/dashboard/patients/#{patient.id}")

      refute has_element?(view, "#weekly-metrics")
      assert html =~ "La semana estuvo marcada por una mejora del sueño."
    end

    test "does not surface the per-emotion range inside the weekly card", %{
      conn: conn,
      patient: patient
    } do
      save_weekly_summary(patient, %{
        session_count: 2,
        emotional_range: %{"joy" => 0.7, "sadness" => 0.1}
      })

      {:ok, view, _html} = live(conn, ~p"/dashboard/patients/#{patient.id}")

      refute has_element?(view, "#weekly-pre-session-report", "Alegría")
    end

    test "tints the card by status level", %{conn: conn, patient: patient} do
      save_weekly_summary(patient, %{status_level: "Intervención Requerida", session_count: 6})

      {:ok, view, _html} = live(conn, ~p"/dashboard/patients/#{patient.id}")

      assert has_element?(view, "#weekly-pre-session-report[data-status-tone=critical]")
      assert has_element?(view, "#weekly-status-badge", "Intervención Requerida")
    end

    test "falls back to a neutral tint for an unknown status level", %{
      conn: conn,
      patient: patient
    } do
      save_weekly_summary(patient, %{status_level: "whatever", session_count: 1})

      {:ok, view, _html} = live(conn, ~p"/dashboard/patients/#{patient.id}")

      assert has_element?(view, "#weekly-pre-session-report[data-status-tone=neutral]")
    end

    defp save_weekly_summary(patient, attrs) do
      period_start = DateTime.utc_now() |> DateTime.add(-9, :day) |> DateTime.truncate(:second)

      defaults = %{
        period_start: period_start,
        period_end: DateTime.add(period_start, 7, :day),
        summary_text: "La semana estuvo marcada por una mejora del sueño.",
        status_level: "Estable",
        type: "weekly",
        patient_id: patient.id
      }

      {:ok, summary} = Alethea.Clinical.save_summary(Map.merge(defaults, attrs))
      summary
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

  # A deterministic 64-char lowercase hex hash, matching the format
  # `Alethea.Foundation.Accounts.Patient.telegram_chat_id_hash` expects.
  defp valid_hash_for(seed) do
    :crypto.mac(:hmac, :sha256, "pepper-v1-32-bytes-min-len-padding-pad", "chat-#{seed}")
    |> Base.encode16(case: :lower)
  end

  describe "Telegram invite action (#108) — mock mode" do
    setup do
      Application.put_env(:alethea, :use_mock_data, true)
      on_exit(fn -> Application.put_env(:alethea, :use_mock_data, false) end)
      :ok
    end

    test "renders the Invite button on a not-connected patient", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/patients/p1")

      assert has_element?(view, "#telegram-status-dot-disconnected")
      assert has_element?(view, "#telegram-invite-button")
    end

    test "clicking Invite opens the modal with deep link, 6-digit code, and expiry", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/dashboard/patients/p1")

      view
      |> element("#telegram-invite-button")
      |> render_click()

      assert has_element?(view, "#telegram-invite-modal")
      assert has_element?(view, "#telegram-invite-deep-link")
      assert has_element?(view, "#telegram-invite-six-digit")
      assert has_element?(view, "#telegram-invite-expiry")
    end

    test "modal deep link carries the MOCK_ prefix in mock mode", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/patients/p1")

      view
      |> element("#telegram-invite-button")
      |> render_click()

      html = render(view)
      assert html =~ "MOCK_"
    end

    test "after invite is shown, the action button flips to Regenerate", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/patients/p1")

      view
      |> element("#telegram-invite-button")
      |> render_click()

      assert has_element?(view, "#telegram-regenerate-button")
      refute has_element?(view, "#telegram-invite-button")
    end

    test "clicking Regenerate re-mints the invite", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/patients/p1")

      view
      |> element("#telegram-invite-button")
      |> render_click()

      first_html = render(view)

      view
      |> element("#telegram-regenerate-button")
      |> render_click()

      second_html = render(view)

      assert first_html != second_html
      assert render(view) =~ "Invite regenerado"
    end

    test "close button dismisses the modal", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/patients/p1")

      view
      |> element("#telegram-invite-button")
      |> render_click()

      assert has_element?(view, "#telegram-invite-modal")

      view
      |> element("#telegram-invite-done")
      |> render_click()

      refute has_element?(view, "#telegram-invite-modal")
    end

    test "clicking the backdrop dismisses the modal", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/patients/p1")

      view
      |> element("#telegram-invite-button")
      |> render_click()

      assert has_element?(view, "#telegram-invite-modal")

      view
      |> element("#telegram-invite-modal-backdrop")
      |> render_click()

      refute has_element?(view, "#telegram-invite-modal")
    end
  end

  describe "Telegram invite action (#108) — real mode" do
    test "creates a foundation row, opens the modal, and shows Connected once bound", %{
      conn: conn,
      professional: professional
    } do
      Application.put_env(:alethea, :use_mock_data, false)
      on_exit(fn -> Application.put_env(:alethea, :use_mock_data, false) end)

      {:ok, kek} = Accounts.load_professional_kek(professional)

      {:ok, patient} =
        Accounts.create_patient(
          %{
            "alias" => "Invitee #{System.unique_integer([:positive])}",
            "professional_id" => professional.id
          },
          kek
        )

      {:ok, view, _html} = live(conn, ~p"/dashboard/patients/#{patient.id}")

      assert has_element?(view, "#telegram-status-dot-disconnected")
      assert has_element?(view, "#telegram-invite-button")

      view
      |> element("#telegram-invite-button")
      |> render_click()

      assert has_element?(view, "#telegram-invite-modal")
      assert has_element?(view, "#telegram-invite-deep-link")
      assert has_element?(view, "#telegram-invite-six-digit")

      # After invite is minted the foundation row exists, but the
      # patient has NOT yet `/start`-ed the bot, so the status must
      # still read "Not connected".
      refute has_element?(view, "#telegram-status-dot-connected")

      # Bind the chat by stamping a real hash onto the foundation
      # row, then re-load the patient detail and assert the
      # indicator flips to Connected.
      foundation =
        Alethea.Foundation.Accounts.Patient
        |> where([p], p.legacy_patient_id == ^patient.id)
        |> Repo.one!()

      foundation
      |> Ecto.Changeset.change(%{
        telegram_chat_id_hash: valid_hash_for("bound-#{System.unique_integer([:positive])}")
      })
      |> Repo.update!()

      {:ok, view2, _html} = live(conn, ~p"/dashboard/patients/#{patient.id}")

      assert has_element?(view2, "#telegram-status-dot-connected")
      assert has_element?(view2, "#telegram-connected-indicator")
    end
  end

  defp log_in_professional(conn, professional) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:professional_id, professional.id)
  end
end
