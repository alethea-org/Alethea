# Clinical Engine: `lib/alethea/clinical/`

Aquí reside la lógica que transforma un mensaje de WhatsApp en un recurso clínico valioso para el psicólogo.

## Propósito
Modelar la conducta verbal, detectar crisis y organizar el diario del paciente de forma estructurada.

## Sub-módulos
*   **Behavior Graph**: Lógica para mapear relaciones en Neo4j.
*   **Crisis Triggers**: Filtros deterministas y pasivos para detección de riesgo.
*   **Journaling**: Gestión del historial de entradas y sesiones de voz.

## Esquema de Base de Datos (ER)
*   **Table `messages`**: 
    *   `id` (UUIDv4)
    *   `patient_id` (FK -> `patients.id`)
    *   `direction` (inbound, outbound)
    *   `encrypted_content` (AES-256)
    *   `encryption_version` (Integer)
    *   `synced_to_graph` (Boolean, for Neo4j projection)
    *   `timestamp` (UTC)
*   **Table `clinical_summaries`**: 
...
    *   `patient_id` (FK -> `patients.id`)
    *   `period_start`, `period_end`
    *   `summary_text` (Consolidated diagnosis)
    *   `status_level` (Estable, Alerta, Intervención Requerida)
*   **Table `clinical_trends`**:
    *   `id` (UUIDv4)
    *   `patient_id` (FK -> `patients.id`)
    *   `indicator_name` (Ej. Ansiedad, Sueño, Socialización)
    *   `score` (Float para gráficas de progreso)
    *   `delta` (Cambio respecto a la medición anterior)
    *   `timestamp`

## Guía para Desarrolladores y Agentes
1.  **Validación Clínica**: Los datos generados aquí deben ser verificables. Siempre guarda el `source_id` del mensaje original.
2.  **Etiquetado**: Distingue rigurosamente entre datos `SPONTANEOUS` y `ELICITED`.
3.  **Neutralidad**: La lógica de intervención debe seguir las instrucciones del terapeuta, no sesgos del modelo de IA.

## Decisiones de contexto

### Intercambios de crisis en el contexto de journaling (#399)

**Decisión**: un intercambio de crisis (el inbound que disparó la crisis + su
respuesta `crisis_bypass`) **se reemplaza por un único turno placeholder
neutral** (`[Intercambio gestionado por el protocolo de apoyo]`) cuando se
arma el historial para el modelo (`Alethea.Clinical.list_conversation_turns/3`)
o la ventana del running summary (`Alethea.Clinical.RunningSummary.window_turns/3`).
Ni las palabras del disparador ni el copy de crisis llegan al modelo
conversacional; el placeholder preserva la continuidad de que hubo un
intercambio gestionado. Consistente con el mitigador interino de #394
(`RunningSummaryValidator` prohíbe copy de crisis en los resúmenes).

**Población única**: la misma regla gobierna el contenido del historial, la
ventana del resumen y la cuenta de cadencia del resumen (los inbounds
disparadores no cuentan para el batch de 10). Regla de identificación,
gap de detección residual y detalles en `Alethea.Clinical.CrisisExchange`.

**Fuera de alcance**: el camino de crisis, el copy de crisis y la autoridad de
crisis quedan sin cambios (#389).

**Sign-off clínico**: requerido por los criterios de aceptación de #399
cambio de comportamiento respecto a la regla anterior (que incluía los
intercambios verbatim); pendiente de confirmación antes de merge.
