defmodule Alethea.AI.Whisper.OpenAICompatible do
  @moduledoc """
  Speech-to-text adapter for any OpenAI-compatible
  `POST /audio/transcriptions` endpoint: OpenAI, Groq, or a local Whisper
  server (for example faster-whisper-server).

  Sends a multipart form (`file`, `model`, `language`,
  `response_format=verbose_json`, `timestamp_granularities[]=segment`).
  These endpoints do not separate speakers, so every segment has
  `speaker: nil`.

  ## Configuration

      config :alethea, Alethea.AI.Whisper.OpenAICompatible,
        endpoint_url: "https://api.openai.com/v1",
        api_key: "...",            # optional; no header when nil
        model: "whisper-1",
        receive_timeout: 600_000

  Extra `Req` options (tests inject a `Req.Test` plug) come from
  `config :alethea, :whisper_req_options`.

  Never logs audio or transcript text.
  """

  use Alethea.AI.Whisper

  @default_model "whisper-1"
  @default_timeout 600_000
  @default_language "es"

  @extensions %{
    "audio/webm" => "webm",
    "video/webm" => "webm",
    "audio/ogg" => "ogg",
    "audio/opus" => "ogg",
    "audio/mpeg" => "mp3",
    "audio/mp3" => "mp3",
    "audio/mp4" => "m4a",
    "audio/m4a" => "m4a",
    "audio/x-m4a" => "m4a",
    "audio/aac" => "m4a",
    "video/mp4" => "mp4",
    "audio/wav" => "wav",
    "audio/wave" => "wav",
    "audio/x-wav" => "wav",
    "audio/flac" => "flac",
    "audio/x-flac" => "flac"
  }

  @impl true
  def transcribe(audio, opts) when is_binary(audio) do
    language = Keyword.get(opts, :language, @default_language)

    with {:ok, content_type} <- fetch_content_type(opts),
         {:ok, extension} <- extension(content_type) do
      audio
      |> request(content_type, extension, language)
      |> handle_response(language)
    end
  end

  defp fetch_content_type(opts) do
    case Keyword.get(opts, :content_type) do
      content_type when is_binary(content_type) and content_type != "" -> {:ok, content_type}
      _missing -> {:error, :missing_content_type}
    end
  end

  # "audio/webm;codecs=opus" -> "audio/webm"
  defp extension(content_type) do
    mime =
      content_type
      |> String.split(";", parts: 2)
      |> hd()
      |> String.trim()
      |> String.downcase()

    case Map.fetch(@extensions, mime) do
      {:ok, extension} -> {:ok, extension}
      :error -> {:error, :unsupported_content_type}
    end
  end

  defp request(audio, content_type, extension, language) do
    form = [
      file: {audio, filename: "audio." <> extension, content_type: content_type},
      model: config(:model, @default_model),
      language: language,
      response_format: "verbose_json",
      "timestamp_granularities[]": "segment"
    ]

    req_opts =
      [
        url: endpoint_url() <> "/audio/transcriptions",
        form_multipart: form,
        headers: auth_headers(),
        receive_timeout: config(:receive_timeout, @default_timeout),
        retry: false
      ] ++ Application.get_env(:alethea, :whisper_req_options, [])

    Req.post(req_opts)
  end

  defp handle_response({:ok, %Req.Response{status: status, body: body}}, language)
       when status in 200..299 do
    case parse(decode(body), language) do
      {:ok, transcription} -> {:ok, transcription}
      :error -> {:error, :invalid_response}
    end
  end

  defp handle_response({:ok, %Req.Response{status: status}}, _language),
    do: {:error, {:http_status, status}}

  defp handle_response({:error, %Req.TransportError{reason: :timeout}}, _language),
    do: {:error, :timeout}

  defp handle_response({:error, %Req.TransportError{reason: reason}}, _language),
    do: {:error, {:transport, reason}}

  defp handle_response({:error, exception}, _language),
    do: {:error, {:transport, exception.__struct__}}

  defp decode(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _} -> nil
    end
  end

  defp decode(body), do: body

  defp parse(%{"text" => text} = body, language) when is_binary(text) do
    with segments when is_list(segments) <- body["segments"] || [],
         {:ok, segments} <- segments(segments) do
      {:ok,
       %{
         text: String.trim(text),
         language: language(body["language"]) || language,
         duration: duration(body["duration"]),
         segments: segments
       }}
    else
      _invalid -> :error
    end
  end

  defp parse(_body, _language), do: :error

  defp segments(raw_segments) do
    Enum.reduce_while(raw_segments, {:ok, []}, fn
      %{"start" => start, "end" => finish, "text" => text}, {:ok, acc}
      when is_number(start) and is_number(finish) and is_binary(text) ->
        case String.trim(text) do
          "" ->
            {:cont, {:ok, acc}}

          trimmed ->
            {:cont, {:ok, [%{start: start, end: finish, text: trimmed, speaker: nil} | acc]}}
        end

      _invalid, _acc ->
        {:halt, :error}
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      :error -> :error
    end
  end

  defp language(language) when is_binary(language) and language != "", do: language
  defp language(_other), do: nil

  defp duration(duration) when is_number(duration), do: duration
  defp duration(_other), do: nil

  defp endpoint_url, do: config(:endpoint_url, "") |> String.trim_trailing("/")

  defp auth_headers do
    case config(:api_key, nil) do
      key when is_binary(key) and key != "" -> [{"authorization", "Bearer " <> key}]
      _none -> []
    end
  end

  defp config(key, default) do
    :alethea
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(key, default)
  end
end
