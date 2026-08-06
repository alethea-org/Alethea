# Alethea

Diario interactivo y sensor de conducta verbal para la continuidad terapéutica.

[![Elixir](https://img.shields.io/badge/Elixir-1.19-4b275f?logo=elixir&logoColor=white)](https://elixir-lang.org)
[![OTP](https://img.shields.io/badge/OTP-28-4b275f?logo=erlang&logoColor=white)](https://www.erlang.org)
[![Phoenix](https://img.shields.io/badge/Phoenix-1.8-FD4F00?logo=phoenixframework&logoColor=white)](https://www.phoenixframework.org)
[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-15-336791?logo=postgresql&logoColor=white)](https://www.postgresql.org)
[![Redis](https://img.shields.io/badge/Redis-7-DC382D?logo=redis&logoColor=white)](https://redis.io)
[![CI](https://github.com/alethea-org/Alethea/actions/workflows/elixir.yml/badge.svg)](https://github.com/alethea-org/Alethea/actions)

## Tabla de Contenidos

- [Visión del Proyecto](#visión-del-proyecto)
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

A diferencia del journaling manual, el producto simplifica el registro mediante una conversación guiada vía WhatsApp, permitiendo al profesional expandir su visión diagnóstica con datos ya organizados para la sesión.

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

El compose levanta la aplicación, PostgreSQL y Redis.

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

En desarrollo **no** se requieren credenciales externas: el cliente de mensajería y la IA usan implementaciones Fake. Solo se activan proveedores reales si se configuran:

- **LLM local (Phi-4 mini):** instala [Ollama](https://ollama.com) y usa `LOCAL_LLM_BASE_URL=http://localhost:11434/v1`. El modelo por defecto se define con `LLM_MODEL` (default `phi-4-mini`).
- **RoBERTa (análisis de emociones):** define `HUGGINGFACE_API_KEY` para usar la API de Hugging Face.

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

Monolito Modular bajo **Arquitectura Hexagonal**, priorizando la soberanía de los datos y la resiliencia clínica.

| Capa | Tecnología | Propósito |
| --- | --- | --- |
| Backend | [Phoenix (Elixir)](https://phoenixframework.org/) | Alta concurrencia y gestión de estado en tiempo real |
| IA | [LangChain](https://github.com/elixir-langchain/langchain) + **RoBERTa** (análisis de sentimiento local, `Nx/Bumblebee`) + **Phi-4 mini** (conversación guiada) | Orquestación de IA |
| Bases de datos | **PostgreSQL + pgvector** | Almacenamiento principal y búsqueda semántica de vectores |
|  | **Neo4j** | Mapeo de grafos de conducta verbal (probabilístico, pendiente de verificación clínica) |
| Infraestructura | **WhatsApp Business API** | Puerto transitorio (sin persistencia en el proveedor) |
|  | **Oban** | Procesamiento asíncrono y patrón de Recibo Transaccional |

---

## Seguridad y Privacidad

- **Soberanía de datos:** cifrado en reposo con `Cloak.Ecto` (AES-256). Llaves específicas por paciente que permiten el **borrado criptográfico** al finalizar el proceso terapéutico.
- **Protección de vectores:** los embeddings se tratan como PII sensible, con el mismo rigor que el texto plano para evitar ataques de inversión.
- **Auditoría clínica:** registro estricto de accesos y modificaciones para que la "Verdad Clínica" siempre sea trazable al origen.
- **Interfaz:** dashboard diseñado exclusivamente para **Light Mode** para asegurar legibilidad en entornos clínicos.

---

## Principios Éticos y de IA

- **IA de personalidad deficiente:** el bot mantiene un tono clínico y neutro para evitar el "Atrapamiento de Transferencia" y preservar el vínculo humano con el terapeuta.
- **Seguridad determinista:** filtro de "banderas rojas" por palabras clave que opera en paralelo a la IA para detección inmediata de crisis, sin depender de la "intuición" del modelo.
- **Transparencia de fuente:** cada hallazgo o nodo del grafo incluye un enlace directo al mensaje original o al audio (Whisper) para evitar el sesgo de automatización.
- **Matiz acústico:** la transcripción de sesiones incluye metadatos de prosodia (silencios, tono, velocidad) para no perder la carga emocional del lenguaje no verbal.

### Lo que Alethea NO es

- No es un servicio de intervención en crisis.
- No diagnostica de forma autónoma ni genera juicios clínicos finales.
- No sustituye el juicio ni la supervisión activa del profesional.

---

## Estado de Seguridad

### Implementado

- Cifrado AES-256-GCM con envelope encryption (DEK por usuario)
- PBKDF2 para passwords
- HMAC-SHA256 para hashing de números telefónicos
- Protección CSRF en sesiones
- Auditoría de accesos PII
- Rate Limiting basado en ETS
- Sanitización de PII antes de enviar a LLM
- Detección de crisis con patrones configurables
- Consentimiento GDPR (flujo explícito de aceptación)

### Pendiente (v2)

- MFA/TOTP para profesionales (schema preparado, flujo pendiente)
- Rotación de KEK (criptográfica)
- pgvector para RAG semántico
- Neo4j para grafo de conducta
- Whisper para transcripción de voz

---

## Roadmap de Desarrollo

1. **Iteración 1:** Core de mensajería (WhatsApp asíncrono) + cifrado base (`Cloak.Ecto`).
2. **Iteración 2:** RAG protegido y dashboard de visualización inicial.
3. **Iteración 3:** RAG de voz (Whisper) con integración de matices acústicos.
4. **Iteración 4:** Triggers deterministas y detección de patrones de riesgo.
5. **Iteración 5:** Analítica avanzada y exportación portabilidad de datos.
6. **Iteración 6:** Auditoría de seguridad final y cumplimiento normativo.

---

## Despliegue

El proyecto incluye una configuración de producción en `docker-compose.prod.yml` y una plantilla de entorno en `.env.example`.

1. Copiar y completar la plantilla:

   ```bash
   cp .env.example .env
   ```

   Generar los secretos requeridos:

   ```bash
   mix phx.gen.secret                    # SECRET_KEY_BASE
   mix run -e 'IO.puts(Base.encode64(:crypto.strong_rand_bytes(32)))'  # CLOAK_AES_KEY
   ```

2. Ejecutar el compose de producción:

   ```bash
   docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d
   ```

Consulta `.env.example` para el detalle de cada variable (base de datos, cifrado, WhatsApp Business API, IA, etc.).

---

## Comandos útiles

| Comando | Descripción |
| --- | --- |
| `mix setup` | Instala dependencias, crea la BD, migra y corre los seeds |
| `mix ecto.reset` | Elimina y recrea la BD desde cero |
| `mix test` | Crea/migra la BD de test y ejecuta la suite |
| `mix precommit` | Verificación completa: compilación con warnings como errores, formato y tests |
| `mix format` | Formatea el código del proyecto |

---

Este proyecto se desarrolla en cumplimiento de los requisitos académicos de la materia Proyecto Final.