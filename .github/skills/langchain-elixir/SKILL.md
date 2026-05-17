---
description: >
  Skill para implementar componentes de LangChain Elixir (chains, tools, templates)
  dentro del núcleo de IA de Alethea (`lib/alethea/ai/`). Úsala cuando el usuario
  pida agregar un flujo de conversación, una tool del LLM, o cualquier integración
  con modelos de lenguaje en el core.
---

# Skill: LangChain Elixir — Alethea AI Core

## Cuándo Invocarme

Invoca esta skill cuando el usuario pida:
- Crear o modificar una **chain** de LangChain (`lib/alethea/ai/chains/`)
- Crear o modificar una **tool** del LLM (`lib/alethea/ai/tools/`)
- Implementar o modificar `phi_worker.ex` o `roberta_worker.ex`
- Integrar un nuevo modelo de lenguaje en el pipeline de Alethea
- Agregar soporte de **streaming** de respuestas del LLM
- Implementar **PromptTemplate** para flujos clínicos
- Escribir tests para el componente de IA

## Lo Que Hago

1. **Analizo el contexto clínico** leyendo `lib/alethea/ai/CONTEXT.md` y el schema
   `lib/alethea/ai/diagnosis.ex` para entender el estado actual del sistema.

2. **Implemento la chain o tool** siguiendo los patrones de `langchain` v0.3.0:
   - Uso `LLMChain.new!/1` → `add_message/2` → `add_tools/2` → `run/1`
   - Mantengo el flujo de sanitización: input → `Sanitizer.sanitize/1` → LLM
   - Incluyo trazabilidad completa con `source_message_id`

3. **Genero el worker Oban** si la chain requiere procesamiento asíncrono.

4. **Escribo los tests** con mocks del LLM para no hacer llamadas HTTP reales.

5. **Ejecuto `mix precommit`** para validar que todo compila y los tests pasan.

## Restricciones Que Aplico Siempre

| Restricción | Implementación |
|-------------|----------------|
| Privacidad PII | `Sanitizer.sanitize/1` antes de cualquier LLM |
| Asincronía | Chains solo se ejecutan desde workers Oban |
| Trazabilidad | `source_message_id` en todo resultado de IA |
| Etiquetado | `:spontaneous` o `:elicited` en cada inferencia |
| Sin validación cognitiva | El LLM no valida ni refuta pensamientos sin OK del terapeuta |

## Pasos de Implementación

### Para una nueva Chain

```
1. Crear `lib/alethea/ai/chains/<nombre>_chain.ex`
2. Definir módulo con `run/1` que recibe %{sanitized_content, patient_context, message_id}
3. Construir LLMChain con el modelo apropiado (phi-4-mini para conversación)
4. Retornar mapa con %{response, source_message_id, model_version, behavior_type}
5. Crear `test/alethea/ai/chains/<nombre>_chain_test.exs` con Mox
```

### Para una nueva Tool

```
1. Crear `lib/alethea/ai/tools/<nombre>_tool.ex`
2. Definir `new!/0` que retorna `LangChain.Function.new!(params)`
3. Implementar la función callback que consulta datos internos de Alethea
4. Registrar la tool en `phi_worker.ex` via `LLMChain.add_tools/2`
5. Asegurar que la tool NO hace llamadas HTTP externas (solo datos internos)
```

## Referencias del Proyecto

- **Docs LangChain Elixir**: https://hexdocs.pm/langchain/0.3.0
- **Contexto del módulo AI**: `lib/alethea/ai/CONTEXT.md`
- **Schema de diagnósticos**: `lib/alethea/ai/diagnosis.ex`
- **Instrucciones del agente**: `.github/instructions/langchain-ai-core.instructions.md`
- **Agente especializado**: `.github/agents/langchain-ai-core.agent.md`
