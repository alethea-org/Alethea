defmodule Alethea.AI.ChatModels.OllamaChat do
  @moduledoc """
  LangChain ChatModel adapter for Ollama's native chat API.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias LangChain.ChatModels.ChatModel
  alias LangChain.{LangChainError, Message}

  @behaviour ChatModel

  @type t :: %__MODULE__{}

  @primary_key false
  embedded_schema do
    field(:model, :string, default: "phi4-mini")
    field(:endpoint_url, :string, default: "http://localhost:11434")
    field(:temperature, :float, default: 0.0)
    field(:max_tokens, :integer, default: 512)
    field(:stream, :boolean, default: false)
    field(:receive_timeout, :integer, default: 60_000)
    field(:callbacks, {:array, :map}, default: [])
  end

  @fields [
    :model,
    :endpoint_url,
    :temperature,
    :max_tokens,
    :stream,
    :receive_timeout,
    :callbacks
  ]

  @spec new(map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def new(attrs \\ %{}) do
    %__MODULE__{}
    |> cast(attrs, @fields)
    |> validate_required([:model, :endpoint_url])
    |> validate_number(:temperature, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 2.0)
    |> validate_number(:max_tokens, greater_than: 0)
    |> apply_action(:insert)
  end

  @spec new!(map()) :: t()
  def new!(attrs \\ %{}) do
    case new(attrs) do
      {:ok, model} -> model
      {:error, changeset} -> raise LangChainError, changeset
    end
  end

  @impl ChatModel
  def call(model, prompt, tools \\ [])

  def call(%__MODULE__{} = model, prompt, tools) when is_binary(prompt) do
    call(model, [Message.new_user!(prompt)], tools)
  end

  def call(%__MODULE__{stream: true}, _messages, _tools) do
    {:error, "Streaming is not supported for OllamaChat"}
  end

  def call(%__MODULE__{} = model, messages, _tools) when is_list(messages) do
    metadata = %{model: model.model, message_count: length(messages)}

    LangChain.Telemetry.span([:langchain, :llm, :call], metadata, fn ->
      case request(model, messages) do
        {:ok, content} -> {:ok, Message.new_assistant!(content)}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  @impl ChatModel
  def restore_from_map(attrs) do
    case new(attrs) do
      {:ok, model} -> model
      {:error, _changeset} -> :error
    end
  end

  @impl ChatModel
  def serialize_config(%__MODULE__{} = model), do: Map.from_struct(model)

  defp request(model, messages) do
    payload = %{
      model: model.model,
      messages: Enum.map(messages, &message_payload/1),
      stream: false,
      options: %{temperature: model.temperature, num_predict: model.max_tokens}
    }

    options =
      [json: payload, receive_timeout: model.receive_timeout] ++
        Application.get_env(:alethea, :ollama_chat_req_options, [])

    url = String.trim_trailing(model.endpoint_url, "/") <> "/api/chat"

    case Req.post(url, options) do
      {:ok, %Req.Response{status: 200, body: %{"message" => %{"content" => content}}}}
      when is_binary(content) and byte_size(content) > 0 ->
        {:ok, content}

      {:ok, %Req.Response{status: status}} ->
        {:error, "Ollama API returned HTTP #{status}"}

      {:error, reason} ->
        {:error, "Ollama API request failed: #{inspect(reason)}"}
    end
  end

  defp message_payload(message) do
    %{
      role: message.role |> to_string(),
      content: message.content
    }
  end
end
