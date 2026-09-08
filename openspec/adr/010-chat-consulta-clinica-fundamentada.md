# ADR-010: El chat de consulta clínica se fundamenta exclusivamente en la historia indexada del paciente

**Status:** Aceptado
**Fecha:** 2026-09-07
**Contexto:** Decisión de producto y dominio para el Chat de consulta clínica fundamentada.

## Contexto y problema

ADR-003 establece que el RAG es la historia clínica navegable del paciente, pero no decide el contrato de una interfaz conversacional sobre esa historia. Sin ese contrato, una respuesta podría mezclar conocimiento general con el registro clínico, ocultar la procedencia de sus afirmaciones o responder mientras el índice está incompleto.

El Chat de consulta clínica fundamentada consolida la consulta clínica existente en una única superficie conversacional para el psicólogo autorizado y uno de sus pacientes. No es journaling interactivo, no es un canal para el paciente y no sustituye el juicio clínico del profesional.

## Decisión

1. **Alcance de la evidencia.** Cada respuesta recupera evidencia actual del historial completo indexado del paciente consultado. El historial de la conversación solo resuelve seguimientos; nunca es evidencia.
2. **Respuesta verificable.** La respuesta separa visiblemente la **Síntesis basada en evidencia** y las **Fuentes**. Para solicitudes interpretativas sobre patrones, relaciones o hipótesis, puede incluir además una **Hipótesis para revisar**, diferenciada de la síntesis, obligatoriamente citada y revisable por el psicólogo. Una hipótesis no es un diagnóstico ni una recomendación terapéutica.
3. **Citas derivadas en servidor.** Cada cita permite acceder al fragmento exacto que la sustenta, su tipo de fuente y su fecha. La evidencia y sus citas se derivan de la recuperación del paciente, no del contenido previo de la conversación.
4. **Sin respuesta fuera del registro.** Si la evidencia indexada no alcanza, el chat indica que el registro no permite responder y puede sugerir reformular la consulta o revisar las fuentes. No completa la respuesta con conocimiento general.
5. **Frescura como condición de respuesta.** Si la indexación del paciente está pendiente o desactualizada, el chat bloquea la respuesta y solicita reintentar cuando finalice la actualización.
6. **Estado efímero.** El historial conversacional es acotado a la sesión y se descarta al navegar, remontar, cerrar sesión o iniciar una conversación nueva. No se guardan hilos nombrados, contenido conversacional ni metadatos de auditoría o acceso.

## Consecuencias

### Positivas

- El psicólogo puede distinguir de inmediato entre evidencia, hipótesis revisable y fuentes.
- La consulta conserva el alcance de paciente y reduce el riesgo de presentar información incompleta o no atribuible como hecho clínico.
- Una sola superficie evita duplicar la búsqueda clínica y el chat.
- La ausencia de persistencia conversacional y de metadatos de acceso reduce la retención de datos derivados de la consulta.

### Negativas

- El chat no puede responder preguntas que excedan el registro indexado, aunque un modelo tenga conocimiento general pertinente.
- La disponibilidad de la respuesta depende de que el índice del paciente esté actualizado.
- Los seguimientos y las conversaciones se pierden al finalizar la sesión; no hay recuperación mediante hilos guardados ni auditoría de accesos.

## Alternativas rechazadas

- **Chat genérico con conocimiento general como respaldo:** rechazado porque desdibuja qué parte de la respuesta proviene de la historia clínica del paciente.
- **Responder durante una indexación pendiente:** rechazado porque una respuesta citada pero incompleta puede aparentar una conclusión clínica confiable.
- **Persistir hilos, historial o auditoría de acceso:** rechazado en este alcance; PR10 y cualquier persistencia posterior requieren una decisión explícita.
- **Mantener una búsqueda clínica separada del chat:** rechazado porque duplica la misma tarea de navegación de la historia clínica.
