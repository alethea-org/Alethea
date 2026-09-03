# PRD: Alethea MVP

> **Estado:** PRD vivo. Refleja las decisiones del grill-me de Fase 0 (junio 2026).
> **Lenguaje canónico:** ver `openspec/UBIQUITOUS_LANGUAGE.md`.
> **Contexto del sistema:** ver `openspec/CONTEXT.md`.
> **Decisiones técnicas:** ver `openspec/adr/`.

## Problem Statement

### Para el paciente
El journaling tradicional genera fricción cognitiva. En momentos de malestar, el esfuerzo de sentarse a escribir reduce la adherencia al registro clínico. Necesita algo tan simple como chatear por Telegram.

### Para el psicólogo
Carece de datos objetivos sobre lo que sucede entre sesiones. Depende del relato retrospectivo del paciente, cargado de sesgos de memoria. Necesita ver la evolución emocional semanal y preparar sesiones basadas en evidencia.

---

## Core Feature: Journaling Interactivo Asistido por IA

Paciente chatea por Telegram → Alethea responde y hace preguntas → Profesional ve dashboard + chatea con los datos (RAG como historia clínica navegable).

### Canal
**Telegram Bot** (gratis, simple, sin costo por mensaje)

### Flujo básico
1. Profesional crea paciente → genera código de 6 dígitos
2. Paciente instala Telegram, agrega bot, escribe `/start`
3. Paciente ingresa código → autenticado
4. Paciente registra experiencias → texto libre + emoji de estado
5. IA responde con preguntas de seguimiento (semi-activa)
6. Profesional recibe resumen pre-sesión + puede chatear con los datos

---

## User Stories

### Paciente

| # | Como... | Quiero... | Para... |
|---|---------|----------|---------|
| P1 | paciente | registrar mis experiencias durante el día con texto libre | expresar lo que me pasa en el momento |
| P2 | paciente | recibir preguntas de seguimiento de Alethea | profundizar en lo que registré |
| P3 | paciente | recibir contención si expreso ideas de crisis | ser derivado a ayuda profesional |
| P4 | paciente | ver la personalidad de Alethea consistente con lo que configuró su terapeuta | confiar en la conversación |
| P5 | paciente | que Alethea le recuerde la sesión próxima | no olvidarse de la cita |

### Profesional

| # | Como... | Quiero... | Para... |
|---|---------|----------|---------|
| PR1 | profesional | registrar pacientes con alias y teléfono | tenerlos en mi lista |
| PR2 | profesional | ver dashboard con pacientes, alertas y métricas | identificar quién necesita atención |
| PR3 | profesional | ver tendencias emocionales (joy, sadness, anger, fear) | entender la evolución de cada paciente |
| PR4 | profesional | recibir alertas de crisis 24/7 | intervenir cuando alguien lo necesita |
| PR5 | profesional | ver resumen pre-sesión generado 2h antes | prepararme para la sesión |
| PR6 | profesional | chatear con los datos del paciente (vista NotebookLM) | explorar insights sin modificar nada |
| PR7 | profesional | configurar triggers pasivos | que la IA recuerde temas específicos cuando el paciente los mencione |
| PR8 | profesional | configurar triggers activos | enviar recordatorios o preguntas en fecha/hora específica |
| PR9 | profesional | configurar triggers recurrentes | acciones periódicas ("cada domingo pregúntale cómo fue la semana") |
| PR10 | profesional | guardar y nombrar conversaciones de la vista NotebookLM |documentar análisis |
| PR11 | profesional | ver métricas: engagement, evolución emocional, retention | saber si el sistema funciona |

### Sistema

| # | Como... | Quiero... | Para... |
|---|---------|----------|---------|
| S1 | sistema | cifrar todos los mensajes con AES-256-GCM por paciente | garantizar privacidad |
| S2 | sistema | derivar clef del paciente | cryptographic erasure cuando el paciente elimina su cuenta |
| S3 | sistema | detectar triggers de crisis | bloquear respuesta de IA y notificar profesional |
| S4 | sistema | generar resúmenes semanales automáticamente | dar contexto al paciente |

---

## Arquitectura

### Módulos principales

```
lib/
├── alethea/
│   ├── accounts/           # Profesionales, pacientes, auth
│   ├── clinical/           # Mensajes, emociones, trends, summaries
│   ├── triggers/          # Pasivos, activos, recurrentes
│   ├── telegram/          # Gateway de Telegram
│   ├── ai/
│   │   ├── phi_worker.ex        # Phi-mini para respuestas
│   │   ├── roberta_worker.ex    # RoBERTa para emociones
│   │   └── chains/
│   │       ├── guided_conversation_chain.ex
│   │       ├── session_summary_chain.ex
│   │       └── weekly_summary_chain.ex
│   └── alerts/
│       └── crisis_monitor.ex    # Detección de crisis
├── alethea_jobs/           # Oban workers
│   ├── daily_scheduler_worker.ex      # Programa sessions
│   ├── emotion_analysis_worker.ex     # Procesa emociones async
│   ├── weekly_report_worker.ex        # Genera resumen semanal
│   ├── session_reminder_worker.ex     # Envia recordatorio
│   └── trigger_worker.ex             # Ejecuta triggers activos
```

### Flujo de datos

```
Paciente escribe en Telegram
    ↓
Webhook recibe mensaje
    ↓
Guarda mensaje encriptado (AES-256-GCM)
    ↓
Encola EmotionAnalysisWorker (RoBERTa)
    ↓
Encola InferencePipeline (Phi-mini)
    ↓
Respuesta → Telegram
    ↓
Si detecta crisis → CrisisMonitor → Notifica profesional
```

### Scheduling

```
DailyScheduler (diario 00:00)
    ↓
Para cada paciente activo con session_day_of_week mañana:
    - Programa WeeklyReportWorker (2h antes de sesión)
    - Programa SessionReminderWorker (24h antes)
```

---

## Decisiones de implementación

### Cifrado
- **AES-256-GCM** con DEK (Data Encryption Key) por paciente
- **KEK (Key Encryption Key)** por profesional que envuelve las DEKs
- **HMAC** para búsquedas seguras por hash de teléfono
- **Cryptographic Erasure**: eliminación de DEK = datos ilegibles

### IA

| Modelo | Uso | Proveedor | Costo |
|--------|-----|-----------|-------|
| **Phi-4-mini** | Respuestas conversacionales, resúmenes, psicometría batch | Groq (API) | Free tier en dev, bajo en prod |
| **RoBERTa-emotion** (local) | Clasificación de emociones por mensaje | Nx/Bumblebee en CPU | Costo marginal de cómputo |
| **Whisper** | Transcripción de sesiones | Groq (API) | Bajo |
| **Embeddings** (multilingüe, BGE-M3 local) | RAG del paciente | Ollama (self-hosted) | Sin costo por token; sin exposición externa de PII |

### Canales

| Canal | Estado | Costo | Alcance |
|-------|--------|-------|---------|
| **Telegram Bot** | MVP | Gratis | **Único canal del paciente**, sin alternativa prevista |
| WhatsApp / SMS | No contemplado | — | Decisión de diseño (ADR-004): Telegram es el único canal por costo y simplicidad |

---

## Out of Scope (MVP)

- App móvil para paciente
- App móvil para profesional
- Notificaciones push (Telegram se encarga)
- Gamificación (rachas, emojis, mensajes motivacionales)
- Auditoría completa (logs de quién vio qué)
- Edición de respuestas de Alethea por profesional
- Transferencia de pacientes entre profesionales
- Multi-idioma
- Notas de voz o imágenes (la arquitectura está lista, ver `JournalEntry.media_type`, pero el MVP solo acepta texto)
- Sensores y wearables del paciente (arquitectura lista en el RAG, integración post-MVP)
- Handoff a humano externo en crisis (protocolo automático, sin escalado externo)

---

## Out of Scope (Post-MVP)

- WhatsApp / SMS como canales adicionales
- Fine-tuning de modelos
- Gamificación avanzada (badges, logros)
- Métricas de equipo/clínica
- Soporte multi-profesional por paciente

---

## KPIs del Dashboard

| Métrica | Descripción |
|---------|-------------|
| **Engagement diario** | Mensajes/paciente/día |
| **Tasa de respuesta** | % mensajes con respuesta de IA |
| **Evolución emocional** | Tendencia de joy/sadness/anger/fear |
| **Alertas de crisis** | Count de detecciones |
| **Racha promedio** | Días consecutivos de registro |
| **Retention** | Pacientes activos después de 30/60/90 días |

---

## Gráfico de dependencias

```
                    ┌─────────────────────┐
                    │  Auth Profesional   │
                    └─────────┬───────────┘
                              │
         ┌────────────────────┼────────────────────┐
         │                    │                    │
         ▼                    ▼                    ▼
┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐
│   Telegram Bot  │  │   Dashboard     │  │  Trigger Config │
│   (paciente)   │  │ (profesional)  │  │  (profesional)  │
└────────┬────────┘  └────────┬────────┘  └────────┬────────┘
         │                   │                    │
         └───────────┬───────┴────────────────────┘
                     │
                     ▼
            ┌─────────────────┐
            │  Clinical Core │
            │  (messages,    │
            │   emotions,     │
            │   trends)       │
            └────────┬────────┘
                     │
         ┌───────────┼───────────┐
         │           │           │
         ▼           ▼           ▼
┌─────────────┐ ┌──────────┐ ┌──────────┐
│   Phi-mini  │ │  RoBERTa │ │ Triggers │
│  (respuesta) │ │(emociones)│ │ (pasivos,│
│             │ │          │ │ activos)  │
└─────────────┘ └──────────┘ └──────────┘
```

---

## Métricas de éxito

### Semana 1 post-lanzamiento
- [ ] 80% de pacientes activos envían ≥1 mensaje/día
- [ ] 0 falsos negativos en detección de crisis
- [ ] Profesional reporta que resumen pre-sesión es útil

### Mes 1
- [ ] Retention 60% a 30 días
- [ ] Profesional usa triggers configurables
- [ ] Profesional guarda ≥1 conversación NotebookLM/semana

---

## Notas

- Interfaz del psicólogo: **Light Mode** (requerimiento de diseño)
- Alethea debe mantener **neutralidad socrática** — no da consejos terapéuticos
- Crisis tiene prioridad absoluta sobre cualquier otra lógica
- El paciente **nunca** ve datos clínicos propios, ni siquiera si pregunta. Es regla dura del sistema.
- La terapia es la sesión, no el chat. El sistema refuerza esta distinción clínica, ética y de producto.
