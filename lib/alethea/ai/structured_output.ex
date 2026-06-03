defmodule Alethea.AI.StructuredOutput do
  @moduledoc """
  Helpers para structured output de LLMs.

  Provee prompts que instructúan al LLM a responder en JSON
  y parsing para convertir las respuestas a mapas estructurados.
  """

  @doc """
  Prompt suffix que instruye al LLM a responder en JSON.
  """
  def json_instruction do
    """
    Responde SOLO con JSON válido en este formato exacto, sin texto adicional:
    {"key": "value", "key2": 123}
    """
  end

  @doc """
  Agrega instruction de JSON al system prompt.
  """
  @spec with_json_format(String.t()) :: String.t()
  def with_json_format(system_prompt) do
    "#{system_prompt}\n\n#{json_instruction()}"
  end

  @doc """
  Intenta parsear la respuesta del LLM como JSON.
  Devuelve {:ok, map} o {:error, reason}.
  """
  @spec parse_json_response(String.t()) :: {:ok, map()} | {:error, :invalid_json}
  def parse_json_response(response) when is_binary(response) do
    # Limpiar markdown code blocks si existen
    cleaned =
      response
      |> String.replace(~r/^```json\s*/i, "")
      |> String.replace(~r/^```\s*/i, "")
      |> String.trim()

    case Jason.decode(cleaned) do
      {:ok, map} when is_map(map) -> {:ok, map}
      {:ok, _} -> {:error, :not_a_map}
      {:error, _} -> {:error, :invalid_json}
    end
  rescue
    _ -> {:error, :invalid_json}
  end

  @doc """
  Schema para emociones.
  """
  def emotion_schema do
    %{
      "type" => "object",
      "properties" => %{
        "dominant_emotion" => %{
          "type" => "string",
          "enum" => ["joy", "sadness", "anger", "fear", "neutral"]
        },
        "intensity" => %{"type" => "number", "minimum" => 0, "maximum" => 1},
        "confidence" => %{"type" => "number", "minimum" => 0, "maximum" => 1},
        "triggers" => %{"type" => "array", "items" => %{"type" => "string"}}
      },
      "required" => ["dominant_emotion", "intensity"]
    }
  end

  @doc """
  Schema para resumen de sesión.
  """
  def session_summary_schema do
    %{
      "type" => "object",
      "properties" => %{
        "emotional_state" => %{"type" => "string"},
        "topics_discussed" => %{"type" => "array", "items" => %{"type" => "string"}},
        "evolution" => %{"type" => "string"},
        "attention_level" => %{
          "type" => "string",
          "enum" => ["Estable", "Alerta", "Intervención Requerida"]
        }
      },
      "required" => ["emotional_state", "attention_level"]
    }
  end

  @doc """
  Schema para weekly summary.
  """
  def weekly_summary_schema do
    %{
      "type" => "object",
      "properties" => %{
        "emotional_overview" => %{"type" => "string"},
        "recurring_patterns" => %{"type" => "array", "items" => %{"type" => "string"}},
        "milestones" => %{"type" => "array", "items" => %{"type" => "string"}},
        "risk_level" => %{
          "type" => "string",
          "enum" => ["Estable", "Alerta", "Intervención Requerida"]
        }
      },
      "required" => ["emotional_overview", "risk_level"]
    }
  end

  @doc """
  Genera el system prompt con instruction de JSON schema.
  """
  @spec with_schema(String.t(), map()) :: String.t()
  def with_schema(system_prompt, schema) do
    schema_str = Jason.encode!(schema)
    "#{system_prompt}\n\nResponde SOLO con JSON válido siguiendo este schema:\n#{schema_str}"
  end
end
