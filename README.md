# Alethea

Diario interactivo y sensor de conducta verbal para la continuidad terapéutica.

[![Elixir](https://img.shields.io/badge/Elixir-1.19-4b275f?logo=elixir&logoColor=white)](https://elixir-lang.org)
[![OTP](https://img.shields.io/badge/OTP-28-4b275f?logo=erlang&logoColor=white)](https://www.erlang.org)
[![Phoenix](https://img.shields.io/badge/Phoenix-1.8-FD4F00?logo=phoenixframework&logoColor=white)](https://www.phoenixframework.org)
[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-15-336791?logo=postgresql&logoColor=white)](https://www.postgresql.org)
[![Redis](https://img.shields.io/badge/Redis-7-DC382D?logo=redis&logoColor=white)](https://redis.io)
[![CI](https://github.com/alethea-org/Alethea/actions/workflows/elixir.yml/badge.svg)](https://github.com/alethea-org/Alethea/actions)

## 🚀 Onboarding

¿Sos dev nuevo del equipo o evaluador de la materia "Proyecto"? Empezá por acá:

### 📘 [`.github/QUICKSTART.md`](.github/QUICKSTART.md)

- 5 minutos de lectura. Cubre el modelo completo con diagramas.
- 3 escenarios paso-a-paso (tomar issue, ser PO, issue bloqueada).
- Tabla de comandos `gh` para auditar quién hizo qué.

### Después seguí con

- [`.github/CONTRIBUTING.md`](.github/CONTRIBUTING.md) — reglas formales y vocabulario de labels.
- [`openspec/adr/009-triage-workflow.md`](openspec/adr/009-triage-workflow.md) — la decisión de diseño (ADR).
- [`openspec/sdd/triage-workflow/`](openspec/sdd/triage-workflow/) — el SDD completo.
- [Issue #150 Triage rota](https://github.com/alethea-org/Alethea/issues/150) — quién es el PO actual y el orden de rotación.

## Tabla de Contenidos

- [Visión del Proyecto](#visión-del-proyecto)
- [Modelo de Dominio](#modelo-de-dominio)
- [Quick Start](#quick-start)
- [Pruebas](#pruebas)
- [CI / GitHub Actions](#ci--github-actions)
- [Arquitectura Técnica](#arquitectura-técnica)
- [Seguridad y Privacidad](#seguridad-y-privacidad)
- [Principios Éticos y de IA](#principios-éticos-y-de-ia)
- [Estado de Seguridad](#estado-de-seguridad)
- [Roadmap de Desarrollo](#roadmap-de-desarrollo)
- [Despliegue](#despliegue)
- [Comandos útiles](#comandos-útiles)

---

## Visión del Proyecto

Para psicólogos que trabajan con información fragmentada y sesgada de sus pacientes, **Alethea** es una plataforma de journaling interactivo que convierte las vivencias diarias en registros clínicos estructurados y objetivos en tiempo real.

A diferencia del journaling manual, el producto simplifica el registro mediante una conversación guiada vía **Telegram** (canal único del paciente), permitiendo al profesional expandir su visión diagnóstica con datos ya organizados para la sesión.

La visión del producto incluye tres ejes diferenciales:

- **Personalidad configurable de Alethea por paciente** — el profesional define el tono (clínico, cálido-cotidiano, silencioso, amigo-informado) y el bot lo respeta.
- **Triggers configurables** — *pasivos* (modifican la respuesta de Alethea cuando el mensaje del paciente matchea una condición), *activos* (disparan acciones en eventos programados: recordatorios, preguntas del terapeuta en fecha X) y *recurrentes* (acciones periódicas, p. ej. "cada domingo pregúntale cómo fue la semana").
- **Borrado criptográfico al cierre del proceso terapéutico** — cada paciente tiene su propia clave de cifrado (DEK envuelta por una KEK). Terminado el proceso, la DEK se destruye y los datos se vuelven irrecuperables sin depender de borrado físico.

El modelo de datos convive durante la transición con dos representaciones de paciente (`Accounts.Patient` por alias y `Foundation.Accounts.Patient` por `telegram_chat_id_hash`); la primera se retirará cuando el flujo Telegram sea el único camino de registro (issue #107 en curso).

---

## Modelo de Dominio

El lenguaje canónico del sistema vive en [`openspec/UBIQUITOUS_LANGUAGE.md`](openspec/UBIQUITOUS_LANGUAGE.md): términos como *paciente*, *psicólogo*, *tenant*, *journaling interactivo*, *sesión clínica*, *grabación*, *crisis protocol* y *RAG como historia clínica navegable* se definen ahí y son la fuente de verdad.

[`openspec/CONTEXT.md`](openspec/CONTEXT.md) sintetiza las reglas de juego del producto (qué es y qué no es Alethea, los tres principios que el sistema no negocia, qué piezas lo articulan y qué queda fuera del MVP).

Las decisiones técnicas duras (LLM en Groq, embeddings HF, Telegram como único canal, rotación del pepper de `telegram_chat_id_hash`) están registradas en [`openspec/adr/`](openspec/adr/).

---

## Quick Start

### Prerrequisitos

| Herramienta | Versión | Uso |
| --- | --- | --- |
| Elixir | 1.19+ | Lenguaje y framework (versión validada por el CI) |
| Erlang/OTP | 28 | Runtime de Elixir |
| PostgreSQL | 15+ | Base de datos principal |
| Redis | 7+ | Cola/infraestructura de soporte |
| Docker | Cualquiera | Opcional: levanta las dependencias en un comando |
| Node.js | 20 | Opcional: solo para regenerar los assets estáticos |

> Nota: las versiones de Elixir y OTP se alinean con las que usa el flujo de CI
> (ver [CI / GitHub Actions](#ci--github-actions)). `mix.exs` declara compatibilidad con Elixir `~> 1.15`, por lo que versiones superiores funcionan sin cambios.

### Opción A: Docker Compose (recomendado)

Requisito: tener Docker instalado.

```bash
docker compose up
```

- Aplicación: <http://localhost:4000>
- Health check: <http://localhost:4000/health>
- Mailpit (email de desarrollo): <http://localhost:8025>

El compose levanta la aplicación, PostgreSQL y Redis. En desarrollo Telegram se simula con `Alethea.Telegram.Client.Fake`, por lo que **no** se requiere bot real ni webhook público.

### Opción B: Instalación local

1. Instalar **Elixir 1.19** y **Erlang/OTP 28** (asdf, apt, Homebrew o el manejador de tu preferencia).
2. Tener PostgreSQL y Redis disponibles. La forma más rápida es solo levantar las dependencias:

   ```bash
   docker compose up -d db redis
   ```

   O instalarlos nativamente y asegurar que `postgres` con contraseña `postgres` sea accesible en `localhost:5432` y Redis en `localhost:6379`.

3. Obtener el código:

   ```bash
   git clone https://github.com/alethea-org/Alethea.git
   cd Alethea
   ```

4. Instalar dependencias de Elixir:

   ```bash
   mix deps.get
   ```

5. Crear la base de datos, migrar y cargar los seeds:

   ```bash
   mix setup
   ```

   Esto ejecuta `mix deps.get`, `ecto.create`, `ecto.migrate` y `run priv/repo/seeds.exs`.

6. Ejecutar la aplicación:

   ```bash
   mix phx.server
   ```

   La aplicación queda disponible en <http://localhost:4000>.

Los assets estáticos ya vienen pre-construidos en `priv/static/assets`, por lo que no es necesario correr `npm install` para desarrollo. Si modificas los assets y quieres regenerarlos:

```bash
npm install --prefix assets
mix assets.deploy
```

### Configuración opcional de IA

En desarrollo **no** se requieren credenciales externas: el cliente de Telegram (`Alethea.Telegram.Client.Fake`) y todos los servicios de IA (LLM, Whisper, RoBERTa, embeddings) usan implementaciones `Fake`. Solo se activan proveedores reales si se configuran:

- **LLM (Phi-4 mini):** el adaptador de producción corre en **Groq** (ver [ADR-001](openspec/adr/001-llm-en-groq.md)). Alternativa local vía [Ollama](https://ollama.com): `LOCAL_LLM_BASE_URL=http://localhost:11434/v1`. El modelo se define con `LLM_MODEL` (default `phi-4-mini`).
- **Whisper (transcripción de sesiones clínicas):** Groq en producción.
- **RoBERTa (análisis de emociones):** **local** vía `Bumblebee` + `Nx` (`lib/alethea/ai/roberta_worker.ex`). Como alternativa puede usarse la API de Hugging Face configurando `HUGGINGFACE_API_KEY`.
- **Embeddings:** Hugging Face Inference API con modelo multilingüe (ver [ADR-002](openspec/adr/002-embeddings-hf-multilingue.md)).
- **Cliente Telegram:** `Alethea.Telegram.Client.Fake` en dev/test, `Alethea.Telegram.Client.Req` (HTTP vía [`Req`](https://hexdocs.pm/req)) en producción.

---

## Pruebas

El job de CI corre exactamente estos comandos — puedes reproducirlos localmente:

```bash
export MIX_ENV=test
export PGHOST=localhost PGPORT=5432 PGUSER=postgres PGPASSWORD=postgres PGDATABASE=alethea_test
export REDIS_HOST=localhost REDIS_PORT=6379
mix test
```

El alias `test` de `mix.exs` crea y migra la base de datos de prueba automáticamente antes de correr la suite.

Para una verificación completa (compilación sin warnings, formato y tests):

```bash
mix precommit
```

---

## CI / GitHub Actions

El flujo de CI está definido en `.github/workflows/elixir.yml` y se dispara con `push` y `pull_request` sobre la rama `main`.

| Trabajo | Descripción |
| --- | --- |
| `test` | Levanta servicios PostgreSQL **15** y Redis **7**; instala Elixir **1.19** con OTP **28** (vía `erlef/setup-beam@v1`); ejecuta `mix deps.get` y `mix test`. |
| `format` | Instala Elixir 1.19/OTP 28; ejecuta `mix deps.get` y `mix format --check-formatted`. |

---

## Arquitectura Técnica

Monolito Modular bajo **Arquitectura Hexagonal**, priorizando la soberanía de los datos y la resiliencia clínica. La capa de dominio está desacoplada del framework mediante puertos/adaptadores, de modo que cualquier servicio externo (Telegram, LLM, embeddings, Whisper) se intercambia por su `Fake` correspondiente en dev y tests.

| Capa | Tecnología | Propósito |
| --- | --- | --- |
| Web | [Phoenix 1.8](https://www.phoenixframework.org/) + LiveView | Dashboard del profesional (LiveView), única vía de acceso del psicólogo al sistema |
| API | Phoenix Router + JSON | Webhooks de Telegram (`/webhooks/telegram`) |
| Backend / dominio | Elixir + OTP | Alta concurrencia y gestión de estado en tiempo real |
| IA – LLM conversacional | **Phi-4 mini** vía `Bumblebee` (Nx/EXLA) o **Groq** en prod | Respuestas de la conversación guiada (chains en `lib/alethea/ai/chains/`) |
| IA – Emociones | **RoBERTa** vía `Bumblebee` + `Nx` (alternativa: Hugging Face API) | Análisis emocional por mensaje, encola vía `EmotionAnalysisWorker` |
| IA – Transcripción | **Whisper** vía Groq (configurable, ver `adr/001-llm-en-groq.md`) | Transcripción de grabaciones de sesión clínica |
| IA – Orquestación | [`langchain`](https://github.com/elixir-langchain/langchain) | Chains: `guided_conversation_chain`, `session_summary_chain`, `weekly_summary_chain` |
| IA – Embeddings | Hugging Face Inference API (multilingüe, e5-large / bge-m3) | Vector store semántico (ver [ADR-002](openspec/adr/002-embeddings-hf-multilingue.md), [ADR-003](openspec/adr/003-rag-historia-clinica-navegable.md)) |
| Cola asíncrona | [Oban](https://hexdocs.pm/oban/) con colas `telegram_inbound`, `telegram_outbound`, `telegram_outbound_crisis`, `ai_analysis` | Procesamiento asíncrono y patrón de Recibo Transaccional. La cola `telegram_outbound_crisis` tiene prioridad más alta para crisis |
| HTTP externo | [`Req`](https://hexdocs.pm/req) | Cliente HTTP canónico del proyecto (Telegram, Groq, Hugging Face) |
| Cifrado | [`Cloak.Ecto`](https://hexdocs.pm/cloak_ecto) (AES-256-GCM) + DEK por paciente envuelta por KEK | Cifrado de campos sensibles y borrado criptográfico |
| Passwords | [`pbkdf2_elixir`](https://hexdocs.pm/pbkdf2_elixir) | Hashing de credenciales |
| Tests | [`Mox`](https://hexdocs.pm/mox) + [`LazyHTML`](https://hexdocs.pm/lazy_html) | Mocks de puertos + assertions HTML |
| Observabilidad | [`telemetry_metrics`](https://hexdocs.pm/telemetry_metrics) + [`telemetry_poller`](https://hexdocs.pm/telemetry_poller) | Métricas internas (`lib/alethea/telemetry/`) |
| Canal paciente | **Telegram Bot API** (único) | Puerto transitorio vía `Alethea.Telegram.Client.*` |

### Estructura del proyecto

```
lib/
├── alethea/
│   ├── accounts/          # Profesionales, pacientes (identidad por alias), sesiones programadas
│   ├── clinical/          # Mensajes, emociones, tendencias, resúmenes, sesiones clínicas
│   ├── foundation/        # Identidad Telegram del paciente, KEK, onboarding, outbound dead-letter
│   ├── telegram/          # Puerto de Telegram: client, bot_token, deep_link, pacer, chat_id_hash, log_redactor
│   ├── ai/                # PhiWorker, RoBERTaWorker, Whisper, Embeddings, LLM, chains/, sanitizer, structured_output
│   ├── alerts/            # CrisisMonitor (detección determinista de crisis)
│   ├── encryption/        # Cloak + helpers
│   ├── jobs/              # TelegramMessageWorker, TelegramOnboardingWorker
│   └── telemetry/         # Métricas
├── alethea_jobs/          # Oban workers: emotion_analysis, session_reminder, session_timeout, daily_scheduler, weekly_report
└── alethea_web/           # Router, LiveViews, controllers (incluye webhook de Telegram)
```

### Estado del RAG y grafo

- **pgvector**: declarado en `mix.exs` y previsto en la migración `20260526141108`, pero la columna `messages.embedding vector(384)` **requiere instalación manual** de la extensión en el servidor PostgreSQL (es un `ALTER TABLE` separado, no parte del `mix ecto.migrate`). Hasta que se ejecute, el RAG opera solo en metadata textual.
- **Neo4j**: no presente en `lib/`. La mención inicial en versiones tempranas del PRD como "mapeo de grafos de conducta verbal" no tiene implementación en el MVP.

---

## Seguridad y Privacidad

- **Soberanía de datos:** cifrado en reposo con `Cloak.Ecto` (AES-256-GCM). Cada paciente tiene su propia **DEK** (data encryption key) envuelta por una **KEK** (key encryption key) almacenada en `lib/alethea/foundation/encryption/`. Al destruir la DEK, todos los mensajes del paciente se vuelven irrecuperables sin necesidad de borrado físico (**borrado criptográfico**).
- **Identidad Telegram opaca:** `telegram_chat_id_hash = HMAC-SHA256(chat_id, pepper)`. El pepper es rotable (`mix alethea.telegram.rotate_pepper`, ver [ADR-008](openspec/adr/008-telegram-chat-id-pepper-rotation.md)); un dump de la BD no permite correlacionar `telegram_chat_id_hash` con el `chat_id` real.
- **Protección de vectores:** los embeddings se tratan como PII sensible, con el mismo rigor que el texto plano para evitar ataques de inversión.
- **Auditoría clínica:** registro estricto de accesos y modificaciones (`lib/alethea/accounts/audit_log.ex`) para que la "Verdad Clínica" siempre sea trazable al origen.
- **Interfaz:** dashboard diseñado exclusivamente para **Light Mode** para asegurar legibilidad en entornos clínicos.
- **Aislamiento por tenant:** cada psicólogo aísla los datos de sus pacientes (ver [`openspec/UBIQUITOUS_LANGUAGE.md`](openspec/UBIQUITOUS_LANGUAGE.md) — *Tenant*).

---

## Principios Éticos y de IA

- **IA de personalidad deficiente:** el bot mantiene un tono clínico y neutro — definido por configuración por el profesional — para evitar el "Atrapamiento de Transferencia" y preservar el vínculo humano con el terapeuta. La personalidad es modificable por paciente.
- **Seguridad determinista:** filtro de "banderas rojas" por patrones configurables (`lib/alethea/alerts/crisis_monitor.ex`) que opera **en paralelo** a la IA para detección inmediata de crisis, sin depender de la "intuición" del modelo. La crisis bypasea la cola normal de Telegram y se enruta por `telegram_outbound_crisis` con prioridad alta.
- **Triggers como materialización del principio determinista:** los **triggers pasivos** (configurables por el profesional) permiten definir condiciones explícitas que modulan la respuesta de la IA; los **triggers activos** y **recurrentes** ejecutan acciones programadas (recordatorios, preguntas en fecha X, check-ins periódicos). El profesional mantiene el control sobre el comportamiento del bot sin tener que confiar en la "intuición" del modelo.
- **Transparencia de fuente:** cada hallazgo o nodo del grafo incluye un enlace directo al mensaje original o al audio (Whisper) para evitar el sesgo de automatización.
- **Matiz acústico:** la transcripción de sesiones con Whisper conserva metadatos prosódicos para no perder la carga emocional del lenguaje no verbal.
- **El paciente solo ve su conversación:** regla dura. Alethea no le muestra al paciente análisis emocional, psicometría, crisis pasadas ni diagnósticos, ni siquiera si pregunta — deriva al espacio clínico.

### Lo que Alethea NO es

- No es un servicio de intervención en crisis.
- No diagnostica de forma autónoma ni genera juicios clínicos finales.
- No sustituye el juicio ni la supervisión activa del profesional.

---

## Estado de Seguridad

### Implementado

- Cifrado **AES-256-GCM** con envelope encryption (DEK por paciente envuelta por KEK).
- `pbkdf2_elixir` para hashing de passwords.
- **HMAC-SHA256(chat_id, pepper)** para `telegram_chat_id_hash`, con pepper rotable.
- Protección CSRF en sesiones (estándar Phoenix).
- Auditoría de accesos PII (`lib/alethea/accounts/audit_log.ex`).
- Rate Limiting basado en ETS (`lib/alethea/telegram/pacer.ex`).
- Sanitización de PII antes de enviar a LLM (`lib/alethea/ai/sanitizer.ex`).
- Detección de crisis con patrones configurables (`lib/alethea/alerts/crisis_monitor.ex`).
- Cola dedicada `telegram_outbound_crisis` con prioridad más alta (bypass de la cola normal para crisis).
- Consentimiento GDPR (flujo explícito de aceptación).
- Whisper para transcripción de voz de sesiones.
- RoBERTa local para análisis emocional.
- Phi-4 mini para conversación guiada.
- Aislamiento de datos por tenant (psicólogo).

### Pendiente (v2)

- MFA/TOTP para profesionales (schema preparado, flujo pendiente).
- Rotación de **KEK** (criptográfica).
- Activación de **pgvector** en el servidor PostgreSQL + columna `vector(384)` en `messages` (RAG semántico).
- Dashboard de visualización de la historia clínica navegable (RAG como NotebookLM).
- Sistema de triggers pasivos / activos / recurrentes en producción (diseñado en PRD, pendiente de implementación bajo SDD).

---

## Roadmap de Desarrollo

El roadmap vivo se publica y mantiene como **SDD (Spec-Driven Development)** dentro de [`openspec/sdd/`](openspec/sdd/). Cada cambio sigue el flujo proposal → spec → design → tasks → apply → verify → archive sobre OpenSpec, con TDD estricto por task.

### Cambios activos

1. **telegram-paciente-foundation** — identidad Telegram del paciente, onboarding vía deep-link, outbound con dead-letter.
2. **telegram-safe-path-ai-reply** — respuesta de IA sobre el *safe path* (sin crisis) desacoplada en un `PhiWorker` compartible.
3. **retire-whatsapp-patient-identity (#107)** — cierre del modelo `whatsapp_number_hash` / `encrypted_whatsapp_number` en `Accounts.Patient` ahora que la identidad Telegram es la fuente de verdad.

### Próximos hitos (orden tentativo)

1. Activación de **pgvector** + embeddings HF para habilitar RAG semántico.
2. Implementación del sistema de **triggers** (pasivos / activos / recurrentes) — PR7–PR9 del PRD.
3. Vista **NotebookLM** (chat sobre datos del paciente) — PR6 del PRD.
4. Auditoría de seguridad final + cumplimiento normativo.

> Las iteraciones "1–6" de versiones tempranas del roadmap (mensajería base, RAG protegido, RAG de voz, triggers deterministas, analítica avanzada, auditoría final) siguen siendo válidas como roadmap conceptual pero el **estado real se traza ticket por ticket** en los SDDs de `openspec/sdd/`.

---

## Despliegue

El proyecto incluye una configuración de producción en `docker-compose.prod.yml` y una plantilla de entorno en `.env.example`.

1. Copiar y completar la plantilla:

   ```bash
   cp .env.example .env
   ```

   Generar los secretos requeridos:

   ```bash
   mix phx.gen.secret                                                  # SECRET_KEY_BASE
   mix run -e 'IO.puts(Base.encode64(:crypto.strong_rand_bytes(32)))' # CLOAK_AES_KEY
   mix run -e 'IO.puts(Base.encode64(:crypto.strong_rand_bytes(32)))' # pepper para telegram_chat_id_hash
   ```

2. Registrar el **bot de Telegram** en la base de datos. El sistema **no** lee el token desde variables de entorno: los valores sellados (token y `secret_token` para el header `X-Telegram-Bot-Api-Secret-Token`) se almacenan cifrados en la tabla `foundation_bot_configs` y se sirven en runtime por `Alethea.Telegram.BotToken` (un GenServer que levanta el plaintext al boot). Para el primer deploy:

   ```elixir
   Alethea.Foundation.Accounts.BotConfig.upsert(%{
     env: "prod",
     bot_token: System.fetch_env!("TELEGRAM_BOT_TOKEN"),
     secret_token: System.fetch_env!("TELEGRAM_WEBHOOK_SECRET_TOKEN"),
     bot_username: "alethea_prod_bot"
   })
   ```

   Las variables `TELEGRAM_BOT_TOKEN` y `TELEGRAM_WEBHOOK_SECRET_TOKEN` se leen **solo al seed** desde el entorno, luego el sistema las sirve desde el GenServer. Esto cumple con [REQ-C6-no-plaintext-in-env](lib/alethea/telegram/bot_token.ex).

   Configurar el webhook público HTTPS apuntando a `POST /webhooks/telegram/` (validado por `AletheaWeb.Plugs.TelegramSecretToken`).

3. Configurar los **proveedores de IA** según [Configuración opcional de IA](#configuración-opcional-de-ia) (Groq, Hugging Face, Ollama local).

4. Ejecutar el compose de producción:

   ```bash
   docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d
   ```

Consulta `.env.example` para el detalle de cada variable (base de datos, cifrado, IA, etc.).

---

## Comandos útiles

| Comando | Descripción |
| --- | --- |
| `mix setup` | Instala dependencias, crea la BD, migra y corre los seeds |
| `mix ecto.reset` | Elimina y recrea la BD desde cero |
| `mix test` | Crea/migra la BD de test y ejecuta la suite |
| `mix precommit` | Verificación completa: compilación con warnings como errores, formato y tests |
| `mix format` | Formatea el código del proyecto |
| `mix assets.deploy` | Regenera los assets estáticos (requiere `npm install --prefix assets`) |
| `mix alethea.telegram.rotate_pepper --reason="..."` | Rota el pepper de `telegram_chat_id_hash` y resetea los hashes (requiere re-onboarding de los pacientes) — ver [ADR-008](openspec/adr/008-telegram-chat-id-pepper-rotation.md) |

---

Este proyecto se desarrolla en cumplimiento de los requisitos académicos de la materia Proyecto Final.
