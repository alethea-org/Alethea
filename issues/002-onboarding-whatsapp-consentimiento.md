# Issue 002: Onboarding de WhatsApp y Consentimiento

**Type**: AFK
**Blocked by**: None (Accounts and Crypto Contracts / Contract-Driven Development)
**User Stories Covered**: 4

## 🤝 Contrato de Paralelización (Contract-Driven Development)

Para desacoplar esta issue del desarrollo de la Bóveda Segura (Issue 001) y permitir el trabajo concurrente del equipo, establecemos contratos explícitos de interfaces en Elixir.

### Contrato Criptográfico: `Alethea.Encryption.PatientVaultBehavior`
Para aislar la lógica del webhook del motor criptográfico real, definimos la interfaz del Vault de Pacientes:
```elixir
defmodule Alethea.Encryption.PatientVaultBehavior do
  @callback encrypt_for_patient(binary(), binary()) :: {:ok, binary()} | {:error, any()}
  @callback decrypt_for_patient(binary(), binary()) :: {:ok, binary()} | {:error, any()}
end
```

### Contrato de Cuentas: Stubs en `Alethea.Accounts`
En `lib/alethea/accounts.ex`, creamos inicialmente las firmas de funciones vacías o stubs que simulan la interacción con la base de datos:
```elixir
defmodule Alethea.Accounts do
  # Stub para lookup de paciente por teléfono normalizado
  def lookup_patient_by_phone(phone_e164) do
    # Durante el desarrollo paralelo, si Issue 001 no está lista,
    # este stub puede retornar un paciente mock guardado en memoria/ETS
    # o una estructura fija con 'terms_accepted: false' para pruebas.
    case phone_e164 do
      "+56912345678" -> 
        {:ok, %Alethea.Accounts.Patient{
          id: "11111111-1111-1111-1111-111111111111", 
          alias: "Paciente Mock", 
          terms_accepted: false,
          encryption_key_id: "key-123"
        }}
      _ -> 
        {:error, :not_found}
    end
  end

  # Stub para actualizar el estado del consentimiento legal
  def update_patient_terms(patient, accepted?) do
    {:ok, %{patient | terms_accepted: accepted?}}
  end
end
```
Esto permite al desarrollador de WhatsApp escribir y probar 100% de la lógica del webhook y el Oban worker (`ProcessMessageWorker`) con datos mockeados en local sin esperar a que la base de datos o el motor de Envelope Encryption real estén listos.

## Description

Manejar el primer contacto del paciente a través de WhatsApp. El sistema debe interceptar el primer mensaje, buscar al paciente por su número de teléfono y no procesar ni persistir ninguna información clínica hasta que el paciente acepte formalmente los términos legales.

## Decisiones de Diseño

| Decisión | Elección | Justificación |
|---|---|---|
| Punto de entrada del webhook | `WhatsappWebhookController` — responde HTTP 200 inmediato, encola Oban job | Desacopla la recepción del procesamiento; el webhook de Meta requiere respuesta rápida |
| Rutas del webhook | `GET /webhooks/whatsapp` (challenge de Meta), `POST /webhooks/whatsapp` (mensajes) | Convención estándar de Meta Graph API |
| Validación de firma `X-Hub-Signature-256` | **Diferido a issue 003** | Esta issue no tiene credenciales reales de Meta; la validación forma parte de la integración completa |
| Arquitectura de workers | Un solo `AletheaJobs.ProcessMessageWorker` que comprueba `terms_accepted` al inicio | Evita duplicar lógica de lookup; el worker es el coordinador de todo el pipeline |
| Lookup de paciente por teléfono | Búsqueda directa O(1) en la base de datos hasheando el número entrante con el secreto global (`phone_hash_secret`) | Resuelve el O(n) y permite al webhook (que no tiene la KEK del profesional) identificar al paciente al instante |
| Formato del mensaje de consentimiento | Texto libre (type: `'text'`) | Sin dependencia de aprobación de plantillas de Meta; compatible con cualquier cuenta Business |
| Detección de aceptación | Comparar `String.downcase(String.trim(texto))` contra `"acepto"` | Simple, inequívoco, sin ambigüedades de interpretación |
| Control de reintentos | Caché de "Consentimiento en Progreso" (TTL 1 min) vía `Alethea.WhatsApp.ConsentCache` | Evita saturar al paciente con el mensaje de términos si envía múltiples mensajes seguidos antes de aceptar |
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
                    ├── lookup_patient(número)  ← calcula `whatsapp_number_hash` con `phone_hash_secret` y busca por índice (O(1))
                    │     ├── {:error, :not_found} → send_message(número, "No estás registrado...") → :ok
                    │     └── {:ok, patient}
                    │           ├── terms_accepted: false
                    │           │     ├── texto == "acepto" → update terms_accepted=true, send_message("Bienvenido...")
                    │           │     └── texto != "acepto" → descartar, send_message(términos de nuevo)
                    │           └── terms_accepted: true → [procesamiento clínico — issue 003+]
```

## Tasks

### Migración
- [x] Generar migración `add_terms_accepted_to_patients`

### Schema y Contexto
- [x] Añadir `terms_accepted` al schema de `Alethea.Accounts.Patient`
- [x] Añadir `update_patient_terms/2` a `Alethea.Accounts`
- [x] Añadir `lookup_patient_by_phone(phone_e164)` a `Alethea.Accounts`

### Cliente WhatsApp
- [x] Crear `lib/alethea/whatsapp/consent_cache.ex`
- [x] Crear `lib/alethea/whatsapp/client.ex`
- [x] Añadir configuración placeholder en `config/runtime.exs`

### Web — Webhook Controller
- [x] Crear `lib/alethea_web/controllers/whatsapp_webhook_controller.ex`
- [x] Añadir rutas en `router.ex`

### Worker Oban
- [x] Crear `lib/alethea_jobs/process_message_worker.ex` (Logic cleanup & Warnings fix)

### Tests
- [x] Crear `test/alethea_jobs/process_message_worker_test.exs`
- [x] Crear `test/alethea_web/controllers/whatsapp_webhook_controller_test.exs` (Integration)
- [x] Ejecutar `mix test` y verificar.

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

- **Lookup O(1) Garantizado**: Al usar un secreto global del sistema para hashear el número (Issue 001), la búsqueda es instantánea y escalable.
- **Normalización E.164**: El número entrante del webhook de Meta ya viene en formato E.164 (ej. `5215512345678`). Verificar antes de calcular el HMAC que el formato es consistente con el almacenado en registro.
- **Idempotencia del worker**: Si Meta reintenta el webhook con el mismo mensaje, el worker debe ser seguro de re-ejecutar. El job de Oban usa el `message_id` del payload de Meta como clave de deduplicación en `unique: [fields: [:args]]`.
- **Texto de los términos**: El contenido del mensaje de consentimiento debe almacenarse en el config o en una constante del módulo, no hardcodeado inline, para facilitar revisión legal.
- **`Mox`**: Verificar que `mox` está en las dependencias de `:test`; si no, añadir `{:mox, "~> 1.0", only: :test}` en `mix.exs`.
