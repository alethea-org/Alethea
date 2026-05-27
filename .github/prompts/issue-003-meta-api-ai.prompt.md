---
description: "Issue 003 — Integración con Meta Graph API y configuración del núcleo de IA conversacional"
---

# Issue 003: Integración con Meta API e IA de Reflexión

Establece la comunicación real con WhatsApp via Meta Graph API y configura el
núcleo de IA conversacional (Phi-4 via LangChain) con restricciones clínicas.

## Contexto

- **Bloqueado por**: Issue 002
- **Type**: HITL (requiere tokens de Meta WhatsApp API reales para producción)
- **User Story**: 5 (IA empática con preguntas abiertas)
- **Módulos clave**: `Alethea.WhatsApp.Client`, `Alethea.AI.Chains.GuidedConversationChain`

## Tareas a Implementar

### 1. Cliente HTTP con `Req` para Meta API

**USAR `Req` — NO `HTTPoison` ni `Tesla`**

```elixir
defmodule Alethea.WhatsApp.Client do
  @base_url "https://graph.facebook.com/v19.0"

  def send_text_message(to_phone, text) do
    phone_number_id = System.fetch_env!("WHATSAPP_PHONE_NUMBER_ID")
    token           = System.fetch_env!("WHATSAPP_API_TOKEN")

    case Req.post("#{@base_url}/#{phone_number_id}/messages",
           auth: {:bearer, token},
           json: %{
             messaging_product: "whatsapp",
             to: to_phone,
             type: "text",
             text: %{body: text}
           }
         ) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: status, body: body}} -> {:error, {status, body}}
      {:error, reason} -> {:error, reason}
    end
  end
end
```

### 2. Variables de Entorno

En `config/runtime.exs`:

```elixir
config :alethea, :whatsapp,
  api_token:       System.fetch_env!("WHATSAPP_API_TOKEN"),
  phone_number_id: System.fetch_env!("WHATSAPP_PHONE_NUMBER_ID"),
  webhook_secret:  System.fetch_env!("WHATSAPP_WEBHOOK_SECRET")
```

Documentar en `.env.example`:
```
WHATSAPP_API_TOKEN=
WHATSAPP_PHONE_NUMBER_ID=
WHATSAPP_WEBHOOK_SECRET=
```

### 3. Validación de Firma del Webhook

```elixir
defmodule AletheaWeb.Plugs.VerifyWhatsAppSignature do
  import Plug.Conn

  def call(conn, _opts) do
    signature = get_req_header(conn, "x-hub-signature-256") |> List.first("") |> String.replace_prefix("sha256=", "")
    secret    = Application.fetch_env!(:alethea, [:whatsapp, :webhook_secret])
    raw_body  = conn.assigns[:raw_body] || ""

    expected = :crypto.mac(:hmac, :sha256, secret, raw_body) |> Base.encode16(case: :lower)

    if Plug.Crypto.secure_compare(expected, signature) do
      conn
    else
      conn |> send_resp(403, "Forbidden") |> halt()
    end
  end
end
```

### 4. System Prompt Clínico (Phi-4 via LangChain)

**Restricciones de las "Líneas Rojas":**
- Prohibición absoluta de diagnóstico médico
- Sin consejos terapéuticos directos
- Tono socrático y escucha activa

```elixir
defp clinical_system_prompt(patient_context) do
  """
  Eres Alethea, un asistente de apoyo emocional. Tu rol es EXCLUSIVAMENTE:
  - Escuchar activamente y validar emociones (no pensamientos distorsionados)
  - Hacer preguntas exploratorias abiertas para profundizar en la experiencia
  - Fomentar la reflexión sin juzgar ni dirigir

  PROHIBICIONES ABSOLUTAS:
  - No emitas diagnósticos de ningún tipo
  - No des consejos médicos ni terapéuticos directos
  - No valides ni refutes distorsiones cognitivas sin autorización explícita del terapeuta
  - No tomes decisiones clínicas

  Contexto del paciente: #{inspect(patient_context)}
  """
end
```

### 5. Integrar en Worker de Oban

El worker llama a `GuidedConversationChain.run/1` SOLO después de pasar por `CrisisMonitor`
y `Sanitizer.sanitize/1`.

## Tests

- Mockear `Req` con `Req.Test` para simular respuestas de Meta API
- Verificar que la firma inválida retorna 403
- Verificar que el System Prompt no contiene frases de diagnóstico

## Checklist

- [ ] `Alethea.WhatsApp.Client` usa `Req` exclusivamente
- [ ] Variables de entorno en `config/runtime.exs` con `fetch_env!/1`
- [ ] `.env.example` documentado
- [ ] Validación `X-Hub-Signature-256` antes de cualquier procesamiento del webhook
- [ ] System Prompt cumple las Líneas Rojas clínicas
- [ ] Worker Oban orquesta: CrisisMonitor → Sanitizer → LangChain
- [ ] Tests mockean Meta API con `Req.Test`
- [ ] `mix precommit` pasa limpio
