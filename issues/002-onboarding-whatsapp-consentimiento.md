# Issue 002: Onboarding de WhatsApp y Consentimiento

**Type**: AFK
**Blocked by**: issues/001-registro-pacientes-boveda-segura.md
**User Stories Covered**: 4

## Description

Manejar el primer contacto del paciente a través de WhatsApp. El sistema debe interceptar el primer mensaje, buscar al paciente por su número de teléfono y no procesar ni persistir ninguna información clínica hasta que el paciente acepte formalmente los términos legales.

## Decisiones de Diseño

| Decisión | Elección | Justificación |
|---|---|---|
| Punto de entrada del webhook | `WhatsappWebhookController` — responde HTTP 200 inmediato, encola Oban job | Desacopla la recepción del procesamiento; el webhook de Meta requiere respuesta rápida |
| Rutas del webhook | `GET /webhooks/whatsapp` (challenge de Meta), `POST /webhooks/whatsapp` (mensajes) | Convención estándar de Meta Graph API |
| Validación de firma `X-Hub-Signature-256` | **Diferido a issue 003** | Esta issue no tiene credenciales reales de Meta; la validación forma parte de la integración completa |
| Arquitectura de workers | Un solo `AletheaJobs.ProcessMessageWorker` que comprueba `terms_accepted` al inicio | Evita duplicar lógica de lookup; el worker es el coordinador de todo el pipeline |
| Lookup de paciente por teléfono | Iterar pacientes del profesional, descifrar cada DEK con el Vault global, recalcular HMAC y comparar con `whatsapp_number_hash` almacenado | Consecuencia de la decisión de issue 001: HMAC usa la DEK del paciente como clave, imposibilitando lookup directo |
| Formato del mensaje de consentimiento | Texto libre (type: `'text'`) | Sin dependencia de aprobación de plantillas de Meta; compatible con cualquier cuenta Business |
| Detección de aceptación | Comparar `String.downcase(String.trim(texto))` contra `"acepto"` | Simple, inequívoco, sin ambigüedades de interpretación |
| Mensajes previos al consentimiento | **Descartar sin guardar** + re-enviar mensaje de consentimiento | La transitoriedad de datos pre-consentimiento es un mandato del GEMINI.md |
| Número no registrado | Responder con mensaje genérico y terminar el job sin error | No guardar nada; evitar revelar información sobre otros pacientes |
| Cliente WhatsApp | Crear `Alethea.WhatsApp.Client` con `send_message/2` usando `Req` ya en esta issue | Evita reescribir el worker en issue 003; da estructura al módulo que 003 expandirá |
| Tests | Tests unitarios del worker con `Mox` para los 4 flujos del estado de consentimiento | Aísla el worker de la API real de Meta; rápidos y deterministas |

## Flujo de Procesamiento del Worker

```
POST /webhooks/whatsapp
  └── WhatsappWebhookController.receive/2
        └── Oban.insert(ProcessMessageWorker, %{from: número, text: texto})
              └── ProcessMessageWorker.perform/1
                    ├── lookup_patient(número)  ← itera pacientes, descifra DEKs, compara HMAC
                    │     ├── {:error, :not_found} → send_message(número, "No estás registrado...") → :ok
                    │     └── {:ok, patient}
                    │           ├── terms_accepted: false
                    │           │     ├── texto == "acepto" → update terms_accepted=true, send_message("Bienvenido...")
                    │           │     └── texto != "acepto" → descartar, send_message(términos de nuevo)
                    │           └── terms_accepted: true → [procesamiento clínico — issue 003+]
```

## Tasks

### Migración
- [ ] Generar migración `add_terms_accepted_to_patients` con:
  - `alter table(:patients)`: añadir `terms_accepted` (`:boolean`, default: `false`, null: `false`)

### Schema y Contexto
- [ ] Añadir `terms_accepted` al schema de `Alethea.Accounts.Patient` y al changeset
- [ ] Añadir `update_patient_terms/2` a `Alethea.Accounts` que actualiza `terms_accepted: true`
- [ ] Añadir `lookup_patient_by_phone(phone_e164)` a `Alethea.Accounts`:
  - Carga todos los pacientes de todos los profesionales (con sus `encryption_key_id`)
  - Para cada paciente: descifra la DEK del `EncryptionKey` usando `Alethea.Encryption.Vault.decrypt!/1`
  - Recalcula `HMAC-SHA256(dek_bytes, phone_e164)` y compara con `whatsapp_number_hash`
  - Retorna `{:ok, patient}` o `{:error, :not_found}`

### Cliente WhatsApp
- [ ] Crear `lib/alethea/whatsapp/client.ex` con `send_message(to_number, body_text)`:
  - Usa `Req.post/2` hacia `https://graph.facebook.com/v19.0/{PHONE_NUMBER_ID}/messages`
  - Cabecera `Authorization: Bearer {WHATSAPP_API_TOKEN}`
  - Payload: `%{messaging_product: "whatsapp", to: to_number, type: "text", text: %{body: body_text}}`
  - Credenciales leídas de `Application.get_env(:alethea, :whatsapp)` (configurado en `config/runtime.exs`)
- [ ] Añadir configuración placeholder en `config/runtime.exs`:
  ```elixir
  config :alethea, :whatsapp,
    api_token: System.get_env("WHATSAPP_API_TOKEN", ""),
    phone_number_id: System.get_env("WHATSAPP_PHONE_NUMBER_ID", "")
  ```

### Web — Webhook Controller
- [ ] Crear `lib/alethea_web/controllers/whatsapp_webhook_controller.ex`:
  - `verify/2` (`GET /webhooks/whatsapp`): responde al challenge de Meta (`hub.challenge`)
  - `receive/2` (`POST /webhooks/whatsapp`): extrae número y texto del payload JSON, encola `ProcessMessageWorker` y devuelve `json(conn, %{})` con HTTP 200
- [ ] Añadir rutas en `router.ex` bajo el pipeline `:api`:
  ```elixir
  scope "/webhooks", AletheaWeb do
    pipe_through :api
    get "/whatsapp", WhatsappWebhookController, :verify
    post "/whatsapp", WhatsappWebhookController, :receive
  end
  ```

### Worker Oban
- [ ] Crear `lib/alethea_jobs/process_message_worker.ex` (`AletheaJobs.ProcessMessageWorker`):
  - `use Oban.Worker, queue: :whatsapp, max_attempts: 3`
  - `perform(%Oban.Job{args: %{"from" => phone, "text" => text}})`:
    1. `Accounts.lookup_patient_by_phone(phone)` — ver flujo arriba
    2. Rama `:not_found`: `WhatsApp.Client.send_message(phone, mensaje_no_registrado)` → `:ok`
    3. Rama `terms_accepted: false`, texto != "acepto": `WhatsApp.Client.send_message(phone, texto_términos)` → `:ok`
    4. Rama `terms_accepted: false`, texto == "acepto" (case-insensitive + trim): `Accounts.update_patient_terms(patient, true)` + `WhatsApp.Client.send_message(phone, bienvenida)` → `:ok`
    5. Rama `terms_accepted: true`: no-op por ahora (issue 003 añade el pipeline clínico)

### Tests
- [ ] Crear `test/alethea_jobs/process_message_worker_test.exs` con 4 tests usando `Mox`:
  1. **Número desconocido**: `lookup_patient_by_phone` retorna `:not_found` → worker llama a `send_message` con mensaje genérico
  2. **Primer mensaje sin consentimiento**: paciente con `terms_accepted: false`, texto = "hola" → worker descarta, re-envía términos
  3. **Aceptación de términos**: paciente con `terms_accepted: false`, texto = "Acepto" → worker actualiza DB y envía bienvenida
  4. **Paciente con consentimiento activo**: paciente con `terms_accepted: true` → worker termina sin llamar a `send_message`

## Archivos Involucrados

| Acción | Archivo |
|---|---|
| NEW (migración) | `priv/repo/migrations/<ts>_add_terms_accepted_to_patients.exs` |
| MODIFY | `lib/alethea/accounts/patient.ex` |
| MODIFY | `lib/alethea/accounts.ex` |
| NEW | `lib/alethea/whatsapp/client.ex` |
| NEW | `lib/alethea_web/controllers/whatsapp_webhook_controller.ex` |
| MODIFY | `lib/alethea_web/router.ex` |
| NEW | `lib/alethea_jobs/process_message_worker.ex` |
| MODIFY | `config/runtime.exs` |
| NEW | `test/alethea_jobs/process_message_worker_test.exs` |

## Notas

- **Lookup O(n)**: El lookup iterando todos los pacientes es costoso a escala. Es aceptable para Iteración 1 con pocos pacientes. Una issue técnica futura debería añadir un índice secundario (ej. hash con salt fija de profesional) para lookup O(1), sin romper la privacidad cruzada.
- **Normalización E.164**: El número entrante del webhook de Meta ya viene en formato E.164 (ej. `5215512345678`). Verificar antes de calcular el HMAC que el formato es consistente con el almacenado en registro.
- **Idempotencia del worker**: Si Meta reintenta el webhook con el mismo mensaje, el worker debe ser seguro de re-ejecutar. El job de Oban usa el `message_id` del payload de Meta como clave de deduplicación en `unique: [fields: [:args]]`.
- **Texto de los términos**: El contenido del mensaje de consentimiento debe almacenarse en el config o en una constante del módulo, no hardcodeado inline, para facilitar revisión legal.
- **`Mox`**: Verificar que `mox` está en las dependencias de `:test`; si no, añadir `{:mox, "~> 1.0", only: :test}` en `mix.exs`.
