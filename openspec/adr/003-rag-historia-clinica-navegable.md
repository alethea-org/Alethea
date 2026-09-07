# ADR-003: El RAG es la historia clínica navegable del paciente

**Status:** Aceptado
**Fecha:** 2026-06-11
**Contexto:** Decisión de Fase 0 / Módulo 2 del grill-me

## Contexto y problema

Inicialmente el RAG estaba pensado como "índice semántico de mensajes del paciente" — útil para "resumí lo que dijo esta semana" pero insuficiente para el caso de uso real.

El sistema tiene tres tipos de datos clínicos que el psicólogo necesita consultar en lenguaje natural:
- Mensajes y respuestas (Telegram, con etiquetas de RoBERTa)
- Notas clínicas del profesional (texto libre + adjuntos)
- Transcripciones de sesiones (Whisper)
- Eventos de crisis, medicación, diagnósticos (vía notas)
- Resúmenes de brecha generados por IA
- Configuración de triggers del paciente
- Datos futuros de wearables

El psicólogo le pregunta a Alethea cosas como:
- "¿Qué medicación toma y desde cuándo?"
- "¿Cuántas crisis tuvo en el último mes?"
- "¿Le mencioné algo del suegro en la última sesión?"

Esto requiere que el RAG no sea solo "índice de mensajes" sino **la historia clínica completa del paciente, navegable semánticamente**.

## Decisión

**El RAG es la historia clínica navegable del paciente, con tres voces (paciente, psicólogo, sistema) y arquitectura de eventos semanticables.**

### Tres voces en el RAG

| Voz | Quién emite | Qué emite |
|---|---|---|
| Paciente | El paciente | Mensajes, futuras métricas de wearables |
| Psicólogo | El profesional | Notas clínicas, configuración de triggers, medicación, diagnósticos (vía notas) |
| Sistema | El sistema | Etiquetas de RoBERTa, psicometría inferida, resúmenes, embeddings, transcripciones |

El día que se necesite auditar "todo lo que el sistema sabe del paciente", se filtra por origen.

### Eventos semanticables

El RAG ingesta **eventos con contenido semanticable**, no solo mensajes. Un evento es cualquier unidad de información del paciente con texto embebible. Esto permite que mañana se sumen wearables, escalas PHQ-9 cargadas manualmente, o lo que sea, sin refactor del RAG.

## Consecuencias

### Positivas
- El RAG responde preguntas clínicas reales, no solo resúmenes narrativos.
- La arquitectura soporta la evolución del sistema (nuevos tipos de datos entran sin reescribir el RAG).
- Filtrar por voz/origen permite auditoría y compliance.

### Negativas
- El RAG no es un simple "índice de mensajes" — el equipo tiene que entender el modelo de eventos antes de tocarlo.
- Los adjuntos (PDFs, imágenes) NO se ingieren al RAG automáticamente. Solo el texto libre de la nota clínica. Si se necesita OCR, es scope aparte.

### Estrategia de chunking (decidida 2026-09-02, en el slice de #196)

**La unidad de chunk es el evento semanticable completo** (una nota clínica, una evidencia citada, una observación, un resumen) — no una ventana de tokens fija. BGE-M3 soporta contexto largo (hasta 8192 tokens), así que no hay límite técnico que fuerce a trocear; la razón es preservar la cita exacta que exige #196 (`labels each result by source with exact citations`). Trocear por conteo de tokens ciego puede partir una oración a la mitad o mezclar contenido de dos eventos en el mismo chunk.

**Excepción:** si el texto libre de un evento supera ~500 tokens (típicamente el cuerpo de una `ClinicalNote` extensa), se sub-trocea por límites de oración/párrafo — nunca por conteo de caracteres crudo — con ~15% de overlap entre sub-chunks para no perder contexto en el borde.

Metadata persistida por chunk: `source_event_id`, tamaño en tokens, si es evento completo o sub-chunk (y su índice de orden dentro del evento), y el modelo de embedding usado — necesario para reindexar sin perder trazabilidad (criterio de #193: *"persists source, model, and chunking metadata for reindexing"*).

### Rebuild y purga del índice (decidido 2026-09-02, en el slice de #196)

**Rebuild completo: on-demand, nunca programado.** El camino normal de actualización es el incremental vía outbox (evento por evento). El rebuild completo (re-embeber todo el historial desde cero) es una herramienta de recuperación disparada manualmente (comando ops), reservada para corrupción de índice, cambio de modelo de embeddings, o sospecha de desincronización — no corre en cron. Razón: el incremental transaccional ya es confiable; un rebuild periódico automático re-embebería el historial clínico completo de todos los pacientes de forma recurrente sin evidencia de que haga falta.

**Purga: un solo mecanismo, borrado inmediato.** Tanto el borrado legal (obligatoriamente inmediato, per #193) como el tombstoning ordinario (evidencia descartada, draft superado, nota reemplazada) disparan el mismo camino: borrado inmediato de la fila indexada vía outbox, sin distinción de velocidad. No hay soft-delete ni job de barrido periódico — nadie pidió la capacidad de "deshacer" un tombstoning, y mantener dos mecanismos de purga solo agrega superficie de bug.

Política de retención (por cuánto tiempo vive el contenido antes de ser elegible para purge) sigue ligada al lifecycle del ClinicalRecord, implementado en #197 — este ADR solo fija el mecanismo, no la ventana de tiempo.
