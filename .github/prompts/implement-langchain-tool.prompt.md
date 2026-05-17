---
description: Crea una nueva LangChain Tool (Function) para que el LLM acceda a datos internos de Alethea
---

# Prompt: Crear LangChain Tool para el LLM

Estás implementando una nueva **LangChain Function (Tool)** para el núcleo de IA de Alethea.
Las tools viven en `lib/alethea/ai/tools/` y son funciones que el LLM puede llamar
para acceder a datos internos del sistema (historial clínico, vectores, grafo de conducta).

## Reglas de Oro para Tools

1. **Las tools NUNCA hacen llamadas HTTP externas**. Solo acceden a datos locales de Alethea.
2. **Las tools NO reciben ni retornan PII en claro**. Usan IDs internos o tokens de sesión.
3. **Las tools retornan JSON válido** (string serializado con `Jason.encode!/1`).

## Contexto del Proyecto

- **Módulos de dominio disponibles**: `Alethea.Clinical`, `Alethea.Accounts`, `Alethea.Encryption`
- **Búsqueda vectorial**: `Alethea.Clinical.search_similar_entries/2` (usa pgvector)
- **Grafo de conducta**: Disponible via queries a Neo4j en `Alethea.Clinical.BehaviorGraph`

## Tu Tarea

Crea una nueva tool para la siguiente funcionalidad:

**Funcionalidad solicitada**: ${input:Describe qué datos necesita acceder el LLM (ej. "historial de emociones del paciente", "entradas similares del diario", "patrones de conducta detectados")}

### Pasos a Seguir

1. **Crear el módulo de tool** en `lib/alethea/ai/tools/<nombre>_tool.ex`:

```elixir
defmodule Alethea.AI.Tools.<NombreTool> do
  @moduledoc """
  LangChain Tool para [descripción].
  Permite al LLM acceder a [datos] del sistema Alethea.
  """
  alias LangChain.Function

  @spec new!() :: LangChain.Function.t()
  def new! do
    Function.new!(%{
      name: "<nombre_snake_case>",
      description: "[Descripción clara para el LLM de qué hace esta tool]",
      parameters_schema: %{
        type: "object",
        properties: %{
          # Define los parámetros que el LLM enviará
          session_token: %{
            type: "string",
            description: "Token de sesión de un solo uso (no expone patient_id)"
          }
        },
        required: ["session_token"]
      },
      function: &execute/2
    })
  end

  # La función callback que realmente ejecuta la tool
  defp execute(params, _context) do
    # 1. Resolver el session_token a un patient_id interno (nunca expuesto al LLM)
    # 2. Consultar los datos de Alethea
    # 3. Retornar JSON serializado
    result = %{data: []}
    Jason.encode!(result)
  end
end
```

2. **Registrar la tool en `phi_worker.ex`**:
   ```elixir
   |> LLMChain.add_tools([
     Alethea.AI.Tools.<NombreTool>.new!(),
     # ... otras tools
   ])
   ```

3. **Crear el test** en `test/alethea/ai/tools/<nombre>_tool_test.exs`:
   - Verifica que `new!/0` retorna un `LangChain.Function` válido
   - Verifica que la función callback retorna JSON válido
   - Verifica que NUNCA expone PII en la respuesta

4. **Ejecutar `mix precommit`** para validar compilación y tests.

## Checklist Antes de Terminar

- [ ] El módulo está en `lib/alethea/ai/tools/`
- [ ] La función pública es `new!/0` que retorna `LangChain.Function.t()`
- [ ] La tool NO hace llamadas HTTP externas
- [ ] La tool usa `session_token` en lugar de `patient_id` para proteger PII
- [ ] La función callback retorna JSON válido con `Jason.encode!/1`
- [ ] La tool está registrada en `phi_worker.ex`
- [ ] El test verifica el comportamiento sin exponer PII
- [ ] `mix precommit` pasa limpio
