# Lenguaje Ubicuo de Alethea

**Versión:** 1.0
**Fecha:** 2026-06-11
**Origen:** Grill-me Fase 0 (4 módulos)

Este documento es la **fuente de verdad** del lenguaje del sistema. Si un término tiene dos definiciones en distintos archivos, gana la de acá. Si un término no está, no existe en el sistema.

---

## Roles

### Paciente
Interlocutor del sistema. Se comunica **únicamente por Telegram**. No tiene cuenta en la app web, no se loguea, no tiene email obligatorio. Recibe journaling interactivo de Alethea, registra su experiencia, recibe recordatorios, dispara crisis protocol si corresponde.

### Psicólogo
Usuario del SaaS. Opera **vía web** (LiveView). Gestiona sus pacientes, configura Alethea, lee la historia clínica navegable, carga notas, agenda sesiones, recibe alertas de crisis. **Es el tenant**: una cuenta de psicólogo aísla los datos de sus pacientes. Es el único actor clínico con acceso al dashboard.

### Admin
Operador del SaaS. Gestiona billing, planes, RevenueCat, soporte, onboarding de psicólogos. No tiene acceso a datos clínicos de pacientes (separación de responsabilidades).

### Tenant
Sinónimo operativo de **psicólogo** a nivel de modelo de datos. Cada psicólogo es un tenant; sus pacientes son datos de su tenant; el aislamiento es por tenant.

---

## Núcleo del dominio

### Mensaje
Unidad atómica de comunicación entre el sistema y el paciente, en cualquier dirección. Un mensaje tiene `media_type` (default `text`, arquitectura preparada para `audio`, `image`, `document` aunque el MVP solo acepta texto).

### Journaling interactivo
**Secuencia de mensajes entre paciente y Alethea a través de Telegram, guiada por el sistema.** No es la terapia — es el registro continuo del paciente entre sesiones. Incluye journaling diario, profundización, triggers, check-ins, recordatorios. **Este término reemplaza al viejo "conversación terapéutica", que era incorrecto porque la conversación terapéutica es la sesión clínica.**

### Sesión clínica
Encuentro entre el psicólogo y el paciente. Ocurre **fuera del sistema** (presencial, Meet, lo que sea), pero el sistema guarda la grabación y la transcripción. El psicólogo agenda cuándo tiene sesiones con cada paciente en el sistema (pueden ser N por semana).

### Grabación
Audio de la sesión clínica, subido al sistema. Se transcribe con Whisper.

### Transcripción
Texto de la grabación, generado por Whisper. Entra al RAG del paciente.

### Resumen de brecha
Documento generado **antes de cada sesión** con todo lo registrado por el paciente y por el sistema desde la última sesión. Es lo que el psicólogo lee para llegar a la sesión preparado.

### RAG
Índice vectorial del paciente, consultable en lenguaje natural. **Es la historia clínica navegable del paciente.** Contiene: journaling interactivo, etiquetas de análisis emocional, transcripciones, métricas inferidas, resúmenes de brecha, eventos de crisis, notas clínicas, configuración de triggers, medicación, diagnósticos (vía notas), datos futuros de wearables. Ver `adr/003-rag-historia-clinica-navegable.md`.

### Psicometría inferida
Métricas que el sistema calcula sobre los datos del paciente. **No son diagnoses** — son agregaciones e inferencias que el profesional usa como insumo. Ejemplos: "esta semana el paciente se mostró más ansioso", "frecuencia de menciones del suegro en el último mes".

### Crisis
Situación detectada que dispara el protocolo de crisis. La detección es por análisis de texto del paciente.

### Protocolo de crisis
Conjunto de acciones automáticas cuando se detecta crisis:
- Mensaje preconfigurado por el psicólogo al paciente
- Alerta al psicólogo
- Marcado en el dashboard del paciente
- **NO** se le muestran datos clínicos al paciente, ni siquiera si pregunta. El sistema se limita a dar contención y a escalar al humano.

---

## IA y análisis

### Análisis emocional
Etiquetas que un modelo (RoBERTa) le pone a un mensaje. Categorías: alegría, tristeza, miedo, enojo (las que se confirmen en implementación). Es por mensaje, no agregado.

### Personalidad de Alethea
Tono con el que Alethea le habla al paciente. **Configurable por el psicólogo, por paciente.** Cuatro opciones: clínico, cálido-cotidiano, silencioso, amigo-informado. Es un trigger pasivo más: "cuando le hablo a este paciente, sueno así".

---

## Triggers

**Definición base:** un trigger es siempre **condición + acción**.

### Trigger
Evento que desata una acción. Si no hay condición-acción explícita, no es trigger, es flujo normal.

### Trigger pasivo
La condición es un mensaje del paciente que matchea con X. La acción es lo que el psicólogo preconfiguró. **El trigger pasivo modifica la respuesta base de Alethea, no la reemplaza** — debe sonar como un recuerdo natural, no como un mensaje aparte.

### Trigger activo
La condición es un evento programado (fecha, hora, post-sesión, etc.). La acción la define el psicólogo o el sistema.

### Check-in
Trigger activo cuya acción es: Alethea le pregunta al paciente cómo está. Por ejemplo: todos los días a las 21hs.

### Recordatorio de sesión
Trigger activo cuya condición es "falta 1 hora para la sesión". La acción es avisarle al paciente.

---

## Datos clínicos del paciente

### Notas clínicas
Texto libre que carga el profesional. Es la **forma canónica de cargar datos clínicos en el sistema**, incluyendo diagnósticos. Las notas pueden tener adjuntos (PDFs, imágenes) que son descargables pero **no se ingieren al RAG** — solo el texto libre entra al RAG.

### Diagnóstico
Se carga como **nota clínica** con texto que da contexto (ej. "TDAH diagnosticado en mayo 2025 por Dra. X, evaluación tal") + adjunto de historia clínica si lo hay.

### Medicación
Lista simple: nombre del medicamento, fecha, dosis. Sin frecuencia, sin vía, sin profesional recetador en el MVP.

### Perfil del paciente
Datos personales mínimos cargados al alta: nombre, fecha de nacimiento, género, idioma principal, teléfono de Telegram, email opcional, contacto de emergencia (nombre + relación + teléfono).

---

## Lo que NO existe en el sistema

- **"Conversación terapéutica"** — borrado del lenguaje. Se llama **journaling interactivo**.
- **"Feedback programado"** — no es un tipo de trigger, es el contenido que el terapeuta programa adentro de un trigger (activo o pasivo).
- **"Gamificación"** — racha, emojis de estado, mensajes motivacionales. **Fuera de alcance del MVP.** Si se quiere en el futuro, se discute aparte.
- **"Sesión" como login** — login es login, sesión clínica es otra cosa.
- **WhatsApp, SMS, app móvil del paciente** — Telegram es el único canal, por diseño.
- **Handoff de IA a humano externo en crisis** — el protocolo de crisis es automático, no escala a un humano fuera del sistema.
- **Multi-paciente por sesión clínica** — una sesión es siempre 1 psicólogo + 1 paciente.
