defmodule Alethea.AI.ChatModels.HuggingFaceChat do
  @moduledoc """
  Custom LangChain ChatModel for Hugging Face Inference API.
  """
  use Ecto.Schema
  import Ecto.Changeset
  alias LangChain.ChatModels.ChatModel
  alias LangChain.Message
  alias LangChain.LangChainError

  @behaviour ChatModel

  @type t :: %__MODULE__{}

  @primary_key false
  embedded_schema do
    field :model, :string, default: "meta-llama/Llama-2-7b-chat-hf"
    field :api_key, :string, redact: true
    field :endpoint_url, :string, default: "https://api-inference.huggingface.co/models/"
    field :temperature, :float, default: 0.7
    field :max_tokens, :integer, default: 512
    field :stream, :boolean, default: false
    field :receive_timeout, :integer, default: 60_000
    field :callbacks, {:array, :map}, default: []
  end

  @create_fields [
    :model,
    :api_key,
    :endpoint_url,
    :temperature,
    :max_tokens,
    :stream,
    :receive_timeout,
    :callbacks
  ]
  @required_fields [:model, :api_key]

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
        LangChain.Telemetry.llm_prompt(%{system_time: System.system_time()}, %{
          model: model.model,
          messages: messages
        })

        case do_api_request(model, messages) do
          {:error, reason} ->
            {:error, reason}

          parsed ->
            LangChain.Telemetry.llm_response(%{system_time: System.system_time()}, %{
              model: model.model,
              response: parsed
            })

            {:ok, Message.new_assistant!(parsed)}
        end
      rescue
        err in LangChainError -> {:error, err.message}
      end
    end)
  end

  defp do_api_request(%__MODULE__{stream: true}, _messages) do
    raise LangChainError, "Streaming is not supported for HuggingFaceChat"
  end

  defp do_api_request(%__MODULE__{} = model, messages) do
    payload = %{
      inputs: messages_to_input(messages),
      parameters: %{
        temperature: model.temperature,
        max_new_tokens: model.max_tokens,
        return_full_text: false
      }
    }

    headers = [
      {"Authorization", "Bearer #{model.api_key}"},
      {"Content-Type", "application/json"}
    ]

    url = model.endpoint_url <> model.model

    case Req.post(url, json: payload, headers: headers, receive_timeout: model.receive_timeout) do
      {:ok, %Req.Response{status: 200, body: [%{"generated_text" => text} | _]}} ->
        text

      {:ok, %Req.Response{status: 200, body: %{"generated_text" => text}}} ->
        text

      {:ok, %Req.Response{status: status, body: body}} ->
        raise LangChainError, "Hugging Face API error (#{status}): #{inspect(body)}"

      {:error, reason} ->
        raise LangChainError, "Hugging Face API request failed: #{inspect(reason)}"
    end
  end

  @impl ChatModel
  def restore_from_map(attrs) do
    case new(attrs) do
      {:ok, model} -> model
      {:error, _changeset} -> :error
    end
  end

  @impl ChatModel
  def serialize_config(%__MODULE__{} = model) do
    Map.from_struct(model)
  end

  defp messages_to_input(messages) do
    messages
    |> Enum.map(fn msg ->
      role = Map.get(msg, :role)
      content = Map.get(msg, :content)
      "[#{role}]: #{content}"
    end)
    |> Enum.join("\n")
  end
end
