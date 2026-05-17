---
applyTo: "lib/alethea/ai/**"
---

# Instrucciones: Núcleo de IA con LangChain Elixir

Estas instrucciones aplican a todos los archivos dentro de `lib/alethea/ai/`.

## Reglas de Privacidad (OBLIGATORIAS)

- **NUNCA** pases contenido en claro directamente a una `LLMChain`. Siempre debes
  sanitizar primero con `Alethea.AI.Sanitizer.sanitize/1`.
- **NUNCA** persistas el contenido raw de mensajes; usa el campo cifrado con `Cloak.Ecto`.
- **NUNCA** expongas el `patient_id` en logs ni en traces del LLM. Usa el `session_token`
  de un solo uso para contexto externo.

## Arquitectura de LangChain en Este Proyecto

### Módulo `langchain` v0.3.0 — APIs Clave

```elixir
# Chat model (siempre usa `new!` con `!` para fallar rápido en config)
LangChain.ChatModels.ChatOpenAI.new!(%{model: "phi-4-mini"})

# Chain principal
LangChain.Chains.LLMChain.new!(params)
LangChain.Chains.LLMChain.add_message(chain, message)
LangChain.Chains.LLMChain.add_tools(chain, [tool])
LangChain.Chains.LLMChain.run(chain)  # Devuelve {:ok, chain} | {:error, reason}

# Mensajes
LangChain.Message.new_system!(content)
LangChain.Message.new_human!(content)
LangChain.Message.new_assistant!(content)

# Tools (funciones que el LLM puede llamar)
LangChain.Function.new!(%{name, description, parameters_schema, function})

# Templates
LangChain.PromptTemplate.new!(%{text: "...", input_variables: [:var]})
LangChain.PromptTemplate.format(template, %{var: value})
```

## Reglas de Asincronía

- Todo código en `lib/alethea/ai/chains/` y `lib/alethea/ai/phi_worker.ex` DEBE
  ser invocado **exclusivamente** desde workers Oban en `lib/alethea_jobs/`.
- Si necesitas resultados de la IA en tiempo real para un LiveView, usa
  `Phoenix.PubSub` para transmitir el resultado cuando el job Oban finalice.

## Estructura de Módulos

- `Alethea.AI.Chains.*` — Definiciones de `LLMChain`. Una por flujo clínico.
  Cada chain debe ser un módulo con una función pública `run/1`.
- `Alethea.AI.Tools.*` — `LangChain.Function` tools. Cada tool en su propio módulo
  con una función `new!/0` que retorna el struct de `Function`.
- `Alethea.AI.Sanitizer` — Módulo único. Centraliza toda la lógica de limpieza de PII.
- `Alethea.AI.RobertaWorker` — Inferencia local. NO usa LangChain. Usa Bumblebee directamente.
- `Alethea.AI.PhiWorker` — Interfaz de alto nivel que coordina cadena y tools.

## Trazabilidad Obligatoria

Toda función que retorne un resultado de IA DEBE devolver un mapa que incluya:

```elixir
%{
  result: ...,
  source_message_id: message_id,   # UUID del mensaje original
  model_version: "roberta-v1",     # o "phi-4-mini", etc.
  behavior_type: :spontaneous | :elicited,
  processed_at: DateTime.utc_now()
}
```

## Testing

- Mockea `LangChain.ChatModels.ChatOpenAI` usando `Mox` o patrones de inyección.
- Nunca hagas llamadas HTTP reales en tests. Usa `Req.Test` o mocks de LangChain.
- Todo cambio en `chains/` requiere un test de regresión en `test/alethea/ai/`.
- Nombre de archivos de test: `test/alethea/ai/chains/<nombre>_chain_test.exs`.

## Ejemplo de Test con Mock

```elixir
defmodule Alethea.AI.Chains.GuidedConversationChainTest do
  use ExUnit.Case, async: true

  import Mox

  setup :verify_on_exit!

  test "run/1 returns structured result with source_message_id" do
    # Mock de la respuesta del LLM
    MockLangChain
    |> expect(:run, fn _chain ->
      {:ok, %{last_message: %{content: "¿Cómo te sentiste después de eso?"}}}
    end)

    result = Alethea.AI.Chains.GuidedConversationChain.run(%{
      sanitized_content: "Me siento triste hoy",
      patient_context: %{},
      message_id: "msg-uuid-123"
    })

    assert result.source_message_id == "msg-uuid-123"
    assert result.behavior_type == :elicited
    assert is_binary(result.response)
  end
end
```
