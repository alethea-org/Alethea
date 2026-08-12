defmodule AletheaWeb.DashboardLiveTest do
  use AletheaWeb.ConnCase
  use Oban.Testing, repo: Alethea.Repo
  import Phoenix.LiveViewTest

  import Ecto.Query
  import Alethea.FoundationTestHelper
  import LazyHTML

  alias Alethea.Accounts
  alias Alethea.Foundation.Accounts.Patient, as: FoundationPatient
  alias Alethea.Foundation.Accounts.PatientAuthCode
  alias Alethea.Jobs.TelegramOutboundWorker
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
      assert html =~ "Lucca"
    end

    test "receives real-time crisis alerts via PubSub", %{conn: conn} do
      Application.put_env(:alethea, :use_mock_data, true)
      on_exit(fn -> Application.put_env(:alethea, :use_mock_data, false) end)

      {:ok, view, _html} = live(conn, ~p"/dashboard")

      # Simular alerta de crisis
      send(view.pid, {:crisis_detected, %{patient_id: "p2", level: :high}})

      assert render(view) =~ "Alerta Critica: El paciente Maria Garcia ha entrado en crisis"
      # The critical patient surfaces in the editorial triage strip
      # as a `pta-chip pta-chip--risk` link to the patient's detail.
      assert has_element?(view, "a.pta-chip--risk", "Maria Garcia")
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

      assert render(view) =~ "Lucca"
      # Editorial layout renames the weekly report section to
      # "Resumen semanal" (was "Weekly Pre-Session Report" before #116).
      assert render(view) =~ "Resumen semanal"
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

  # Acceptance criteria for issue #160 — demo must look populated under
  # `use_mock_data: true` without external services.
  describe "Mock mode demo acceptance (#160)" do
    setup do
      Application.put_env(:alethea, :use_mock_data, true)
      on_exit(fn -> Application.put_env(:alethea, :use_mock_data, false) end)
      :ok
    end

    test "triage strip is empty when no patients are critical", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/dashboard")

      refute html =~ "Alertas críticas"
      refute html =~ "pta-triage"
    end

    test "triage strip surfaces a chip once a crisis PubSub event arrives", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/dashboard")

      refute html =~ "Alertas críticas"

      send(view.pid, {:crisis_detected, %{patient_id: "p2", level: :high}})

      assert has_element?(view, "a.pta-chip--risk", "Maria Garcia")
    end

    test "primary mock patient renders populated briefing under mock mode", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/dashboard/patients/p1")

      # 1. Mock professional + linked patient — header reads "Lucca".
      assert html =~ "Lucca"
      assert html =~ "Briefing · Lucca"

      # 2. Weekly summary with all four metric tiles filled (no dashes).
      assert has_element?(view, "#weekly-metric-anxiety", "62%")
      assert has_element?(view, "#weekly-metric-social", "41%")
      assert has_element?(view, "#weekly-metric-crisis", "1")
      assert has_element?(view, "#weekly-metric-sessions", "5")

      # 3. At least three session-snapshot timeline entries.
      timeline_count =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.filter(".pta-timeline__item")
        |> Enum.count()

      assert timeline_count >= 3

      # 4. At least three emotion-trend bars rendered.
      emotion_rows =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.filter("[id^=emotion-row-]")
        |> Enum.count()

      assert emotion_rows >= 3

      # 5. Daily emotion chart renders with the 7-day aria-labelled SVG.
      assert html =~ ~s|aria-label="Gráfico de emociones últimos 7 días"|

      # 6. Chat history panel populates after "Descifrar chat".
      refute html =~ "CONTENIDO DESCIFRADO (MOCK)"

      view |> element("#decrypt-chat-button") |> render_click()

      assert render(view) =~ "CONTENIDO DESCIFRADO (MOCK)"
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

      assert html =~ "Sin resumen semanal generado todavía."
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

  defp log_in_professional(conn, professional) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:professional_id, professional.id)
  end

  describe "Telegram invite (real mode)" do
    setup %{professional: professional} do
      Application.put_env(:alethea, :use_mock_data, false)
      on_exit(fn -> Application.put_env(:alethea, :use_mock_data, false) end)

      # Foundation tenant bridged to the session professional via the
      # shared email (D1); a "test"-env BotConfig row so the web layer
      # can compose the deep link (D6); a legacy patient to invite.
      foundation_pro = professional_fixture(%{email: professional.email})
      patient = legacy_patient_fixture(professional)
      bot_config_fixture()

      %{foundation_pro: foundation_pro, patient: patient, bot_username: "fixture_bot"}
    end

    test "shows a not-connected indicator and an Invite button on the briefing body", %{
      conn: conn,
      patient: patient
    } do
      {:ok, view, _html} = live(conn, ~p"/dashboard/patients/#{patient.id}")

      assert has_element?(view, "#tg-status-#{patient.id}", "Sin conectar")
      assert has_element?(view, "#tg-btn-#{patient.id}", "Invitar")
    end

    test "shows a disabled Connected button once the patient is bound", %{
      conn: conn,
      patient: patient,
      foundation_pro: foundation_pro
    } do
      {:ok, _fp} =
        FoundationPatient.create_patient(foundation_pro, %{
          alias: patient.alias,
          legacy_patient_id: patient.id,
          telegram_chat_id_hash: String.duplicate("a", 64)
        })

      {:ok, view, _html} = live(conn, ~p"/dashboard/patients/#{patient.id}")

      assert has_element?(view, "#tg-status-#{patient.id}", "Conectado")
      assert has_element?(view, "#tg-btn-#{patient.id}[disabled]", "Conectado")
      refute has_element?(view, "#tg-btn-#{patient.id}", "Regenerar")
    end

    test "R6 invites the patient and opens the modal with deep link, code and expiry", %{
      conn: conn,
      patient: patient,
      foundation_pro: foundation_pro
    } do
      {:ok, view, _html} = live(conn, ~p"/dashboard/patients/#{patient.id}")

      view |> element("#tg-btn-#{patient.id}") |> render_click()

      assert has_element?(view, "#invite-modal")

      # Deep link composed in the WEB layer from the test-env BotConfig
      # bot_username + the domain-minted token (D6)
      assert has_element?(
               view,
               ~s|#invite-deep-link[href^="https://t.me/fixture_bot?start="]|
             )

      # One bridged foundation row, alias mirrored (R1)
      fp =
        Repo.get_by(FoundationPatient,
          legacy_patient_id: patient.id,
          professional_id: foundation_pro.id
        )

      assert fp != nil
      assert fp.alias == patient.alias
      assert Repo.aggregate(FoundationPatient, :count, :id) == 1

      # The modal shows the very codes the domain minted, with a 10-min TTL
      six_digit = latest_code(fp.id, "six_digit")
      deep_link = latest_code(fp.id, "deep_link")

      assert has_element?(view, "#invite-six-digit", six_digit.code)

      assert has_element?(
               view,
               "#invite-deep-link",
               "https://t.me/fixture_bot?start=#{deep_link.code}"
             )

      ttl_seconds = DateTime.diff(six_digit.expires_at, DateTime.utc_now(), :second)
      assert ttl_seconds in 590..610

      assert has_element?(
               view,
               "#invite-expires-at",
               Calendar.strftime(six_digit.expires_at, "%H:%M")
             )

      # The app never delivers the invite (R6: no outbound send)
      refute_enqueued(worker: TelegramOutboundWorker)

      # The button adapts to Regenerate for the just-invited patient
      assert has_element?(view, "#tg-btn-#{patient.id}", "Regenerar")
    end

    test "R6 closes the modal without any side effect", %{conn: conn, patient: patient} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/patients/#{patient.id}")

      view |> element("#tg-btn-#{patient.id}") |> render_click()
      assert has_element?(view, "#invite-modal")

      view |> element("#invite-close") |> render_click()

      refute has_element?(view, "#invite-modal")
    end

    defp latest_code(patient_id, kind) do
      Repo.one(
        from(c in PatientAuthCode,
          where: c.patient_id == ^patient_id and c.kind == ^kind,
          order_by: [desc: c.inserted_at],
          limit: 1
        )
      )
    end
  end

  describe "Telegram invite without a foundation professional (real mode)" do
    setup %{professional: professional} do
      Application.put_env(:alethea, :use_mock_data, false)
      on_exit(fn -> Application.put_env(:alethea, :use_mock_data, false) end)

      patient = legacy_patient_fixture(professional)
      %{patient: patient}
    end

    test "shows an error flash and never mints codes", %{conn: conn, patient: patient} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/patients/#{patient.id}")

      view |> element("#tg-btn-#{patient.id}") |> render_click()

      assert render(view) =~ "No se pudo generar la invitación"
      refute has_element?(view, "#invite-modal")
      assert Repo.aggregate(FoundationPatient, :count, :id) == 0
      assert Repo.aggregate(PatientAuthCode, :count, :id) == 0
    end
  end

  describe "Telegram invite (mock mode)" do
    setup do
      Application.put_env(:alethea, :use_mock_data, true)
      on_exit(fn -> Application.put_env(:alethea, :use_mock_data, false) end)
      :ok
    end

    test "shows not-connected status and opens the mock invite modal without DB writes", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/dashboard/patients/p1")

      # Mock statuses are always not-connected (non-UUID ids, no bridge)
      assert has_element?(view, "#tg-status-p1", "Sin conectar")
      assert has_element?(view, "#tg-btn-p1", "Invitar")

      view |> element("#tg-btn-p1") |> render_click()

      assert has_element?(view, "#invite-modal")
      assert has_element?(view, "#invite-patient-alias", "Lucca")
      assert has_element?(view, "#invite-six-digit", "123456")
      assert has_element?(view, "#invite-expires-at")

      refute_enqueued(worker: TelegramOutboundWorker)

      # Mock mode never touches the real invite path (D5): zero foundation rows
      assert Repo.aggregate(FoundationPatient, :count, :id) == 0
      assert Repo.aggregate(PatientAuthCode, :count, :id) == 0
    end
  end
end
