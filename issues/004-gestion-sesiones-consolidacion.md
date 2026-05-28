# Issue 004: Gestión de Sesiones y Consolidación (Heavy Processing)

**Type**: AFK
**Blocked by**: None (Clinical Schema & RoBERTa Contracts / Contract-Driven Development)
**User Stories Covered**: 6, 3

## 🤝 Contrato de Paralelización (Contract-Driven Development)

Para desacoplar esta issue de la Issue 003 y habilitar de forma paralela y síncrona el desarrollo del Dashboard Clínico (Issue 006), definimos las estructuras de datos clínicas (Structs/Schemas) y el comportamiento del procesador de emociones de forma contractual.

### Contrato de Modelos: Structs Clínicos
Los esquemas de bases de datos y structs de Elixir se acuerdan de antemano con la siguiente estructura exacta:

#### `Alethea.Clinical.Session`
```elixir
defmodule Alethea.Clinical.Session do
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "clinical_sessions" do
    field :started_at, :utc_datetime
    field :closed_at, :utc_datetime
    field :status, :string, default: "open" # "open" / "closed"
    belongs_to :patient, Alethea.Accounts.Patient, type: :binary_id
    has_many :messages, Alethea.Clinical.Message
    timestamps()
  end
end
```

#### `Alethea.Clinical.Summary`
```elixir
defmodule Alethea.Clinical.Summary do
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "clinical_summaries" do
    field :summary_text, :string
    field :period_start, :utc_datetime
    field :period_end, :utc_datetime
    field :status_level, :string # "Estable", "Alerta", "Intervención Requerida"
    field :type, :string, default: "session" # "session" / "weekly" (añadido en esta issue)
    belongs_to :patient, Alethea.Accounts.Patient
    timestamps(type: :utc_datetime)
  end
end
```

#### `Alethea.Clinical.Trend`
```elixir
defmodule Alethea.Clinical.Trend do
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "clinical_trends" do
    field :indicator_name, :string # "joy", "sadness", "anger", "fear", "neutral"
    field :score, :float
    field :delta, :float, default: 0.0
    field :recorded_at, :utc_datetime
    belongs_to :patient, Alethea.Accounts.Patient
    timestamps(type: :utc_datetime)
  end
end
```

### Contrato de Inferencia Emocional: `Alethea.AI.RoBERTaWorkerBehavior`
```elixir
defmodule Alethea.AI.RoBERTaWorkerBehavior do
  @callback analyze_batch(list(String.t())) :: list(map())
end
```
Esto permite al desarrollador del backend de procesamiento de fondo escribir y verificar los workers de inactividad de Oban (`SessionTimeoutWorker` y `WeeklyReportWorker`) utilizando Mox, simulando distribuciones de emociones predefinidas (ej. `[%{label: "sadness", score: 0.75}, %{label: "neutral", score: 0.25}]`) y reportes simulados.

Al mismo tiempo, la definición formal de los campos de estos Structs **desbloquea inmediatamente la Issue 006 (Dashboard Clínico)**, permitiendo que el desarrollador del front-end monte todas las vistas y gráficos de tendencias usando datos de prueba simulados, sin esperar a que el pipeline de procesamiento asíncrono o la descarga física de Bumblebee estén listos.

## Description

Gestionar el ciclo de vida de la interacción diaria. El sistema detecta inactividad, dispara procesamiento pesado asíncrono (análisis de emoción + snapshot clínico) y genera un reporte semanal personalizado por horario de sesión del paciente, para que el dashboard del psicólogo sea instantáneo.

## Decisiones de Diseño

| Decisión | Elección | Justificación |
|---|---|---|
| Migraciones | Una sola migración agrupa todos los cambios de schema | Cambios interdependientes; historial limpio |
| `SessionManager` | Módulo de contexto puro (sin OTP) — estado de sesión en DB | El timer está en Oban; no se necesita proceso en memoria |
| Timer de inactividad | `SessionTimeoutWorker` con `unique: [fields: [:args], period: 40*60, on_conflict: :replace]` y `scheduled_at: now + 30min` | Cada mensaje nuevo reemplaza el job, reiniciando el timer sin duplicados |
| Modelo de emoción | `pysentimiento/robertuito-emotion-analysis` vía Bumblebee local (`Nx.Serving`) | Español, 7 emociones, jerga informal; privacidad total, latencia 0 |
| Embeddings | Columna `vector(384)` creada en migración; **generación diferida** a issue futura | No hay feature que los consuma en issues 005/006 |
| Scope de análisis emocional | Todos los mensajes `inbound` de la sesión — promedio de scores por emoción | Perfil emocional representativo de toda la sesión |
| Trends | Un `Trend` por emoción (hasta 5 registros por sesión, filtrando surprise y disgust); `delta` vs. último trend de esa emoción | Granularidad clínica; el dashboard puede graficar evolución por emoción (set canónico de 5) |
| Snapshot de sesión | Mismo LLM/endpoint que issue 003 (`ChatOpenAI` configurable) con prompt de resumen diferente | Sin nueva dependencia; reutiliza la configuración existente |
| Agenda del reporte semanal | `session_day_of_week` (integer 1-7) + `session_time` (time) añadidos a `patients` en esta migración | El profesional configura el horario real del paciente; el cron encola dinámicamente |
| Trigger del `WeeklyReportWorker` | Cron diario de barrido (`DailySchedulerWorker`) a las 00:00 UTC que encola `WeeklyReportWorker` con `scheduled_at = mañana session_time - 2h` | Distribuye la carga durante la semana; el reporte llega antes de la sesión real |
| Tests | Unitarios con Mox para workers; mock de `Nx.Serving` para RoBERTa | Sin modelo ni API reales en CI |

## Flujo al Cerrar una Sesión

```
SessionTimeoutWorker.perform/1 (o cierre explícito)
  ├── 1. SessionManager.close_session(session) → actualiza status: "closed", closed_at: now
  ├── 2. Cargar todos los Messages inbound de la sesión → descifrar con DEK del paciente
  ├── 3. RoBERTaWorker.analyze_batch(messages) → [{emoción, score}] promediados por emoción
  ├── 4. Clinical.save_trends(patient, emotion_scores, session) → hasta 5 Trend records (filtrado)
  ├── 5. SummaryChain.run(messages, emotion_scores) → texto de 4 líneas
  ├── 6. Clinical.save_summary(patient, session, summary_text, type: "session")
  └── 7. WhatsApp.Client.send_message(phone, mensaje_despedida)
```

```
DailySchedulerWorker (cron 00:00 UTC)
  └── Para cada paciente cuyo session_day_of_week == mañana:
        └── Oban.insert(WeeklyReportWorker, %{patient_id: id},
              scheduled_at: tomorrow_at(session_time) - 2h)

WeeklyReportWorker.perform/1
  ├── 1. Recuperar summaries type "session" de los últimos 7 días del paciente
  ├── 2. Recuperar trends del período → agregar scores por emoción → emociones predominantes
  ├── 3. WeeklySummaryChain.run(summaries, aggregated_trends) → reporte ≤ 8 líneas
  └── 4. Clinical.save_summary(patient, period, reporte, type: "weekly")
```

## Tasks

### Migración
- [x] Generar migración `add_sessions_and_embeddings`

### Schemas
- [x] Crear `lib/alethea/clinical/session.ex`
- [x] Actualizar `Alethea.Clinical.Message` (session_id, embedding)
- [x] Actualizar `Alethea.Clinical.Summary` (tipo session/weekly)
- [x] Actualizar `Alethea.Accounts.Patient` (horarios de sesión)

### IA — Análisis de Emoción
- [x] Crear `lib/alethea/ai/roberta_worker.ex` (Bumblebee/HF)
- [x] Añadir al supervision tree en `lib/alethea/application.ex`

### Dominio — `SessionManager` y contexto `Clinical`
- [x] Crear `lib/alethea/clinical/session_manager.ex`
- [x] Añadir `save_trends`, `save_summary`, etc., a `Alethea.Clinical`

### IA — Chains de Resumen
- [x] Crear `lib/alethea/ai/chains/session_summary_chain.ex`
- [x] Crear `lib/alethea/ai/chains/weekly_summary_chain.ex`

### Workers Oban
- [x] Crear `lib/alethea_jobs/session_timeout_worker.ex`
- [x] Actualizar `AletheaJobs.ProcessMessageWorker` para usar sesiones.
- [x] Crear `lib/alethea_jobs/daily_scheduler_worker.ex`
- [x] Crear `lib/alethea_jobs/weekly_report_worker.ex`
- [x] Configurar colas y cron en `config/config.exs`

### Tests
- [x] `test/alethea_jobs/session_timeout_worker_test.exs`
- [x] `test/alethea_jobs/daily_scheduler_worker_test.exs`
- [x] `test/alethea_jobs/weekly_report_worker_test.exs`
- [x] Ejecutar `mix test` y verificar.

## Archivos Involucrados

| Acción | Archivo |
|---|---|
| NEW (migración) | `priv/repo/migrations/<ts>_add_sessions_and_embeddings.exs` |
| NEW | `lib/alethea/clinical/session.ex` |
| MODIFY | `lib/alethea/clinical/message.ex` |
| MODIFY | `lib/alethea/clinical/summary.ex` |
| MODIFY | `lib/alethea/accounts/patient.ex` |
| NEW | `lib/alethea/ai/roberta_worker.ex` |
| MODIFY | `lib/alethea/application.ex` (añadir RoBERTaWorker al supervision tree) |
| NEW | `lib/alethea/clinical/session_manager.ex` |
| MODIFY | `lib/alethea/clinical.ex` |
| NEW | `lib/alethea/ai/chains/session_summary_chain.ex` |
| NEW | `lib/alethea/ai/chains/weekly_summary_chain.ex` |
| NEW | `lib/alethea_jobs/session_timeout_worker.ex` |
| MODIFY | `lib/alethea_jobs/process_message_worker.ex` |
| NEW | `lib/alethea_jobs/daily_scheduler_worker.ex` |
| NEW | `lib/alethea_jobs/weekly_report_worker.ex` |
| MODIFY | `config/config.exs` (colas Oban + cron + System Prompts de resumen) |
| NEW | `test/alethea_jobs/session_timeout_worker_test.exs` |
| NEW | `test/alethea/ai/roberta_worker_test.exs` |
| NEW | `test/alethea_jobs/daily_scheduler_worker_test.exs` |

## Notas

- **Descarga del modelo RoBERTa**: `pysentimiento/robertuito-emotion-analysis` (~500MB) se descarga en el primer arranque. En producción, pre-descargar en la imagen Docker durante el build con `mix run --no-start -e "Bumblebee.load_model({:hf, \"pysentimiento/robertuito-emotion-analysis\"})"`.
- **`session_day_of_week` nulo**: pacientes sin horario configurado no reciben `WeeklyReportWorker`. El profesional puede configurar el campo desde el detalle del paciente (issue 006).
- **`delta` en Trends**: si no existe un trend previo de esa emoción para el paciente, `delta` = 0.0. Si existe, `delta = score_actual - score_anterior`.
- **Pgvector**: la columna `embedding vector(384)` requiere que la extensión `pgvector` esté habilitada en PostgreSQL (`CREATE EXTENSION IF NOT EXISTS vector`). Añadir esto a la migración o a un migration previo.
- **Embeddings diferidos**: la columna se crea nullable; ningún código la llena en esta issue. La generación de embeddings se documenta como deuda técnica en una issue separada.
- **Issue 006**: actualizar el issue 006 para que la vista de detalle del paciente tenga un campo de edición de `session_day_of_week` y `session_time`.
