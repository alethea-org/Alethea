defmodule Alethea.Clinical.MockData do
  @moduledoc """
  Generador de datos ficticios para el Dashboard en entornos de desarrollo.
  """
  alias Alethea.Accounts.Patient
  alias Alethea.Clinical.{Trend, Summary, Message}

  def list_mock_patients(professional_id) do
    [
      %Patient{
        id: "p1",
        alias: "Juan Perez",
        urgent_intervention: true,
        session_day_of_week: 1,
        session_time: ~T[10:00:00],
        professional_id: professional_id
      },
      %Patient{
        id: "p2",
        alias: "Maria Garcia",
        urgent_intervention: false,
        session_day_of_week: 3,
        session_time: ~T[15:30:00],
        professional_id: professional_id
      },
      %Patient{
        id: "p3",
        alias: "Carlos Rodriguez",
        urgent_intervention: true,
        session_day_of_week: 5,
        session_time: ~T[09:00:00],
        professional_id: professional_id
      }
    ]
  end

  def list_mock_trends(_patient_id) do
    [
      %Trend{indicator_name: "joy", score: 0.4, delta: 0.1},
      %Trend{indicator_name: "sadness", score: 0.2, delta: -0.05},
      %Trend{indicator_name: "anger", score: 0.1, delta: 0.0},
      %Trend{indicator_name: "fear", score: 0.15, delta: 0.05},
      %Trend{indicator_name: "neutral", score: 0.8, delta: -0.1}
    ]
  end

  def list_mock_summaries(patient_id, "weekly") do
    [
      %Summary{
        id: Ecto.UUID.generate(),
        patient_id: patient_id,
        type: "weekly",
        summary_text:
          "Esta semana el paciente ha mostrado una mejora significativa en su estado de ánimo, aunque persiste cierta ansiedad relacionada con el trabajo.",
        status_level: "Estable",
        period_start: DateTime.utc_now() |> DateTime.add(-7, :day),
        period_end: DateTime.utc_now()
      }
    ]
  end

  def list_mock_summaries(patient_id, "session") do
    [
      %Summary{
        id: Ecto.UUID.generate(),
        patient_id: patient_id,
        type: "session",
        summary_text:
          "Sesión enfocada en técnicas de respiración. El paciente reporta mejor descanso.",
        status_level: "Estable",
        period_start: DateTime.utc_now() |> DateTime.add(-1, :day),
        period_end: DateTime.utc_now() |> DateTime.add(-1, :day)
      },
      %Summary{
        id: Ecto.UUID.generate(),
        patient_id: patient_id,
        type: "session",
        summary_text: "Crisis de pánico reportada el martes. Se ajustaron metas semanales.",
        status_level: "Alerta",
        period_start: DateTime.utc_now() |> DateTime.add(-4, :day),
        period_end: DateTime.utc_now() |> DateTime.add(-4, :day)
      }
    ]
  end

  def list_mock_daily_emotions(_patient_id) do
    today = Date.utc_today()

    rows = [
      {0.4, 0.2, 0.1, 0.15, 0.8},
      {0.3, 0.4, 0.05, 0.1, 0.6},
      {0.5, 0.15, 0.2, 0.25, 0.7},
      {0.2, 0.5, 0.15, 0.3, 0.5},
      {0.45, 0.2, 0.1, 0.12, 0.75},
      {0.6, 0.1, 0.05, 0.08, 0.85},
      {0.35, 0.3, 0.12, 0.18, 0.65}
    ]

    rows
    |> Enum.with_index()
    |> Enum.map(fn {{joy, sadness, anger, fear, neutral}, i} ->
      %{
        date: Date.add(today, i - 6),
        joy: joy,
        sadness: sadness,
        anger: anger,
        fear: fear,
        neutral: neutral
      }
    end)
  end

  def list_mock_messages(patient_id) do
    Enum.map(1..20, fn i ->
      %Message{
        id: Ecto.UUID.generate(),
        patient_id: patient_id,
        direction: if(rem(i, 2) == 0, do: "inbound", else: "outbound"),
        encrypted_content: "Mensaje cifrado simulado #{i}",
        timestamp: DateTime.utc_now() |> DateTime.add(-i, :hour)
      }
    end)
  end
end
