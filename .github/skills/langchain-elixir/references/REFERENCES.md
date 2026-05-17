---
description: >
  Referencias técnicas y documentación curada para implementar LangChain Elixir
  en el contexto del proyecto Alethea. Incluye ejemplos de la API v0.3.0, patrones
  de testing, y guías de integración con Oban y Bumblebee.
---

# Referencias: LangChain Elixir v0.3.0

## Documentación Oficial

- **HexDocs**: https://hexdocs.pm/langchain/0.3.0
- **GitHub**: https://github.com/brainlid/langchain
- **Changelog**: https://github.com/brainlid/langchain/blob/main/CHANGELOG.md

## API Reference Rápida

### Chat Models

| Módulo | Uso en Alethea |
|--------|---------------|
| `LangChain.ChatModels.ChatOpenAI` | Phi-4, GPT-4o (fallback) |
| `LangChain.ChatModels.ChatAnthropic` | NO usar (política de privacidad) |
| `LangChain.ChatModels.ChatMistral` | Alternativa local vía Ollama |
| `LangChain.ChatModels.ChatOllamaAI` | Modelos locales vía Ollama |

### Mensajes

```elixir
Message.new_system!(content)          # Prompt del sistema (instrucciones clínicas)
Message.new_human!(content)           # Mensaje del paciente (SANITIZADO)
Message.new_assistant!(content)       # Respuesta anterior del LLM (historial)
Message.new_tool_result!(tool_call_id, content)  # Resultado de una tool call
```

### LLMChain — Flujo Completo

```elixir
{:ok, updated_chain} =
  %{llm: ChatOpenAI.new!(%{model: "gpt-4o-mini", stream: false, temperature: 0.3})}
  |> LLMChain.new!()
  |> LLMChain.add_message(Message.new_system!("..."))
  |> LLMChain.add_messages([msg1, msg2])   # Historial
  |> LLMChain.add_tools([Tool.new!()])      # Tools disponibles
  |> LLMChain.run()

# Acceder al resultado:
updated_chain.last_message.content   # String con la respuesta
updated_chain.messages               # Historial completo
```

### Streaming (para LiveView)

```elixir
# Callback por chunk
callback = fn
  %LangChain.MessageDelta{} = delta ->
    Phoenix.PubSub.broadcast(Alethea.PubSub, "ai:#{session_id}", {:chunk, delta.content})
  :done ->
    Phoenix.PubSub.broadcast(Alethea.PubSub, "ai:#{session_id}", :done)
end

%{llm: ChatOpenAI.new!(%{model: "phi-4-mini", stream: true})}
|> LLMChain.new!(callbacks: [callback])
|> LLMChain.add_message(Message.new_human!(sanitized_content))
|> LLMChain.run()
```

### PromptTemplate

```elixir
alias LangChain.PromptTemplate

template = PromptTemplate.new!(%{
  text: "Contexto del paciente: <%= @context %>. Mensaje: <%= @message %>",
  input_variables: [:context, :message]
})

formatted = PromptTemplate.format(template, %{
  context: "Paciente con trastorno de ansiedad",
  message: sanitized_content
})
```

### Function/Tool

```elixir
alias LangChain.Function

tool = Function.new!(%{
  name: "get_patient_summary",
  description: "Obtiene el resumen clínico del paciente para esta sesión.",
  parameters_schema: %{
    type: "object",
    properties: %{
      session_token: %{type: "string"}
    },
    required: ["session_token"]
  },
  function: fn %{"session_token" => token}, _context ->
    # Resolver internamente — NUNCA exponer patient_id al LLM
    summary = Alethea.Clinical.get_session_summary(token)
    Jason.encode!(summary)
  end
})
```

## Integración con Bumblebee (RoBERTa Local)

```elixir
# NO usa LangChain. Es inferencia local directa.
{:ok, model_info} = Bumblebee.load_model({:hf, "cardiffnlp/twitter-roberta-base-sentiment"})
{:ok, tokenizer} = Bumblebee.load_tokenizer({:hf, "cardiffnlp/twitter-roberta-base-sentiment"})

serving = Bumblebee.Text.text_classification(model_info, tokenizer)

Nx.Serving.run(serving, "Me siento muy triste hoy")
# => %{predictions: [%{label: "LABEL_0", score: 0.89}]}
```

## Patrones de Testing

### Mock de LangChain con Bypass/Req.Test

```elixir
# En test/support/mocks.ex
Mox.defmock(MockLLMChain, for: LangChain.Chains.LLMChain.Behaviour)

# En el test
import Mox

test "chain retorna respuesta válida" do
  MockLLMChain
  |> expect(:run, fn _chain ->
    {:ok, %LangChain.Chains.LLMChain{
      last_message: LangChain.Message.new_assistant!("¿Cómo te sientes ahora?")
    }}
  end)
  # ...
end
```

### Test de Oban Worker

```elixir
use Oban.Testing, repo: Alethea.Repo

test "encola job de procesamiento de IA" do
  assert :ok = perform_job(Alethea.Jobs.AIProcessingWorker, %{
    "message_id" => "uuid-123",
    "patient_id" => "patient-uuid"
  })

  assert_enqueued worker: Alethea.Jobs.AIProcessingWorker,
                  args: %{"message_id" => "uuid-123"}
end
```

## Configuración de Entorno

```elixir
# config/runtime.exs
config :langchain, openai_key: System.fetch_env!("OPENAI_API_KEY")

# Para Phi-4 local vía Ollama:
config :langchain, :chat_models, %{
  "phi-4-mini" => %{
    module: LangChain.ChatModels.ChatOllamaAI,
    endpoint: "http://localhost:11434/api/chat"
  }
}
```

## Recursos Adicionales del Ecosistema

- **Ollama** (Phi-4 local): https://ollama.ai
- **pgvector Elixir**: https://hexdocs.pm/pgvector/
- **Bumblebee**: https://hexdocs.pm/bumblebee/
- **Oban**: https://hexdocs.pm/oban/
- **Nx (Numerical Elixir)**: https://hexdocs.pm/nx/
