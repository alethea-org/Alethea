# CONTEXT.md — Alethea

**Versión:** 1.0
**Fecha:** 2026-06-11
**Origen:** Síntesis de Fase 0 (grill-me de 4 módulos)

Este documento es la **puerta de entrada** al sistema. Si leés esto, entendés qué hace Alethea, para quién, y con qué reglas de juego. Para el lenguaje canónico, ver `UBIQUITOUS_LANGUAGE.md`. Para las decisiones técnicas, ver `adr/`.

---

## Qué es Alethea

Alethea es un SaaS para psicólogos. Les da una herramienta para **acortar la brecha de información entre sesiones**: mientras el paciente vive su semana, journalingea con Alethea por Telegram, y el terapeuta llega a la sesión con material procesado — no con la hoja en blanco.

**Para el paciente:** un canal de acompañamiento continuo. Journaling con IA, recordatorios, feedback programado por el terapeuta, conversación cuando quiere profundizar en algo que le pasa en el momento.

**Para el psicólogo:** una historia clínica navegable del paciente, alimentada por el journaling, transcripciones de sesiones, notas clínicas, y consultas en lenguaje natural tipo NotebookLM.

**Visión a futuro:** que Alethea se vuelva la nueva forma estándar de acompañamiento terapéutico, y que la psicometría sobre los mensajes sea un output del sistema, no un análisis manual.

---

## Los tres principios que el sistema no negocia

### 1. El paciente solo ve su conversación
El sistema **nunca** le muestra al paciente datos clínicos propios — ni análisis emocional, ni psicometría, ni medicación, ni diagnósticos, ni crisis pasadas. Ni siquiera si el paciente pregunta. Si pregunta, el sistema le dice algo neutro y deriva la conversación al espacio clínico. El paciente es dueño de lo que escribe; el terapeuta es dueño de lo que el sistema sabe de él.

### 2. La terapia es la sesión, no el chat
El journaling interactivo es **registro entre sesiones**, no terapia. El sistema está diseñado para no confundirse: "conversación terapéutica" no es un término válido en Alethea — la conversación terapéutica es la sesión clínica. Esta distinción es clínica, ética y de producto.

### 3. RAG = historia clínica navegable
El RAG no es "índice semántico de mensajes". Es la historia clínica completa del paciente, consultable en lenguaje natural. Cuando el profesional le pregunta a Alethea "¿qué medicación toma Juan?", el sistema responde. Cuando le pregunta "¿hubo crisis esta semana?", el sistema responde. Esto es lo que vuelve a Alethea diferente de un chatbot genérico.

---

## Modelo de roles

| Rol | Canal | Qué hace |
|---|---|---|
| **Paciente** | Telegram (único) | Journaling, recibe Alethea, dispara crisis si pasa, ve solo su conversación |
| **Psicólogo** | Web (LiveView) | Configura Alethea por paciente, lee historia clínica, agenda sesiones, carga notas |
| **Admin** | Web (LiveView) | Billing, RevenueCat, soporte, onboarding. Sin acceso a datos clínicos |

El psicólogo es el **tenant**: una cuenta aísla los datos de sus pacientes.

---

## Las piezas que articulan el sistema

### Journaling interactivo (paciente ↔ Alethea, por Telegram)
- El paciente escribe. Alethea **siempre** responde.
- Alethea tiene **personalidad configurable** por el psicólogo, por paciente (clínico, cálido-cotidiano, silencioso, amigo-informado).
- Cada mensaje del paciente pasa por **análisis emocional** (RoBERTa local).
- **Triggers pasivos** modifican la respuesta de Alethea si el mensaje del paciente matchea una condición preconfigurada (debe sonar como recuerdo natural, no como mensaje aparte).
- **Triggers activos** disparan acciones en eventos programados (check-in diario, recordatorio de sesión, pregunta del terapeuta en fecha X).
- **Por ahora solo texto.** La arquitectura está lista para audio/imagen/documento (`media_type` en `JournalEntry`).

### Sesión clínica (ocurre fuera, registrada en el sistema)
- El terapeuta agenda cuándo tiene sesión con cada paciente (N por semana, no fijo).
- **Antes de la sesión:** se genera un **resumen de brecha** automático con todo lo registrado desde la última sesión.
- **Durante la sesión:** el terapeuta puede tomar notas en vivo o después. La grabación se sube al sistema, Whisper la transcribe, la transcripción entra al RAG.
- **Después de la sesión:** el RAG queda actualizado con la sesión.

### Crisis protocol
- Detección por análisis de texto del paciente.
- Si hay crisis: mensaje preconfigurado por el terapeuta al paciente + alerta al profesional + marcado en dashboard.
- El paciente **no** ve "tu IA detectó una crisis". Recibe contención, y el terapeuta es notificado.

### RAG (historia clínica navegable)
- El psicólogo le pregunta a Alethea cosas en lenguaje natural y el sistema responde citando las fuentes.
- Ingesta: journaling, transcripciones, notas clínicas, psicometría, crisis, medicación, configuración de triggers, perfil, diagnósticos (vía notas), datos futuros de wearables.
- **Tres voces:** paciente (mensajes, wearables), psicólogo (notas, triggers, medicación), sistema (etiquetas, métricas, resúmenes).
- **Adjuntos NO se ingieren al RAG.** Solo el texto libre de las notas. PDFs e imágenes son descargables.

### Visibilidad del paciente
- **Default: oculto.** El paciente no ve análisis, métricas, crisis, ni nada que el sistema infiera.
- **Configurable por el psicólogo y por métrica** (diseñado para que mañana se pueda mostrar algo sin refactor mayor).
- **Hard rule:** el sistema no le contesta al paciente ningún dato clínico propio, ni siquiera si pregunta.

---

## Stack y decisiones técnicas (resumen)

- **Web:** Phoenix 1.8 + LiveView. Sin OpenAPI.
- **DB:** PostgreSQL + Ecto + pgvector.
- **Jobs:** Oban.
- **Cifrado:** Cloak.Ecto (campos sensibles).
- **IA local:** Nx + Bumblebee + tokenizers (RoBERTa para análisis emocional).
- **IA externa:**
  - LLM = Phi-4-mini en Groq
  - Whisper = en Groq
  - Embeddings = HF Inference API con modelo multilingüe (e5-large o bge-m3)
- **Canal paciente:** Telegram Bot (único).

Detalle en `adr/`.

---

## Lo que NO entra en el MVP

- WhatsApp, SMS, app móvil del paciente
- Gamificación (rachas, emojis, mensajes motivacionales)
- Multi-tenant complejo (equipos, organizaciones)
- Multi-paciente por sesión
- Handoff a humano externo en crisis (protocolo automático, sin escalado externo)
- Multi-idioma
- Sensores/wearables (arquitectura lista, integración post-MVP)
- Notificaciones push (Telegram se encarga)
- Auditoría completa de accesos a datos clínicos
- Edición de respuestas de Alethea por el terapeuta
- Transferencia de pacientes entre profesionales

---

## Estado actual del proyecto

- **Sistema anterior:** existe código, modelos, jobs, pero el proyecto está **sin uso en producción**. Se rehace desde decisiones técnicas y de producto, conservando lo que sirve y descartando lo que no.
- **Tests:** `mix test` corre 224 tests, 1 falla preexistente (no bloqueante, copy en español en `page_controller_test.exs:6`), 5 skipped.
- **Strict TDD Mode:** activado. Toda implementación nueva sigue red-green-refactor.
- **Workflow:** SDD (proposal → spec → design → tasks → apply → verify → archive) sobre OpenSpec. TDD estricto por task.
