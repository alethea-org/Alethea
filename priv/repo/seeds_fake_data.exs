# Script for populating the database with fake data for development.
# Run with: mix run priv/repo/seeds_fake_data.exs

import Ecto.Query
alias Alethea.Repo
alias Alethea.Accounts
alias Alethea.Clinical.{Trend, Summary, Message}

# Get the only patient (Lucca Giordana)
professional = Accounts.list_professionals() |> List.first()
patients = Accounts.list_patients(professional.id)

if Enum.empty?(patients) do
  IO.puts("No patients found. Create a patient first.")
else
  patient = List.first(patients)
  IO.puts("Seeding fake data for: #{patient.alias} (ID: #{patient.id})")

  # ── 1. Clinical Trends (last 7 days) ─────────────────────────────
  IO.puts("  Creating clinical trends...")

  emotions = ["joy", "sadness", "anger", "fear", "neutral"]

  # Delete existing trends for this patient
  Repo.delete_all(from(t in Trend, where: t.patient_id == ^patient.id))

  # Create trends for each of the last 7 days
  Enum.each(0..6, fn days_ago ->
    base_scores = %{
      "joy" => 0.5 + :rand.uniform() * 0.3,
      "sadness" => 0.2 + :rand.uniform() * 0.2,
      "anger" => 0.1 + :rand.uniform() * 0.15,
      "fear" => 0.15 + :rand.uniform() * 0.2,
      "neutral" => 0.4 + :rand.uniform() * 0.3
    }

    recorded_date =
      NaiveDateTime.utc_now()
      |> NaiveDateTime.add(-days_ago * 86400)
      |> NaiveDateTime.truncate(:second)

    Enum.each(emotions, fn emotion ->
      score = Map.get(base_scores, emotion) + :rand.uniform() * 0.1 - 0.05
      score = max(0.0, min(1.0, score))

      %Trend{}
      |> Trend.changeset(%{
        indicator_name: emotion,
        score: score,
        delta: :rand.uniform() * 0.2 - 0.1,
        recorded_at: recorded_date,
        patient_id: patient.id
      })
      |> Repo.insert!()
    end)
  end)

  IO.puts("    ✓ Created 35 trends (5 emotions × 7 days)")

  # ── 2. Clinical Summaries ─────────────────────────────────────────
  IO.puts("  Creating clinical summaries...")

  Repo.delete_all(from(s in Summary, where: s.patient_id == ^patient.id))

  # Weekly summary
  %Summary{}
  |> Summary.changeset(%{
    type: "weekly",
    summary_text:
      "Lucca ha mostrado una tendencia positiva esta semana. La comunicación sigue siendo abierta y colaborativa. Se observan mejoras en la gestión del estrés, aunque persisten algunos episodios de ansiedad moderada los días de alta demanda laboral.",
    status_level: "Estable",
    period_start:
      NaiveDateTime.utc_now() |> NaiveDateTime.add(-7 * 86400) |> NaiveDateTime.truncate(:second),
    period_end: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second),
    patient_id: patient.id,
    anxiety_score: 0.62,
    social_score: 0.41,
    emotional_range: %{
      "joy" => 0.34,
      "sadness" => 0.21,
      "anger" => 0.08,
      "fear" => 0.17,
      "neutral" => 0.52
    },
    crisis_events: 1,
    session_count: 5
  })
  |> Repo.insert!()

  # Session summaries
  session_summaries = [
    {
      ~N[2025-05-28T14:00:00],
      "Sesión centrada en técnicas de respiración diafragmática. Lucca reporta haber practicado en casa con buenos resultados. Reducción notable de la tensión muscular.",
      "Estable"
    },
    {
      ~N[2025-05-24T10:30:00],
      "Revisión de metas mensuales. Lucca expresa sentirse más tranquilo con su situación actual. Se ajusta frecuencia de ejercicios de mindfulness.",
      "Estable"
    },
    {
      ~N[2025-05-20T16:00:00],
      "Episodio de ansiedad moderada durante la sesión. Se implementaron técnicas de grounding. Lucca responde bien a intervenciones estructuradas.",
      "Alerta"
    },
    {
      ~N[2025-05-15T11:00:00],
      "Seguimiento post-crisis. Se revisaron estrategias de contención. El paciente reporta sentirse más seguro con su red de apoyo.",
      "Alerta"
    },
    {
      ~N[2025-05-10T09:30:00],
      "Sesión inicial de evaluación. Lucca llega con buena disposición. Establecemos acuerdos terapéuticos y objetivos a corto plazo.",
      "Estable"
    }
  ]

  Enum.each(session_summaries, fn {period_end, text, status} ->
    %Summary{}
    |> Summary.changeset(%{
      type: "session",
      summary_text: text,
      status_level: status,
      period_start: period_end,
      period_end: period_end,
      patient_id: patient.id
    })
    |> Repo.insert!()
  end)

  IO.puts("    ✓ Created 1 weekly + 5 session summaries")

  # ── 3. Messages ───────────────────────────────────────────────────
  IO.puts("  Creating message history...")

  Repo.delete_all(from(m in Message, where: m.patient_id == ^patient.id))

  message_templates = [
    {"inbound", "Hola, ¿cómo estás?"},
    {"outbound", "Hola Lucca, ¿cómo te encuentras hoy?"},
    {"inbound", "Bien, un poco cansado pero ok"},
    {"outbound", "Entiendo. ¿Pudiste hacer los ejercicios de anoche?"},
    {"inbound", "Sí, me ayudaron a relajarme antes de dormir"},
    {"outbound", "Excelente. ¿Quieres que repitamos la técnica mañana?"},
    {"inbound", "Sí, creo que me está funcionando"},
    {"outbound", "Perfecto. Recuerda que si sientes ansiedad, puedes usar el método 5-4-3-2-1"},
    {"inbound", "Sí, lo recuerdo. Es muy útil"},
    {"outbound", "Excelente. ¿Hay algo que quieras discutir en la próxima sesión?"},
    {"inbound", "Sí, quiero hablar sobre cómo manejar mejor el estrés en el trabajo"},
    {"outbound",
     "Estaré preparado para abordar ese tema. Mientras tanto, lleva un registro de los momentos de estrés."},
    {"inbound", "Ok, lo haré. Gracias"},
    {"outbound", "De nada. Cualquier cosa me escribes."},
    {"inbound", "Hola, tengo una consulta"},
    {"outbound", "Claro, dime qué necesitas"},
    {"inbound", "¿Es normal sentirme ansioso antes de las reuniones importantes?"},
    {"outbound",
     "Es completamente normal. La ansiedad antes de eventos importantes es una respuesta natural. Podemos trabajar en técnicas para manejarla."},
    {"inbound", "Gracias, me ayuda saber eso"},
    {"outbound", "¿Quieres practicar juntos alguna técnica antes de tu próxima reunión?"},
    {"inbound", "Sí, me gustaría"},
    {"outbound", "Perfecto. Te enviaré ejercicios para preparar antes de la próxima semana."},
    {"inbound", "Gracias Vicenzo, te agradezco mucho tu ayuda"},
    {"outbound", "Para eso estoy. Hasta la próxima sesión."},
    {"inbound", "Hasta luego 👋"},
    {"outbound", "Cuídate Lucca 💪"},
    {"inbound", "Hola, tengo una pregunta sobre la meditación"},
    {"outbound", "Claro, ¿qué te gustaría saber?"},
    {"inbound", "¿Cuánto tiempo debería meditar cada día?"},
    {"outbound",
     "Recomendamos empezar con 5-10 minutos e ir aumentando gradualmente. Lo importante es la consistencia."},
    {"inbound", "Entendido, voy a intentar hacer 10 minutos cada mañana"},
    {"outbound", "Es una excelente rutina. ¿Quieres que te mande una guía de meditación guiada?"},
    {"inbound", "Sí, por favor. Me ayudaría mucho"},
    {"outbound", "Perfecto. Te la envío en la tarde."},
    {"inbound", "Ok, gracias. ¿Cómo estuvo tu día?"},
    {"outbound",
     "Muy bien, gracias por preguntar. Hoy tengo varias sesiones pero todas van bien."},
    {"inbound", "Me alegra escuchar eso 😊"},
    {"outbound", "Cuídate Lucca, nos vemos mañana"}
  ]

  Enum.with_index(message_templates, fn {direction, content}, idx ->
    # Create fake encrypted_content (base64 of the text for demo purposes)
    encrypted = Base.encode64(content)

    hours_ago = 48 - idx * 2

    timestamp =
      NaiveDateTime.utc_now()
      |> NaiveDateTime.add(-hours_ago * 3600)
      |> NaiveDateTime.truncate(:second)

    %Message{}
    |> Message.changeset(%{
      direction: direction,
      behavior_type: "spontaneous",
      encrypted_content: encrypted,
      timestamp: timestamp,
      patient_id: patient.id
    })
    |> Repo.insert!()
  end)

  IO.puts("    ✓ Created #{length(message_templates)} messages")

  IO.puts("")
  IO.puts("✅ Fake data seeded successfully for Lucca Giordana!")
  IO.puts("")
  IO.puts("Now visit: http://localhost:4000/dashboard")
end
