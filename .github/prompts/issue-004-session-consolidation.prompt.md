---
description: "Issue 004 — Gestión de sesiones diarias y consolidación asíncrona (Snapshot, embeddings, sentimiento)"
---

# Issue 004: Gestión de Sesiones y Consolidación

Implementa el ciclo de vida de la sesión diaria del paciente con procesamiento
asíncrono de IA al cierre: sentimiento (RoBERTa local), embeddings (pgvector) y
Snapshot clínico de 4 líneas (LangChain).

## Contexto

- **Bloqueado por**: Issue 003
- **User Stories**: 6 (cierre tras 30 min de inactividad) y 3 (Snapshot pre-sesión)
- **Módulos clave**: `Alethea.Clinical.SessionManager`, workers Oban

## Tareas a Implementar

### 1. `Alethea.Clinical.SessionManager`

Gestiona el estado de sesión via GenServer + Oban scheduling:

```elixir
defmodule Alethea.Clinical.SessionManager do
  @moduledoc """
  Gestiona el ciclo de vida de sesiones diarias de pacientes.
  Al detectar inactividad de 30 min, dispara el pipeline de consolidación.
  """

  @timeout_minutes 30

  def register_activity(patient_id) do
    # Cancela el job de timeout anterior (si existe) y programa uno nuevo
    cancel_pending_timeout(patient_id)
    schedule_session_timeout(patient_id)
  end

  defp schedule_session_timeout(patient_id) do
    scheduled_at = DateTime.add(DateTime.utc_now(), @timeout_minutes * 60, :second)

    %{"patient_id" => patient_id}
    |> Alethea.Jobs.SessionTimeoutWorker.new(scheduled_at: scheduled_at)
    |> Oban.insert()
  end
end
```

### 2. `SessionTimeoutWorker` — Pipeline de Consolidación

```elixir
defmodule Alethea.Jobs.SessionTimeoutWorker do
  use Oban.Worker, queue: :ai_processing, max_attempts: 3

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"patient_id" => patient_id}}) do
    session_messages = Alethea.Clinical.get_session_messages(patient_id)

    with {:ok, sentiment}   <- analyze_sentiment_batch(session_messages),
         {:ok, embeddings}  <- generate_embeddings(session_messages),
         {:ok, _snapshot}   <- generate_snapshot(patient_id, session_messages, sentiment),
         :ok                <- save_embeddings(embeddings, patient_id),
         :ok                <- send_farewell_message(patient_id) do
      :ok
    end
  end

  defp analyze_sentiment_batch(messages) do
    # RoBERTa via Bumblebee — LOCAL, sin llamadas externas
    Alethea.AI.RobertaWorker.analyze_batch(Enum.map(messages, & &1.content))
  end

  defp generate_snapshot(patient_id, messages, sentiment) do
    # LangChain / Phi-4 — genera resumen de 4 líneas
    Alethea.AI.Chains.SnapshotChain.run(%{
      patient_id: patient_id,
      messages: messages,
      sentiment_summary: sentiment
    })
  end

  defp send_farewell_message(patient_id) do
    patient = Alethea.Accounts.get_patient!(patient_id)
    Alethea.WhatsApp.Client.send_text_message(
      patient.whatsapp_number,
      "Tu sesión de hoy ha sido guardada de forma segura. Hasta la próxima. 🌿"
    )
  end
end
```

### 3. `SnapshotChain` en LangChain

Crea `lib/alethea/ai/chains/snapshot_chain.ex` con System Prompt que genera
exactamente 4 líneas: trigger emocional, emoción predominante, patrón detectado,
recomendación para el terapeuta.

### 4. Schema para Snapshots

```bash
mix ecto.gen.migration create_clinical_snapshots
```

```elixir
create table(:clinical_snapshots) do
  add :patient_id,        references(:patients), null: false
  add :session_date,      :date, null: false
  add :content,           :text, null: false        # Las 4 líneas
  add :sentiment_score,   :float
  add :source_session_id, :string                   # Trazabilidad
  timestamps()
end
```

### 5. pgvector para Embeddings

Asegura que la tabla de mensajes tenga una columna `embedding vector(768)` y
que las búsquedas usen el operador `<=>`.

## Tests

- Test de `SessionManager` simulando inactividad via `Oban.Testing`
- Test de `SessionTimeoutWorker` mockeando RoBERTa, LangChain y WhatsApp
- Test de `SnapshotChain` verificando que el resultado tiene exactamente 4 líneas
- Test de que el mensaje de despedida se envía al cierre

## Checklist

- [ ] `SessionManager.register_activity/1` re-programa el timeout en cada mensaje
- [ ] `SessionTimeoutWorker` ejecuta: sentimiento → embeddings → snapshot → despedida
- [ ] RoBERTa se ejecuta localmente (Bumblebee), sin llamadas HTTP externas
- [ ] `SnapshotChain` genera resumen de 4 líneas con trazabilidad `source_session_id`
- [ ] Embeddings guardados en pgvector con referencia al mensaje original
- [ ] Mensaje de despedida enviado al paciente al cerrar sesión
- [ ] `mix precommit` pasa limpio
