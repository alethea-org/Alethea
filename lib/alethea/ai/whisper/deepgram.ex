defmodule Alethea.AI.Whisper.Deepgram do
  @moduledoc """
  Deepgram speech-to-text adapter (pre-recorded audio, `POST /v1/listen`).

  Sends the raw audio with its content type and asks for utterances with
  speaker separation (`diarize_model=latest`), so each segment carries a
  zero-based `speaker`.

  ## Configuration

      config :alethea, Alethea.AI.Whisper.Deepgram,
        api_key: "...",
        model: "nova-3",
        base_url: "https://api.deepgram.com",
        receive_timeout: 600_000

  Extra `Req` options (tests inject a `Req.Test` plug) come from
  `config :alethea, :whisper_req_options`.

  ## Response mapping

  - `segments` — `results.utterances[]` (`start`, `end`, `transcript`,
    `speaker`). An utterance without `speaker` takes the majority speaker of
    the words inside its time span, or `nil`. Blank utterances are dropped.
  - `text` — `results.channels[0].alternatives[0].transcript`.
  - `duration` — `metadata.duration`.
  - `language` — the detected language when present, else the requested one.

  Never logs audio or transcript text.
  """

  use Alethea.AI.Whisper

  @default_model "nova-3"
  @default_base_url "https://api.deepgram.com"
  @default_timeout 600_000
  @default_language "es"

  @impl true
  def transcribe(audio, opts) when is_binary(audio) do
    language = Keyword.get(opts, :language, @default_language)

    case Keyword.get(opts, :content_type) do
      content_type when is_binary(content_type) and content_type != "" ->
        audio |> request(content_type, language) |> handle_response(language)

      _missing ->
        {:error, :missing_content_type}
    end
  end

  defp request(audio, content_type, language) do
    params = [
      model: config(:model, @default_model),
      language: language,
      utterances: true,
      diarize_model: "latest",
      punctuate: true,
      smart_format: true
    ]

    req_opts =
      [
        url: base_url() <> "/v1/listen",
        params: params,
        headers: [
          {"authorization", "Token " <> to_string(config(:api_key, ""))},
          {"content-type", content_type}
        ],
        body: audio,
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

  defp parse(
         %{"results" => %{"channels" => [%{"alternatives" => [alternative | _]} = channel | _]}} =
           body,
         language
       )
       when is_map(alternative) do
    results = body["results"]
    words = if is_list(alternative["words"]), do: alternative["words"], else: []

    with text when is_binary(text) <- alternative["transcript"],
         utterances when is_list(utterances) <- results["utterances"] || [],
         {:ok, segments} <- segments(utterances, words) do
      {:ok,
       %{
         text: text,
         language: detected_language(channel) || language,
         duration: duration(body["metadata"]),
         segments: segments
       }}
    else
      _invalid -> :error
    end
  end

  defp parse(_body, _language), do: :error

  defp segments(utterances, words) do
    Enum.reduce_while(utterances, {:ok, []}, fn utterance, {:ok, acc} ->
      case segment(utterance, words) do
        {:ok, nil} -> {:cont, {:ok, acc}}
        {:ok, segment} -> {:cont, {:ok, [segment | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      :error -> :error
    end
  end

  defp segment(%{"start" => start, "end" => finish, "transcript" => text} = utterance, words)
       when is_number(start) and is_number(finish) and is_binary(text) do
    trimmed = String.trim(text)

    if trimmed == "" do
      {:ok, nil}
    else
      speaker = speaker(utterance["speaker"]) || majority_speaker(words, start, finish)
      {:ok, %{start: start, end: finish, text: trimmed, speaker: speaker}}
    end
  end

  defp segment(_utterance, _words), do: :error

  defp speaker(speaker) when is_integer(speaker) and speaker >= 0, do: speaker
  defp speaker(_other), do: nil

  # Ties go to the lowest speaker number so the result is deterministic.
  defp majority_speaker(words, start, finish) do
    words
    |> Enum.filter(&word_within?(&1, start, finish))
    |> Enum.map(&speaker(&1["speaker"]))
    |> Enum.reject(&is_nil/1)
    |> Enum.frequencies()
    |> Enum.sort_by(fn {speaker, count} -> {-count, speaker} end)
    |> case do
      [{speaker, _count} | _] -> speaker
      [] -> nil
    end
  end

  defp word_within?(%{"start" => w_start, "end" => w_end}, start, finish)
       when is_number(w_start) and is_number(w_end),
       do: w_start >= start and w_end <= finish

  defp word_within?(_word, _start, _finish), do: false

  defp detected_language(%{"detected_language" => language})
       when is_binary(language) and language != "",
       do: language

  defp detected_language(_channel), do: nil

  defp duration(%{"duration" => duration}) when is_number(duration), do: duration
  defp duration(_metadata), do: nil

  defp base_url, do: config(:base_url, @default_base_url) |> String.trim_trailing("/")

  defp config(key, default) do
    :alethea
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(key, default)
  end
end
