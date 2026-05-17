---
description: Crea un Oban Worker que orqueste el pipeline completo de IA (RoBERTa + LangChain)
mode: agent
---

# Prompt: Crear Oban Worker para el Pipeline de IA

Estás creando un **Oban Worker** en `lib/alethea_jobs/` que orquesta el pipeline
completo de procesamiento de IA de Alethea: sanitización → RoBERTa (sentimiento local)
→ LangChain/Phi-4 (conversación) → persistencia en `ai_diagnoses`.

## Por Qué Oban es Obligatorio

Todo procesamiento de IA en Alethea DEBE ejecutarse de forma asíncrona:
- La inferencia de IA es costosa (segundos a minutos)
- El proceso receptor de WhatsApp no debe bloquearse
- Oban garantiza reintentos ante fallos y trazabilidad de jobs

## Flujo del Pipeline de IA

```
WhatsApp Webhook
    ↓
[Alethea.Jobs.MessageReceiverWorker]
    ↓  (encola job)
[Alethea.Jobs.AIProcessingWorker]  ← Este worker
    ├── Alethea.AI.Sanitizer.sanitize/1
    ├── Alethea.AI.RobertaWorker.analyze_sentiment/1
    ├── Alethea.AI.PhiWorker.generate_response/1
    │       └── LLMChain con tools
    └── Persistir en ai_diagnoses
         └── Phoenix.PubSub.broadcast (notifica al LiveView)
```

## Tu Tarea

Crea el worker para el siguiente tipo de procesamiento:

**Procesamiento solicitado**: ${input:Describe el tipo de procesamiento de IA (ej. "pipeline completo de mensaje entrante", "re-análisis de sentimiento de mensajes históricos", "generación de resumen semanal del paciente")}

### Pasos a Seguir

1. **Crear el worker** en `lib/alethea_jobs/<nombre>_worker.ex`:

```elixir
defmodule Alethea.Jobs.<NombreWorker> do
  @moduledoc """
  Worker Oban para [descripción del procesamiento].
  """
  use Oban.Worker,
    queue: :ai_processing,
    max_attempts: 3,
    unique: [period: 60, fields: [:args]]

  alias Alethea.AI.Sanitizer
  alias Alethea.AI.RobertaWorker
  alias Alethea.AI.PhiWorker
  alias Alethea.Clinical

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"message_id" => message_id, "patient_id" => patient_id}}) do
    with {:ok, message} <- Clinical.get_message_with_content(message_id),
         {:ok, sanitized} <- Sanitizer.sanitize(message.content),
         {:ok, sentiment} <- RobertaWorker.analyze_sentiment(sanitized),
         {:ok, ai_result} <- PhiWorker.generate_response(%{
           sanitized_content: sanitized,
           sentiment: sentiment,
           patient_id: patient_id,
           message_id: message_id,
           behavior_type: message.behavior_type
         }),
         {:ok, _diagnosis} <- Clinical.save_ai_diagnosis(ai_result) do
      :ok
    else
      {:error, reason} ->
        {:error, reason}
    end
  end
end
```

2. **Configurar la cola Oban** (si no existe `ai_processing`) en `config/config.exs`:
   ```elixir
   config :alethea, Oban,
     queues: [
       default: 10,
       ai_processing: 5,  # Concurrencia limitada por recursos de GPU/CPU
       webhooks: 20
     ]
   ```

3. **Encolar el job** desde el contexto apropiado:
   ```elixir
   %{"message_id" => message.id, "patient_id" => patient.id}
   |> Alethea.Jobs.<NombreWorker>.new()
   |> Oban.insert()
   ```

4. **Crear el test** en `test/alethea_jobs/<nombre>_worker_test.exs`:
   - Usa `Oban.Testing` para testing de workers
   - Mockea `RobertaWorker` y `PhiWorker` para tests rápidos
   - Verifica el manejo de errores y reintentos

5. **Ejecutar `mix precommit`** para validar.

## Checklist Antes de Terminar

- [ ] El worker usa `use Oban.Worker` con `queue: :ai_processing`
- [ ] El pipeline sigue el orden: sanitizar → RoBERTa → LangChain → persistir
- [ ] El manejo de errores usa `with` y retorna `{:error, reason}` para reintentos
- [ ] El job publica en `Phoenix.PubSub` al finalizar para notificar LiveViews
- [ ] El test usa `Oban.Testing` y mocks de IA
- [ ] `mix precommit` pasa limpio
