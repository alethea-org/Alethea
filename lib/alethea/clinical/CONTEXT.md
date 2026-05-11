# Clinical Engine: `lib/alethea/clinical/`

Aquí reside la lógica que transforma un mensaje de WhatsApp en un recurso clínico valioso para el psicólogo.

## Propósito
Modelar la conducta verbal, detectar crisis y organizar el diario del paciente de forma estructurada.

## Sub-módulos
*   **Behavior Graph**: Lógica para mapear relaciones en Neo4j.
*   **Crisis Triggers**: Filtros deterministas y pasivos para detección de riesgo.
*   **Journaling**: Gestión del historial de entradas y sesiones de voz.

## Guía para Desarrolladores y Agentes
1.  **Validación Clínica**: Los datos generados aquí deben ser verificables. Siempre guarda el `source_id` del mensaje original.
2.  **Etiquetado**: Distingue rigurosamente entre datos `SPONTANEOUS` y `ELICITED`.
3.  **Neutralidad**: La lógica de intervención debe seguir las instrucciones del terapeuta, no sesgos del modelo de IA.
