# Issue 003: Integración con Meta API e IA de Reflexión

**Type**: HITL (Requiere tokens de Meta WhatsApp API)
**Blocked by**: issues/002-onboarding-whatsapp-consentimiento.md
**User Stories Covered**: 5

## Description

Completar el pipeline clínico completo: validar la seguridad del webhook de Meta, construir el contexto de conversación desde la DB, invocar a Phi-4 mini via LangChain, y persistir tanto el mensaje entrante como la respuesta de la IA con trazabilidad completa.

## Decisiones de Diseño

| Decisión | Elección | Justificación |
|---|---|---|
| Validación de firma `X-Hub-Signature-256` | Implementar en esta issue en `WhatsappWebhookController` | Es seguridad perimetral; no puede esperar a tener un staging real |
| Arquitectura del pipeline | Un solo `ProcessMessageWorker` ejecuta todo el flujo secuencialmente | Menor latencia que un segundo job; la IA es suficientemente rápida en el caso de Phi-4 mini |
| Backend de Phi-4 mini | `ChatOpenAI` con `endpoint_url` configurable vía `OPENAI_BASE_URL` | Dev → Groq/Azure (Phi-4 mini gratuito); Prod → Ollama local. Cero cambios de código entre entornos |
| Contexto de conversación | Últimos N mensajes descifrados del paciente concatenados en el system prompt — N configurable (`app env`), default 10 | Provee continuidad clínica sin enviar el historial completo al LLM |
| System Prompt | Almacenado en `config/config.exs`, leído con `Application.get_env/2` | Patrón ya establecido en `GuidedConversationChain`; ajustable sin recompilación (runtime.exs) |
| Persistencia en DB | 3 registros por interacción: `Message` inbound (`spontaneous`), `Message` outbound (`elicited`), `AIDiagnosis` del chain | Trazabilidad completa (Source Anchoring del GEMINI.md); `AIDiagnosis.message_id` apunta al mensaje inbound |
| `behavior_type` | Campo string `"spontaneous"` / `"elicited"` en `messages`, asignado en el worker al guardar | Cumple el mandato de trazabilidad del GEMINI.md |
| Tests | Tests unitarios con `Mox` (mockear `PhiWorker` y `WhatsApp.Client`) | Aísla el pipeline del LLM real y de la API de Meta; rápidos y deterministas |

## Flujo Completo del Pipeline (rama `terms_accepted: true`)

```
ProcessMessageWorker.perform/1
  ├── 1. Guardar Message inbound (cifrado con DEK, direction: "inbound", behavior_type: "spontaneous")
  ├── 2. Cargar últimos N mensajes del paciente → descifrar con DEK → construir patient_context
  ├── 3. Sanitizer.sanitize(texto_entrante)
  ├── 4. PhiWorker.process(%{message_id: inbound_id, raw_content: texto, patient_context: ctx})
  │         └── GuidedConversationChain.run/1 → LLM (Phi-4 mini via OpenAI-compatible API)
  ├── 5. Guardar Message outbound (cifrado con DEK, direction: "outbound", behavior_type: "elicited")
  ├── 6. Guardar AIDiagnosis (message_id: inbound_id, model_version, extracted_emotions: %{}, ai_response)
  └── 7. WhatsApp.Client.send_message(phone, respuesta_ia)
```

## Tasks

### Migración
- [ ] Generar migración `add_behavior_type_to_messages` con:
  - `alter table(:messages)`: añadir `behavior_type` (`:string`, null: `false`, default: `"spontaneous"`)
  - Crear check constraint: `behavior_type IN ('spontaneous', 'elicited')`

### Schema y Contexto Clínico
- [ ] Añadir `behavior_type` al schema de `Alethea.Clinical.Message` y al changeset
- [ ] Añadir `Alethea.Clinical.list_recent_messages(patient_id, limit)` al contexto clinical — query ordenada por `timestamp DESC`, limit configurable, con preload vacío (solo los campos necesarios para descifrado)
- [ ] Crear `Alethea.Clinical` context module (`lib/alethea/clinical.ex`) si no existe, o añadir la función al módulo existente

### Seguridad del Webhook
- [ ] Actualizar `WhatsappWebhookController.receive/2` para validar `X-Hub-Signature-256`:
  - Leer el header `x-hub-signature-256` de la request
  - Comparar con `HMAC-SHA256(app_secret, raw_body)` usando `:crypto.mac/4`
  - Si falla: responder HTTP 403 inmediatamente, sin encolar job
  - `WHATSAPP_APP_SECRET` se añade a las variables de entorno en `config/runtime.exs`
  - **Nota**: Phoenix parsea el body antes de llegar al controlador; se necesita un Plug custom (`CacheBodyReader`) que preserve el raw body en `conn.assigns` para poder calcular el HMAC

### Configuración del LLM
- [ ] Añadir a `config/config.exs` el System Prompt completo con los "No Negociables":
  ```elixir
  config :alethea, Alethea.AI.Chains.GuidedConversationChain,
    model: "phi-4-mini",
    system_prompt: """
    Eres un asistente clínico de apoyo. Tu única función es escuchar y formular
    preguntas exploratorias con tono socrático.
    PROHIBIDO: emitir diagnósticos, validar o refutar pensamientos del paciente,
    dar consejos médicos directos o sugerir tratamientos.
    Si el paciente expresa riesgo de daño propio o a terceros, responde únicamente:
    "Entiendo que estás pasando por algo muy difícil. Por favor contacta a tu
    terapeuta o llama al 600 360 7777 (Salud Responde Chile)."
    """
  ```
- [ ] Añadir a `config/runtime.exs`:
  ```elixir
  config :alethea, Alethea.AI.Chains.GuidedConversationChain,
    endpoint_url: System.get_env("OPENAI_BASE_URL", "https://api.openai.com/v1"),
    api_key: System.get_env("OPENAI_API_KEY", "")

  config :alethea, :whatsapp,
    app_secret: System.get_env("WHATSAPP_APP_SECRET", "")
  ```

### AI Chain — Contexto de Conversación
- [ ] Actualizar `GuidedConversationChain.run/1` para:
  - Leer `system_prompt` y `endpoint_url` desde `Application.get_env/2`
  - Construir el system prompt interpolando el `patient_context` (historial de N mensajes)
  - Mantener `behavior_type: :elicited` en el resultado del chain

### Worker Oban — Pipeline Clínico Completo
- [ ] Actualizar `AletheaJobs.ProcessMessageWorker.perform/1`, rama `terms_accepted: true`:
  1. `Clinical.save_message(patient, text, dek, "inbound", "spontaneous")` → `{:ok, inbound_msg}`
  2. `Clinical.list_recent_messages(patient.id, limit)` → descifrar con DEK → `patient_context` string
  3. `PhiWorker.process(%{message_id: inbound_msg.id, raw_content: text, patient_context: patient_context})`
  4. `Clinical.save_message(patient, response, dek, "outbound", "elicited")` → `{:ok, _outbound_msg}`
  5. `Clinical.save_ai_diagnosis(inbound_msg.id, chain_result)` → `{:ok, _diagnosis}`
  6. `WhatsApp.Client.send_message(phone, response)`

### Plug — Raw Body Preservation (para HMAC)
- [ ] Crear `lib/alethea_web/plugs/cache_body_reader.ex` con un Plug que guarda el raw body en `conn.assigns.raw_body` antes de que Phoenix lo parsee
- [ ] Configurar el endpoint (`endpoint.ex`) para usar `CacheBodyReader` solo en la ruta `/webhooks/whatsapp`

### Tests
- [ ] Actualizar `test/alethea_jobs/process_message_worker_test.exs` con test del pipeline completo:
  - `terms_accepted: true` → mockear `PhiWorker` y `WhatsApp.Client.send_message`; verificar que se crean 2 `Message` y 1 `AIDiagnosis` en DB
- [ ] Crear `test/alethea_web/controllers/whatsapp_webhook_controller_test.exs`:
  - Firma válida → encola job, devuelve 200
  - Firma inválida → devuelve 403, no encola job
  - Sin header de firma → devuelve 403

## Archivos Involucrados

| Acción | Archivo |
|---|---|
| NEW (migración) | `priv/repo/migrations/<ts>_add_behavior_type_to_messages.exs` |
| MODIFY | `lib/alethea/clinical/message.ex` |
| NEW/MODIFY | `lib/alethea/clinical.ex` (context con `save_message/5`, `list_recent_messages/2`, `save_ai_diagnosis/2`) |
| MODIFY | `lib/alethea/ai/chains/guided_conversation_chain.ex` |
| MODIFY | `lib/alethea_jobs/process_message_worker.ex` |
| MODIFY | `lib/alethea_web/controllers/whatsapp_webhook_controller.ex` |
| NEW | `lib/alethea_web/plugs/cache_body_reader.ex` |
| MODIFY | `lib/alethea_web/endpoint.ex` |
| MODIFY | `config/config.exs` |
| MODIFY | `config/runtime.exs` |
| MODIFY | `test/alethea_jobs/process_message_worker_test.exs` |
| NEW | `test/alethea_web/controllers/whatsapp_webhook_controller_test.exs` |

## Notas

- **`OPENAI_BASE_URL` en dev**: Groq Cloud (`https://api.groq.com/openai/v1`) ofrece `llama-3.3-70b-versatile` o `meta-llama/llama-4-scout` gratis. Para Phi-4 mini específicamente, usar Azure AI Foundry o Together.ai. En prod, Ollama en el mismo servidor con `http://localhost:11434/v1` y `api_key: "ollama"`.
- **Raw body y HMAC**: Phoenix consume el body al parsearlo. El `CacheBodyReader` debe configurarse **antes** del parser JSON en el endpoint para que el raw body esté disponible. Es un patrón estándar documentado en la guía de seguridad de Phoenix.
- **`extracted_emotions` en `AIDiagnosis`**: En esta issue se guarda como `%{}` vacío. El análisis de sentimiento con RoBERTa (Bumblebee) que lo rellena es parte de la issue de monitoreo de crisis o dashboard.
- **Idempotencia**: el worker debe evitar guardar mensajes duplicados si Oban reintenta. Añadir una clave de unicidad usando el `wamid` (WhatsApp Message ID) del payload de Meta como campo único en `messages`.
