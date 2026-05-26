defmodule Alethea.AI.ChatModels.HuggingFaceChat do
  @moduledoc """
  Wrapper de chat para usar la API de Hugging Face con LangChain.

  Este modelo envía la conversación formateada a un endpoint de Hugging Face
  y convierte la respuesta en un `LangChain.Message` compatible.
  """

  use Ecto.Schema
  require Logger
  import Ecto.Changeset

  alias LangChain.ChatModels.ChatModel
  alias LangChain.LangChainError
  alias LangChain.Message
  alias LangChain.Utils

  @behaviour ChatModel
  @current_config_version 1
  @receive_timeout 60_000

  @type t :: %__MODULE__{}

  @create_fields [
    :endpoint,
    :model,
    :api_key,
    :temperature,
    :max_tokens,
    :stream,
    :receive_timeout,
    :callbacks
  ]

  @required_fields [:endpoint, :model]

  @primary_key false
  embedded_schema do
    field :endpoint, :string,
      default: "https://api-inference.huggingface.co/models"

    field :model, :string, default: "phi-4-mini"
    field :api_key, :string, redact: true
    field :temperature, :float, default: 0.0
    field :max_tokens, :integer, default: 512
    field :stream, :boolean, default: false
    field :receive_timeout, :integer, default: @receive_timeout
    field :callbacks, {:array, :map}, default: []
  end

  @spec new(map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def new(attrs \\ %{}) when is_map(attrs) do
    %__MODULE__{}
    |> cast(attrs, @create_fields, empty_values: [""])
    |> validate_required(@required_fields)
    |> validate_number(:temperature, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 2.0)
    |> validate_number(:max_tokens, greater_than: 0)
    |> apply_action(:insert)
  end

  @spec new!(map()) :: t() | no_return()
  def new!(attrs \\ %{}) do
    case new(attrs) do
      {:ok, model} -> model
      {:error, changeset} -> raise LangChainError, changeset
    end
  end

  @impl ChatModel
  def call(model, prompt, tools \\ [])

  def call(%__MODULE__{} = model, prompt, tools) when is_binary(prompt) do
    messages = [Message.new_system!(), Message.new_user!(prompt)]
    call(model, messages, tools)
  end

  def call(%__MODULE__{} = model, messages, _tools) when is_list(messages) do
    metadata = %{model: model.model, message_count: length(messages)}

    LangChain.Telemetry.span([:langchain, :llm, :call], metadata, fn ->
      try do
        LangChain.Telemetry.llm_prompt(%{system_time: System.system_time()}, %{model: model.model, messages: messages})

        case do_api_request(model, messages) do
          {:error, reason} -> {:error, reason}
          parsed ->
            LangChain.Telemetry.llm_response(%{system_time: System.system_time()}, %{model: model.model, response: parsed})
            {:ok, Message.new_assistant!(parsed)}
        end
      rescue
        err in LangChainError -> {:error, err.message}
      end
    end)
  end

  defp do_api_request(%__MODULE__{stream: true} = _model, _messages) do
    raise LangChainError, "Streaming is not supported for HuggingFaceChat"
  end

  defp do_api_request(%__MODULE__{} = model, messages) do
    payload = %{
      inputs: messages_to_input(messages),
      parameters: %{
        temperature: model.temperature,
        max_new_tokens: model.max_tokens
      }
    }

    req =
      Req.new(
        url: build_url(model),
        headers: request_headers(model),
        json: payload,
        receive_timeout: model.receive_timeout,
        retry: :transient,
        max_retries: 3,
        inet6: true,
        retry_delay: fn attempt -> 300 * attempt end
      )

    case Req.post(req) do
      {:ok, %Req.Response{body: body}} -> parse_response(body)
      {:error, %Req.TransportError{reason: :timeout}} -> {:error, "Request timed out"}
      {:error, %Req.TransportError{reason: :closed}} -> {:error, "Connection closed"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp build_url(%__MODULE__{endpoint: endpoint, model: model}) do
    String.trim_trailing(endpoint, "/") <> "/" <> model
  end

  defp request_headers(%__MODULE__{api_key: api_key}) do
    base_headers = [
      {"content-type", "application/json"}
    ]

    if api_key in [nil, ""] do
      base_headers
    else
      base_headers ++ [{"authorization", "Bearer #{api_key}"}]
    end
  end

  defp messages_to_input(messages) do
    messages
    |> Enum.filter(&(&1.content != nil))
    |> Enum.map(&message_to_input/1)
    |> Enum.join("\n\n")
  end

  defp message_to_input(%Message{role: :system, content: content}), do: "System: #{content}"
  defp message_to_input(%Message{role: :user, content: content}), do: "User: #{content}"
  defp message_to_input(%Message{role: :assistant, content: content}), do: "Assistant: #{content}"
  defp message_to_input(%Message{content: content}), do: content

  defp parse_response(%{"error" => error}), do: raise(LangChainError, error)
  defp parse_response(%{"generated_text" => text}) when is_binary(text), do: text
  defp parse_response([%{"generated_text" => text} | _]) when is_binary(text), do: text
  defp parse_response(%{"choices" => [%{"message" => %{"content" => text}} | _]}) when is_binary(text), do: text
  defp parse_response(%{"choices" => [%{"generated_text" => text} | _]}) when is_binary(text), do: text
  defp parse_response(body) when is_binary(body), do: body

  defp parse_response(body) do
    raise LangChainError,
      "Could not parse Hugging Face response: #{inspect(body)}"
  end

  @impl ChatModel
  def serialize_config(%__MODULE__{} = model) do
    Utils.to_serializable_map(model, [:endpoint, :model, :api_key, :temperature, :max_tokens, :stream, :receive_timeout], @current_config_version)
  end

  @impl ChatModel
  def restore_from_map(%{"version" => 1} = data) do
    new(data)
  end
end
