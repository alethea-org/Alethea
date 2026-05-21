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
  schema "clinical_summaries" do
    field :content, :string
    field :type, :string, default: "session" # "session" / "weekly"
    belongs_to :patient, Alethea.Accounts.Patient, type: :binary_id
    belongs_to :session, Alethea.Clinical.Session, type: :binary_id, optional: true
    timestamps()
  end
end
```

#### `Alethea.Clinical.Trend`
```elixir
defmodule Alethea.Clinical.Trend do
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "clinical_trends" do
    field :indicator_name, :string # "joy", "sadness", "anger", "fear", "neutral"
    field :score, :float
    field :delta, :float, default: 0.0
    belongs_to :patient, Alethea.Accounts.Patient, type: :binary_id
    belongs_to :session, Alethea.Clinical.Session, type: :binary_id
    timestamps()
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
- [ ] Generar migración `add_sessions_and_embeddings` con:
  - **Tabla nueva `clinical_sessions`**: `id` (binary_id PK), `patient_id` (FK → patients, `on_delete: :delete_all`), `started_at` (:utc_datetime, null: false), `closed_at` (:utc_datetime, nullable), `status` (:string, default: `"open"`, null: false)
  - `alter table(:messages)`: añadir `session_id` (FK → clinical_sessions, nullable, `on_delete: :nilify_all`)
  - `alter table(:messages)`: añadir `embedding` (`:vector`, size: 384, nullable) — llenado diferido
  - `alter table(:clinical_summaries)`: añadir `type` (:string, null: false, default: `"session"`)
  - `alter table(:patients)`: añadir `session_day_of_week` (:integer, nullable) — 1=lunes … 7=domingo
  - `alter table(:patients)`: añadir `session_time` (:time, nullable)
  - Crear índice: `index(:clinical_sessions, [:patient_id, :status])`
  - Crear índice: `index(:messages, [:session_id])`

### Schemas
- [ ] Crear `lib/alethea/clinical/session.ex` (`Alethea.Clinical.Session`) con el schema de `clinical_sessions`
- [ ] Actualizar `Alethea.Clinical.Message` añadiendo `session_id`, `embedding` (tipo `Pgvector.Ecto.Vector`, correspondiente a la columna pgvector `:vector, size: 384`)
- [ ] Actualizar `Alethea.Clinical.Summary` añadiendo campo `type` con `validate_inclusion(["session", "weekly"])`
- [ ] Actualizar `Alethea.Accounts.Patient` añadiendo `session_day_of_week` y `session_time`

### IA — Análisis de Emoción (Bumblebee local)
- [ ] Crear `lib/alethea/ai/roberta_worker.ex` (`Alethea.AI.RoBERTaWorker`):
  - Inicia `Nx.Serving` con `Bumblebee.load_model({:hf, "pysentimiento/robertuito-emotion-analysis"})`
  - Expone `analyze(text)` → `[%{label: "alegría", score: 0.82}, ...]`
  - Expone `analyze_batch(texts)` → lista de resultados; promedia scores por emoción si `texts` tiene N elementos
- [ ] Añadir `{Alethea.AI.RoBERTaWorker, []}` al supervision tree en `lib/alethea/application.ex`

### Dominio — `SessionManager` y contexto `Clinical`
- [ ] Crear `lib/alethea/clinical/session_manager.ex` (`Alethea.Clinical.SessionManager`) con:
  - `open_session(patient)` → crea `Session` con `status: "open"`, retorna `{:ok, session}`
  - `close_session(session)` → actualiza `closed_at` y `status: "closed"`, retorna `{:ok, session}`
  - `current_open_session(patient_id)` → busca sesión abierta o crea una nueva
- [ ] Añadir a `Alethea.Clinical` (context):
  - `save_trends(patient, emotion_scores, session)` — guarda hasta 5 `Trend` (descartando surprise y disgust), calculando `delta` vs. último trend de cada emoción
  - `save_summary(attrs)` — crea `Summary` con `type` incluido
  - `list_session_summaries(patient_id, since)` — para el `WeeklyReportWorker`
  - `aggregate_trends(patient_id, since)` — agrega scores por `indicator_name` en período

### IA — Chains de Resumen
- [ ] Crear `lib/alethea/ai/chains/session_summary_chain.ex` (`SummaryChain`) con prompt de snapshot de 4 líneas: estado emocional, temas tratados, cambios observados, nivel de atención requerido
- [ ] Crear `lib/alethea/ai/chains/weekly_summary_chain.ex` (`WeeklySummaryChain`) con prompt de reporte semanal ≤ 8 líneas: estado emocional de la semana, temas recurrentes, eventos significativos, nivel de riesgo observado
- [ ] Ambas chains leen el modelo y `endpoint_url` del mismo `Application.get_env` que `GuidedConversationChain`

### Workers Oban
- [ ] Crear `lib/alethea_jobs/session_timeout_worker.ex` (`AletheaJobs.SessionTimeoutWorker`):
  - `use Oban.Worker, queue: :sessions, unique: [fields: [:args], period: 40 * 60, on_conflict: :replace]`
  - `perform/1`: ejecuta el flujo de cierre de sesión (ver diagrama arriba)
- [ ] Actualizar `AletheaJobs.ProcessMessageWorker` para, tras guardar el mensaje inbound:
  - Llamar a `SessionManager.current_open_session(patient)` para asociar el mensaje a la sesión abierta
  - Encolar/reemplazar `SessionTimeoutWorker` con `scheduled_at: DateTime.add(now, 30, :minute)`
- [ ] Crear `lib/alethea_jobs/daily_scheduler_worker.ex` (`AletheaJobs.DailySchedulerWorker`):
  - `use Oban.Worker, queue: :schedulers`
  - Configurar como cron en `config/config.exs`: `{"0 0 * * *", AletheaJobs.DailySchedulerWorker}`
  - `perform/1`: carga pacientes con `session_day_of_week` = mañana (UTC), encola `WeeklyReportWorker`
- [ ] Crear `lib/alethea_jobs/weekly_report_worker.ex` (`AletheaJobs.WeeklyReportWorker`):
  - `use Oban.Worker, queue: :reports`
  - `perform/1`: agrega trends, genera resumen semanal via `WeeklySummaryChain`, guarda en `clinical_summaries` con `type: "weekly"`
- [ ] Añadir las colas `sessions`, `schedulers`, `reports` a la configuración de Oban en `config/config.exs`

### Tests
- [ ] `test/alethea_jobs/session_timeout_worker_test.exs`:
  - Mock de `WhatsApp.Client` y `SummaryChain`; mock de `RoBERTaWorker.analyze_batch` via Mox
  - Verificar que se crean `Trend` records y un `Summary` type `"session"` tras el cierre
- [ ] `test/alethea/ai/roberta_worker_test.exs`:
  - Test de regresión: mockear `Nx.Serving.run` y verificar que `analyze_batch/1` retorna la estructura esperada
- [ ] `test/alethea_jobs/daily_scheduler_worker_test.exs`:
  - Verificar que el cron encola `WeeklyReportWorker` con el `scheduled_at` correcto para los pacientes cuya sesión es mañana
  - Verificar que los pacientes con `session_day_of_week` distinto al día de mañana no reciben job

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
