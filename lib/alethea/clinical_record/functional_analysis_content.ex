defmodule Alethea.ClinicalRecord.FunctionalAnalysisContent do
  @moduledoc """
  Canonical plaintext representation of expanded E-O-R-C draft content.

  This module is the boundary between string-keyed form parameters and the
  single plaintext body encrypted by the clinical-record context. Structured
  bodies use a sentinel plus a versioned JSON envelope. Any body that does not
  match the complete supported envelope is treated as legacy text and preserved
  byte-for-byte in `previous_notes`.

  `previous_notes` is storage for legacy or explicitly entered notes only. Its
  content is never interpreted to populate E-O-R-C fields.
  """

  @sentinel "ALETHEA_FUNCTIONAL_ANALYSIS_CONTENT\n"
  @format "alethea.functional-analysis-content"
  @version 1

  @fields [
    :antecedents_distal,
    :antecedents_immediate,
    :organism_sleep,
    :organism_pain_or_discomfort,
    :organism_hunger_or_nutrition,
    :organism_learning_history,
    :response_physiological,
    :response_cognitive,
    :response_motor,
    :consequences_short_term,
    :consequences_long_term,
    :previous_notes
  ]

  @enforce_keys []
  defstruct Enum.map(@fields, &{&1, ""})

  @type t :: %__MODULE__{
          antecedents_distal: String.t(),
          antecedents_immediate: String.t(),
          organism_sleep: String.t(),
          organism_pain_or_discomfort: String.t(),
          organism_hunger_or_nutrition: String.t(),
          organism_learning_history: String.t(),
          response_physiological: String.t(),
          response_cognitive: String.t(),
          response_motor: String.t(),
          consequences_short_term: String.t(),
          consequences_long_term: String.t(),
          previous_notes: String.t()
        }

  @doc "Builds normalized content from string-keyed form parameters."
  @spec new(map()) :: t()
  def new(params) when is_map(params) do
    values =
      Map.new(@fields, fn field ->
        value = Map.get(params, Atom.to_string(field))
        {field, if(is_binary(value), do: value, else: "")}
      end)

    struct!(__MODULE__, values)
  end

  @doc "Serializes content to the deterministic plaintext body used for encryption and RAG."
  @spec serialize(t()) :: String.t()
  def serialize(%__MODULE__{} = content) do
    ordered_fields =
      Enum.map(@fields, fn field ->
        [Atom.to_string(field), Map.fetch!(content, field)]
      end)

    @sentinel <> Jason.encode!([@format, @version, ordered_fields])
  end

  @doc """
  Parses a stored plaintext body.

  Complete supported envelopes return `{:structured, content}`. All other
  binaries return `{:legacy, content}` with the original body unchanged in
  `previous_notes`.
  """
  @spec parse(binary()) :: {:structured, t()} | {:legacy, t()}
  def parse(body) when is_binary(body) do
    case body do
      <<@sentinel, payload::binary>> -> parse_envelope(payload, body)
      _other -> legacy(body)
    end
  end

  defp parse_envelope(payload, original_body) do
    with {:ok, [@format, @version, pairs]} <- Jason.decode(payload),
         true <- valid_pairs?(pairs) do
      params = Map.new(pairs, fn [name, value] -> {name, value} end)
      {:structured, new(params)}
    else
      _invalid -> legacy(original_body)
    end
  end

  defp valid_pairs?(pairs) when is_list(pairs) do
    expected_names = Enum.map(@fields, &Atom.to_string/1)

    names_and_values =
      Enum.reduce_while(pairs, {[], []}, fn
        [name, value], {names, values} when is_binary(name) and is_binary(value) ->
          {:cont, {[name | names], [value | values]}}

        _invalid, _acc ->
          {:halt, :invalid}
      end)

    case names_and_values do
      {names, _values} -> Enum.reverse(names) == expected_names
      :invalid -> false
    end
  end

  defp valid_pairs?(_pairs), do: false

  defp legacy(body), do: {:legacy, %__MODULE__{previous_notes: body}}
end
