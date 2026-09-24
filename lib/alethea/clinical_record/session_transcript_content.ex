defmodule Alethea.ClinicalRecord.SessionTranscriptContent do
  @moduledoc """
  Validating constructor and serializer for speech spans (#317, AD1).

  Unlike `FunctionalAnalysisContent`, `new/1` is the write-time validation
  gate: a result tuple, rejecting the whole transcript on the first invalid
  span, never partially. `serialize/1` is total. `parse/1` re-runs the same
  checks as defense-in-depth — no legacy body exists (greenfield table).
  """

  @sentinel "ALETHEA_SESSION_TRANSCRIPT_SPANS\n"
  @format "alethea.session-transcript-spans"
  @version 1
  @speakers ~w(patient therapist)

  @enforce_keys [:spans]
  defstruct spans: []

  @type speaker :: String.t()
  @type span :: %{start: number(), end: number(), speaker: speaker(), text: String.t()}
  @type t :: %__MODULE__{spans: [span()]}
  @type error :: :empty_transcript | :invalid_span | :invalid_speaker

  @span_keys MapSet.new([:start, :end, :speaker, :text])

  @doc "Returns the accepted speaker values, `~w(patient therapist)`."
  @spec speakers() :: [String.t()]
  def speakers, do: @speakers

  @doc """
  Validating constructor — the write-time gate (AD1). Rejects the whole list
  on the first invalid span; never a partial acceptance.
  """
  @spec new([map()]) :: {:ok, t()} | {:error, error()}
  def new([]), do: {:error, :empty_transcript}

  def new(spans) when is_list(spans) do
    Enum.reduce_while(spans, :ok, fn span, :ok ->
      case validate_span(span) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      :ok -> {:ok, %__MODULE__{spans: spans}}
      {:error, _reason} = error -> error
    end
  end

  defp validate_span(%{start: start, end: stop, speaker: speaker, text: text} = span) do
    with true <- MapSet.new(Map.keys(span)) == @span_keys || :invalid_span,
         true <- (is_number(start) and is_number(stop)) || :invalid_span,
         true <- start <= stop || :invalid_span,
         true <- is_binary(text) || :invalid_span,
         true <- speaker in @speakers || :invalid_speaker do
      :ok
    else
      reason when is_atom(reason) -> {:error, reason}
    end
  end

  defp validate_span(_span), do: {:error, :invalid_span}

  @doc "Serializes an already-validated struct. Total."
  @spec serialize(t()) :: String.t()
  def serialize(%__MODULE__{spans: spans}) do
    ordered_spans =
      Enum.map(spans, fn %{start: start, end: stop, speaker: speaker, text: text} ->
        [start, stop, speaker, text]
      end)

    @sentinel <> Jason.encode!([@format, @version, ordered_spans])
  end

  @doc "Parses a stored plaintext body. Total; never raises."
  @spec parse(binary()) :: {:ok, t()} | {:error, :malformed}
  def parse(body) when is_binary(body) do
    case body do
      <<@sentinel, payload::binary>> -> parse_envelope(payload)
      _other -> {:error, :malformed}
    end
  end

  defp parse_envelope(payload) do
    with {:ok, [@format, @version, raw_spans]} <- Jason.decode(payload),
         {:ok, spans} <- decode_spans(raw_spans) do
      {:ok, %__MODULE__{spans: spans}}
    else
      _invalid -> {:error, :malformed}
    end
  end

  defp decode_spans(raw_spans) when is_list(raw_spans) do
    Enum.reduce_while(raw_spans, {:ok, []}, fn raw_span, {:ok, acc} ->
      case decode_span(raw_span) do
        {:ok, span} -> {:cont, {:ok, [span | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      :error -> :error
    end
  end

  defp decode_spans(_raw_spans), do: :error

  defp decode_span([start, stop, speaker, text]) do
    span = %{start: start, end: stop, speaker: speaker, text: text}

    case validate_span(span) do
      :ok -> {:ok, span}
      {:error, _reason} -> :error
    end
  end

  defp decode_span(_raw_span), do: :error
end
