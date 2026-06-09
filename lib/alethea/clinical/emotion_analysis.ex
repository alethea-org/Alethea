defmodule Alethea.Clinical.EmotionAnalysis do
  @moduledoc """
  Almacena el resultado del análisis de emociones realizado por RoBERTa.
  Cada mensaje puede tener un único análisis de emociones asociado.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @canonical_labels [:joy, :sadness, :anger, :fear, :neutral]
  @canonical_label_strings Enum.map(@canonical_labels, &Atom.to_string/1)

  schema "emotion_analyses" do
    field(:model_version, :string, default: "robertuito-emotion-analysis")

    field(:joy_score, :float)
    field(:sadness_score, :float)
    field(:anger_score, :float)
    field(:fear_score, :float)
    field(:neutral_score, :float)

    field(:dominant_label, :string)
    field(:confidence, :float)

    field(:processed_at, :utc_datetime)

    belongs_to(:message, Alethea.Clinical.Message)

    timestamps(type: :utc_datetime)
  end

  @doc """
  Crea un changeset para insertar un nuevo análisis de emociones.
  """
  def changeset(emotion_analysis, attrs) do
    emotion_analysis
    |> cast(attrs, [
      :message_id,
      :model_version,
      :joy_score,
      :sadness_score,
      :anger_score,
      :fear_score,
      :neutral_score,
      :dominant_label,
      :confidence,
      :processed_at
    ])
    |> validate_required([:message_id])
    |> validate_inclusion(:dominant_label, @canonical_label_strings ++ [nil])
  end

  @doc """
  Builds emotion analysis attributes from canonical RoBERTa score maps.
  """
  def attrs_from_scores(emotion_scores, extra_attrs \\ %{}) when is_list(emotion_scores) do
    score_map =
      Enum.reduce(emotion_scores, empty_score_map(), fn emotion_score, acc ->
        label = score_label(emotion_score)
        score = score_value(emotion_score)

        if label in @canonical_label_strings do
          Map.put(acc, label, score)
        else
          acc
        end
      end)

    {dominant_label, confidence} = dominant(score_map)

    %{
      joy_score: Map.fetch!(score_map, "joy"),
      sadness_score: Map.fetch!(score_map, "sadness"),
      anger_score: Map.fetch!(score_map, "anger"),
      fear_score: Map.fetch!(score_map, "fear"),
      neutral_score: Map.fetch!(score_map, "neutral"),
      dominant_label: dominant_label,
      confidence: confidence
    }
    |> Map.merge(extra_attrs)
  end

  @doc """
  Calcula el label dominante y confidence a partir de los scores.
  """
  def compute_dominant(%__MODULE__{} = analysis) do
    scores = %{
      joy: analysis.joy_score,
      sadness: analysis.sadness_score,
      anger: analysis.anger_score,
      fear: analysis.fear_score,
      neutral: analysis.neutral_score
    }

    {label, score} =
      scores
      |> Enum.reject(fn {_, v} -> is_nil(v) or v == 0.0 end)
      |> Enum.max_by(fn {_, v} -> v end, fn -> {:neutral, 0.0} end)

    %{label: label, confidence: score}
  end

  @doc """
  Formatea todos los scores como string para contexto de LLM.
  """
  def to_context_string(%__MODULE__{} = analysis) do
    "joy: #{format_score(analysis.joy_score)}, " <>
      "sadness: #{format_score(analysis.sadness_score)}, " <>
      "anger: #{format_score(analysis.anger_score)}, " <>
      "fear: #{format_score(analysis.fear_score)}, " <>
      "neutral: #{format_score(analysis.neutral_score)}"
  end

  defp format_score(nil), do: "N/A"
  defp format_score(score) when is_float(score), do: :erlang.float_to_binary(score, decimals: 3)

  defp empty_score_map do
    Map.new(@canonical_label_strings, fn label -> {label, 0.0} end)
  end

  defp score_label(%{label: label}), do: to_string(label)
  defp score_label(%{"label" => label}), do: to_string(label)
  defp score_label(_emotion_score), do: nil

  defp score_value(%{score: score}), do: number_score(score)
  defp score_value(%{"score" => score}), do: number_score(score)
  defp score_value(_emotion_score), do: 0.0

  defp number_score(score) when is_number(score), do: score / 1
  defp number_score(_score), do: 0.0

  defp dominant(score_map) do
    if Enum.all?(score_map, fn {_label, score} -> score == 0.0 end) do
      {"neutral", 0.0}
    else
      Enum.max_by(@canonical_label_strings, &Map.fetch!(score_map, &1))
      |> then(fn label -> {label, Map.fetch!(score_map, label)} end)
    end
  end
end
