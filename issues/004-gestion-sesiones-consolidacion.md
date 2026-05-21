# Issue 004: Gestión de Sesiones y Consolidación (Heavy Processing)

**Type**: AFK
**Blocked by**: issues/003-integracion-meta-api-ia-reflexion.md
**User Stories Covered**: 6, 3

## Description
Gestionar el ciclo de vida de la interacción diaria. El sistema debe detectar la inactividad y disparar el procesamiento pesado de datos de forma asíncrona para que el dashboard del psicólogo sea instantáneo.

## Tasks
- [ ] Crear las siguientes migraciones antes de implementar cualquier lógica:
    - **`clinical_sessions`** (tabla nueva): `id` (binary_id PK), `patient_id` (FK → patients), `started_at` (utc_datetime), `closed_at` (utc_datetime, nullable), `status` (string: `"open" | "closed"`).
    - **`messages.session_id`** (FK → clinical_sessions, nullable): permite agrupar mensajes por sesión sin depender de rangos de timestamps frágiles.
    - **`messages.embedding`** (columna `vector(384)`): para guardar el vector de sentence transformers por mensaje, habilitando búsqueda semántica via pgvector.
    - **`clinical_summaries.type`** (string: `"session" | "weekly"`, NOT NULL): distingue los snapshots de sesión del Weekly Pre-Session Report.
- [ ] Implementar `Alethea.Clinical.SessionManager` para manejar estados de sesión (`open` / `closed`).
- [ ] Configurar un timeout de 30 minutos por paciente usando Oban con política `unique` y `on_conflict: :replace` sobre `scheduled_at`, de forma que cada mensaje nuevo reinicie el timer sin acumular jobs duplicados.
- [ ] Al cumplirse el timeout o cierre explícito, ejecutar en secuencia:
    - **Análisis de sentimiento** (RoBERTa vía Bumblebee): clasificar cada mensaje de la sesión como positivo/negativo/neutral y guardar los scores en la tabla `trends`. RoBERTa produce scores de clasificación, no vectores.
    - **Generación de embeddings** (modelo de sentence transformers vía Bumblebee, ej: `sentence-transformers/all-MiniLM-L6-v2`): producir un vector de alta dimensión por mensaje o por sesión y guardarlo en la columna `pgvector`. Este es un modelo distinto a RoBERTa con un propósito distinto (búsqueda semántica, no clasificación).
    - **Snapshot clínico** (LangChain + LLM externo): generar el resumen de 4 líneas usando los scores y mensajes de la sesión como input, y guardarlo en la tabla `summaries`.
- [ ] Enviar mensaje automático de despedida al paciente al cerrar la sesión.
- [ ] Implementar un Oban job recurrente (`WeeklyReportWorker`) que se ejecute una vez por semana por paciente activo:
    - Recuperar todos los `summaries` de la semana del paciente.
    - Agregar los scores de `trends` del período para identificar emociones predominantes y disparadores recurrentes.
    - Generar con LangChain un **Weekly Pre-Session Report** (máximo 8 líneas) que consolide: estado emocional de la semana, temas recurrentes, eventos significativos y nivel de riesgo observado.
    - Guardar el reporte en la tabla `summaries` con un campo `type` que distinga `:session` de `:weekly`.
- [ ] Actualizar Issue 006 para que la vista de detalle del paciente muestre el **Weekly Pre-Session Report** de forma prominente, por encima de los snapshots individuales de sesión.
