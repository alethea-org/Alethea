defmodule Alethea.AI.ChatModels.AnthropicChat do
  @moduledoc """
  Text-only Anthropic adapter with bounded, payload-free failures.

  Reuses LangChain's message serializer, but not its transport: the installed
  adapter logs some unexpected provider responses before callers can redact them.
  Streaming and tools are rejected explicitly. Credentials are not serialized.
  """
  @behaviour LangChain.ChatModels.ChatModel
  @derive {Inspect, except: [:config]}
  defstruct [:config, :model, callbacks: []]

  alias LangChain.ChatModels.ChatAnthropic
  alias LangChain.{LangChainError, Message}

  @type t :: %__MODULE__{}
  @config_fields [:model, :endpoint, :temperature, :max_tokens, :receive_timeout, :stream]

  def new(attrs \\ %{}) do
    with model when is_binary(model) and byte_size(model) > 0 <- Map.get(attrs, :model),
         key when is_binary(key) and byte_size(key) > 0 <- Map.get(attrs, :api_key),
         true <- String.trim(model) != "" and String.trim(key) != "",
         {:ok, config} <- ChatAnthropic.new(attrs) do
      {:ok, %__MODULE__{config: config, model: config.model}}
    else
      _ -> error("invalid_config", "Invalid Anthropic configuration")
    end
  end

  def new!(attrs \\ %{}) do
    case new(attrs) do
      {:ok, model} -> model
      {:error, reason} -> raise reason
    end
  end

  @impl true
  def call(model, messages, tools \\ [])

  def call(%__MODULE__{config: %{stream: true}}, _messages, _tools),
    do: error("unsupported", "Anthropic streaming is not supported")

  def call(_model, _messages, tools) when tools != [],
    do: error("unsupported", "Anthropic tools are not supported")

  def call(%__MODULE__{} = model, prompt, []) when is_binary(prompt),
    do: call(model, [Message.new_user!(prompt)], [])

  def call(%__MODULE__{config: config}, messages, []) when is_list(messages) do
    payload = ChatAnthropic.for_api(config, messages, [])

    options =
      Keyword.merge(Application.get_env(:alethea, :anthropic_chat_req_options, []),
        json: payload,
        headers: [{"x-api-key", config.api_key}, {"anthropic-version", config.api_version}],
        receive_timeout: config.receive_timeout,
        retry: false,
        redirect: false
      )

    case Req.post(config.endpoint, options) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        decode(body)

      {:ok, %Req.Response{status: status}} ->
        error("http_error", "Anthropic API returned HTTP #{status}")

      {:error, _reason} ->
        error("request_failed", "Anthropic request failed")
    end
  rescue
    _ -> error("request_failed", "Anthropic request failed")
  end

  @impl true
  def serialize_config(%__MODULE__{config: config}), do: Map.take(config, @config_fields)

  @impl true
  def restore_from_map(attrs) do
    case new(attrs) do
      {:ok, model} -> model
      {:error, _reason} -> :error
    end
  end

  defp decode(%{"content" => [_ | _] = blocks, "stop_reason" => stop})
       when stop in ["end_turn", "stop_sequence", "max_tokens"] do
    if Enum.all?(blocks, &match?(%{"type" => "text", "text" => text} when is_binary(text), &1)) do
      text = Enum.map_join(blocks, & &1["text"])

      if String.trim(text) != "" do
        Message.new_assistant(%{
          content: text,
          status: if(stop == "max_tokens", do: :length, else: :complete)
        })
      else
        invalid_response()
      end
    else
      invalid_response()
    end
  end

  defp decode(_body), do: invalid_response()
  defp invalid_response, do: error("invalid_response", "Invalid Anthropic response")
  defp error(type, message), do: {:error, LangChainError.exception(type: type, message: message)}
end
