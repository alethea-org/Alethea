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
          "alias" => "Weekly Patient",
          "professional_id" => professional.id
        },
        kek
      )

    %{patient: patient}
  end

  test "passes the week's sanitized inbound patient messages, in order", %{patient: patient} do
    {:ok, dek} = Clinical.patient_dek(patient)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    save = fn text, direction, at ->
      {:ok, message} = Clinical.save_message(patient, text, dek, direction, "spontaneous")

      Repo.update_all(from(m in Alethea.Clinical.Message, where: m.id == ^message.id),
        set: [timestamp: at]
      )
    end

    save.("Mensaje viejo de hace ocho días", "inbound", DateTime.add(now, -8, :day))

    save.(
      "Ayer desaprobé un examen. Escribime a juan@example.com",
      "inbound",
      DateTime.add(now, -1, :day)
    )

    save.("Respuesta del bot", "outbound", DateTime.add(now, -1, :day))
    save.("Hoy me siento un poco mejor", "inbound", DateTime.add(now, -1, :hour))

    Alethea.AI.WeeklySummaryChainMock
    |> expect(:run, fn %{summaries: [], messages: messages} ->
      assert messages == [
               "Ayer desaprobé un examen. Escribime a [REDACTED_EMAIL]",
               "Hoy me siento un poco mejor"
             ]

      {:ok,
       %{
         summary_text: "Semana con un examen desaprobado.",
         status_level: "Alerta",
         anxiety_score: nil,
         social_score: nil,
         emotional_range: nil,
         crisis_events: 0,
         session_count: 0
       }}
    end)

    assert :ok = perform_job(WeeklyReportWorker, %{"patient_id" => patient.id})
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
    |> expect(:run, fn %{summaries: summaries, trends: trends} ->
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
         emotional_range: %{
           "joy" => 0.5,
           "sadness" => 0.1,
           "anger" => 0.0,
           "fear" => 0.1,
           "neutral" => 0.3
         },
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

  test "no guarda ningún resumen cuando la cadena rechaza un eco del esquema (#360)", %{
    patient: patient
  } do
    # 1. Datos de entrada presentes (el eco ocurre con sesiones reales de fondo)
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    yesterday = DateTime.add(now, -1, :day)

    {:ok, _s1} =
      Clinical.save_summary(%{
        period_start: DateTime.add(yesterday, -1, :hour),
        period_end: yesterday,
        summary_text: "Sesión sobre ansiedad con mejora sostenida.",
        status_level: "Alerta",
        type: "session",
        patient_id: patient.id
      })

    # 2. La cadena rechaza la respuesta del modelo: eco del JSON schema
    Alethea.AI.WeeklySummaryChainMock
    |> expect(:run, fn %{summaries: _summaries, trends: _trends} -> {:error, :schema_echo} end)

    # 3. El worker propaga el error (Oban reintentará)…
    assert {:error, :schema_echo} =
             perform_job(WeeklyReportWorker, %{"patient_id" => patient.id})

    # 4. …y no persiste ninguna fila semanal: ni el esquema como narrativa
    #    clínica ni un estado inferido por escaneo de palabras clave.
    weekly_summaries =
      Repo.all(from s in Summary, where: s.patient_id == ^patient.id and s.type == "weekly")

    assert weekly_summaries == []
  end
end
