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
    # LangChain's serializer always includes temperature; see haiku_5_payload/2.
    payload =
      config
      |> ChatAnthropic.for_api(messages, [])
      |> haiku_5_payload(config.model)

    options =
      Keyword.merge(Application.get_env(:alethea, :anthropic_chat_req_options, []),
        json: payload,
        headers: [{"x-api-key", config.api_key}, {"anthropic-version", config.api_version}],
        receive_timeout: config.receive_timeout,
        # Overload (529), rate limits (429), 408/5xx and closed sockets are
        # retried with backoff (see retry?/2); auth and request errors fail at once.
        retry: &retry?/2,
        max_retries: 2,
        redirect: false
      )

    case Req.post(config.endpoint, options) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        decode(body)

      # The status rides in the type so it survives SafeRun, which keeps only
      # the type: a revoked key, a rate limit and an outage stay distinct.
      {:ok, %Req.Response{status: status}} ->
        error("http_error.#{status}", "Anthropic API returned HTTP #{status}")

      # Only the transport's reason atom (e.g. timeout, econnrefused) is
      # reported: it tells throttling, auth and network failures apart
      # without echoing any payload.
      {:error, %Req.TransportError{reason: reason}} when is_atom(reason) ->
        error("request_failed", "Anthropic request failed: #{reason}")

      {:error, _reason} ->
        error("request_failed", "Anthropic request failed")
    end
  rescue
    _ -> error("request_failed", "Anthropic request failed")
  end

  @impl true
  def serialize_config(%__MODULE__{config: config}), do: Map.take(config, @config_fields)

  # Credentials are never serialized, so restoring needs `:api_key` added back.
  @impl true
  def restore_from_map(attrs) do
    case new(attrs) do
      {:ok, model} -> {:ok, model}
      {:error, _reason} -> {:error, "Invalid Anthropic configuration"}
    end
  end

  # Req's :transient set lacks Anthropic's 529 (overloaded). Latency stays
  # bounded: a provider Retry-After is capped, and a receive timeout is not
  # retried (each attempt would wait the full timeout again).
  @retry_statuses [408, 429, 500, 502, 503, 504, 529]
  @reasoning_blocks ["thinking", "redacted_thinking"]
  @default_max_retry_delay_ms 5_000

  # Every retry returns an explicit delay: exponential backoff (1 s, 2 s), or
  # the provider's Retry-After, both capped.
  defp retry?(request, %Req.Response{status: status} = response)
       when status in @retry_statuses do
    {:delay, min(retry_after_ms(response) || backoff_ms(request), max_retry_delay_ms())}
  end

  defp retry?(request, %Req.TransportError{reason: :closed}),
    do: {:delay, min(backoff_ms(request), max_retry_delay_ms())}

  defp retry?(_request, _other), do: false

  defp backoff_ms(request),
    do: 1000 * Integer.pow(2, Req.Request.get_private(request, :req_retry_count, 0))

  defp retry_after_ms(response) do
    case Req.Response.get_header(response, "retry-after") do
      [] ->
        nil

      [value | _] ->
        case Integer.parse(value) do
          {seconds, ""} when seconds >= 0 -> seconds * 1000
          # An HTTP-date or malformed value: wait the cap, never longer.
          _other -> max_retry_delay_ms()
        end
    end
  end

  defp max_retry_delay_ms,
    do: Application.get_env(:alethea, :anthropic_retry_max_delay_ms, @default_max_retry_delay_ms)

  defp decode(%{"content" => [_ | _] = blocks, "stop_reason" => stop})
       when stop in ["end_turn", "stop_sequence", "max_tokens"] do
    # Reasoning blocks carry no reply text and are dropped; every other block
    # must be text, and at least one must be non-blank.
    blocks = Enum.reject(blocks, &match?(%{"type" => type} when type in @reasoning_blocks, &1))

    if blocks != [] and
         Enum.all?(blocks, &match?(%{"type" => "text", "text" => text} when is_binary(text), &1)) do
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

  # The haiku-5 family rejects `temperature` with HTTP 400 ("'temperature'
  # is deprecated for this model"), whatever its value, and runs adaptive
  # thinking by default: thinking tokens count against `max_tokens` (160 for
  # guided replies) and can leave no room for the reply. Thinking is disabled
  # explicitly, which this family accepts at its default `medium` effort.
  # Every other model keeps the payload as serialized.
  defp haiku_5_payload(payload, model) do
    if is_binary(model) and String.contains?(model, "haiku-5") do
      payload
      |> Map.delete(:temperature)
      |> Map.put(:thinking, %{type: "disabled"})
    else
      payload
    end
  end
end
