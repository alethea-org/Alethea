defmodule AletheaJobs.WeeklyReportWorkerTest do
  use Alethea.DataCase, async: false
  use Oban.Testing, repo: Alethea.Repo

  import Mox
  import Ecto.Query

  alias Alethea.{Accounts, Repo, Clinical}
  alias Alethea.Clinical.{Summary, Trend}
  alias AletheaJobs.WeeklyReportWorker

  setup :set_mox_from_context
  setup :verify_on_exit!

  setup do
    {:ok, professional} =
      Accounts.create_professional(%{
        email: "weekly_test@example.com",
        password: "securepassword123",
        full_name: "Weekly Tester"
      })

    {:ok, kek} = Accounts.load_professional_kek(professional)

    {:ok, patient} =
      Accounts.create_patient(
        %{
          "whatsapp_number" => "+541122223333",
          "alias" => "Weekly Patient",
          "professional_id" => professional.id
        },
        kek
      )

    %{patient: patient}
  end

  test "aggregates data and saves a weekly summary", %{patient: patient} do
    # 1. Crear datos de prueba (resúmenes de sesión y trends)
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    yesterday = DateTime.add(now, -1, :day)

    # Insertar un resumen de sesión con datos sensibles (email)
    {:ok, _s1} =
      Clinical.save_summary(%{
        period_start: DateTime.add(yesterday, -1, :hour),
        period_end: yesterday,
        summary_text: "Sesión sobre ansiedad. Contactar a juan@example.com.",
        status_level: "Alerta",
        type: "session",
        patient_id: patient.id
      })

    # Insertar algunos trends
    Repo.insert!(%Trend{
      indicator_name: "joy",
      score: 0.5,
      delta: 0.0,
      recorded_at: yesterday,
      patient_id: patient.id
    })

    # 2. Configurar Expectativas
    Alethea.AI.WeeklySummaryChainMock
    |> expect(:run, fn summaries, trends ->
      # Verificar que se recibió el resumen y que el email está sanitizado
      assert hd(summaries).summary_text =~ "[REDACTED_EMAIL]"
      # Verificar que se recibieron los trends agregados
      assert Enum.any?(trends, fn t -> t.label == "joy" end)

      {:ok,
       %{
         summary_text: "Reporte: El paciente está estable pero con picos de alegría.",
         status_level: "Estable",
         anxiety_score: 0.2,
         social_score: 0.7,
         emotional_range: %{"joy" => 0.5, "sadness" => 0.1, "anger" => 0.0, "fear" => 0.1, "neutral" => 0.3},
         crisis_events: 0,
         session_count: 1,
         tokens_used: 42
       }}
    end)

    # 3. Ejecutar Worker
    assert :ok = perform_job(WeeklyReportWorker, %{"patient_id" => patient.id})

    # 4. Validar Resultado
    weekly_summaries =
      Repo.all(from s in Summary, where: s.patient_id == ^patient.id and s.type == "weekly")

    assert length(weekly_summaries) == 1
    [summary] = weekly_summaries
    assert summary.summary_text =~ "está estable"
    assert summary.status_level == "Estable"
  end
end
