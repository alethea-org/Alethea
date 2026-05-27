---
applyTo: "lib/alethea_jobs/**"
---

# Instrucciones: Workers Oban (Infrastructure Adapter)

Estas instrucciones aplican a todos los archivos dentro de `lib/alethea_jobs/`.

## Regla de Asincronía (OBLIGATORIA)

**Todo** procesamiento de IA (LangChain, Bumblebee, embeddings) DEBE ejecutarse
desde un worker Oban. **NUNCA** hagas inferencia de IA sincrónica en el proceso
receptor de mensajes de WhatsApp.

## Colas Oban y sus Responsabilidades

| Cola             | Uso                                          | Concurrencia |
|------------------|----------------------------------------------|--------------|
| `:webhooks`      | Recepción y parseo de mensajes WhatsApp      | 20           |
| `:ai_processing` | Pipeline de IA (RoBERTa + LangChain)         | 5            |
| `:alerts`        | Notificaciones de crisis (alta prioridad)    | 10           |
| `:default`       | Jobs genéricos                               | 10           |

## Patrón de Worker

```elixir
defmodule Alethea.Jobs.MyWorker do
  use Oban.Worker,
    queue: :ai_processing,   # Siempre especificar la cola correcta
    max_attempts: 3,
    unique: [period: 60, fields: [:args]]  # Evitar duplicados

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"key" => value}}) do
    # Usa `with` para manejo de errores en cascada
    with {:ok, result} <- do_work(value) do
      :ok
    else
      {:error, reason} -> {:error, reason}  # Permite reintento de Oban
    end
  end
end
```

## Manejo de Errores

- Retorna `{:error, reason}` para que Oban reintente automáticamente.
- Retorna `:ok` solo cuando el procesamiento fue exitoso.
- No uses `raise` para errores esperados; usa el patrón `{:error, reason}`.
- Para errores irrecuperables (datos corruptos), usa `{:cancel, reason}` para
  evitar reintentos infinitos.

## Notificación a LiveViews

- Cuando un job de IA completa, notifica via `Phoenix.PubSub` para actualizar LiveViews.
- Patrón: `Phoenix.PubSub.broadcast(Alethea.PubSub, "topic:#{id}", {:done, result})`

## Testing

```elixir
use Oban.Testing, repo: Alethea.Repo

# Para probar un worker directamente
assert :ok = perform_job(Alethea.Jobs.MyWorker, %{"key" => "value"})

# Para verificar que se encoló un job
assert_enqueued worker: Alethea.Jobs.MyWorker, args: %{"key" => "value"}
```
