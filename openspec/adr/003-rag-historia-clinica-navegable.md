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

### Decisiones que NO se toman acá
- Tamaño de chunk, overlap, ventana de contexto → se decide en el slice de implementación.
- Política de retención y purge → se discute cuando se defina lifecycle del paciente.
