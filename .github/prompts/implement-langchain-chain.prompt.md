---
description: Crea una nueva LLMChain de LangChain Elixir para un flujo clínico en Alethea
mode: agent
---

# Prompt: Crear LangChain Chain para Flujo Clínico

Estás implementando una nueva **LangChain chain** para el núcleo de IA de Alethea.
La chain vive en `lib/alethea/ai/chains/` y se invoca **exclusivamente** desde workers Oban.

## Contexto del Proyecto

- **Librería**: `langchain ~> 0.3.0` (Elixir)
- **Directorio objetivo**: `lib/alethea/ai/chains/`
- **Patrón de privacidad**: Todo contenido DEBE pasar por `Alethea.AI.Sanitizer.sanitize/1`
- **Trazabilidad**: El resultado SIEMPRE incluye `source_message_id`
- **Schema de salida**: Ver `lib/alethea/ai/diagnosis.ex`

## Tu Tarea

Crea una nueva chain para el siguiente flujo clínico:

**Flujo solicitado**: ${input:Describe el flujo clínico (ej. "extracción de emociones", "detección de crisis", "conversación guiada")}

### Pasos a Seguir

1. **Leer el contexto actual**:
   - `lib/alethea/ai/CONTEXT.md`
   - `lib/alethea/ai/diagnosis.ex`

2. **Crear el módulo de chain** en `lib/alethea/ai/chains/<nombre>_chain.ex`:

```elixir
defmodule Alethea.AI.Chains.<NombreChain> do
  @moduledoc """
  Chain para [descripción del flujo clínico].
  Invocada por Alethea.Jobs.AIProcessingWorker.
  """
  alias LangChain.Chains.LLMChain
  alias LangChain.ChatModels.ChatOpenAI
  alias LangChain.Message

  @model "phi-4-mini"

  @spec run(%{
    sanitized_content: String.t(),
    patient_context: map(),
    message_id: String.t(),
    behavior_type: :spontaneous | :elicited
  }) :: {:ok, map()} | {:error, term()}
  def run(%{sanitized_content: content, patient_context: ctx,
             message_id: msg_id, behavior_type: behavior_type}) do
    with {:ok, chain} <-
           %{llm: ChatOpenAI.new!(%{model: @model, stream: false})}
           |> LLMChain.new!()
           |> LLMChain.add_message(Message.new_system!(build_system_prompt(ctx)))
           |> LLMChain.add_message(Message.new_human!(content))
           |> LLMChain.run() do
      {:ok, %{
        response: chain.last_message.content,
        source_message_id: msg_id,
        model_version: @model,
        behavior_type: behavior_type,
        processed_at: DateTime.utc_now()
      }}
    end
  end

  defp build_system_prompt(ctx) do
    # Tono clínico, neutro. SIN validación de distorsiones cognitivas.
    """
    [System prompt específico para este flujo]
    Contexto: #{inspect(ctx)}
    """
  end
end
```

3. **Crear el test** en `test/alethea/ai/chains/<nombre>_chain_test.exs`:
   - Usa Mox para mockear las llamadas al LLM
   - Verifica que `source_message_id` esté en el resultado
   - Verifica que el `behavior_type` sea correcto

4. **Verificar el precommit**:
   ```bash
   mix precommit
   ```

## Checklist Antes de Terminar

- [ ] El módulo está en `lib/alethea/ai/chains/`
- [ ] La función pública es `run/1` con la typespec correcta
- [ ] El system prompt NO valida distorsiones cognitivas sin instrucción del terapeuta
- [ ] El resultado incluye `source_message_id`, `model_version`, `behavior_type`, `processed_at`
- [ ] El test existe y usa mocks (sin llamadas HTTP reales)
- [ ] `mix precommit` pasa limpio
