defmodule Alethea.Clinical.EmotionAnalysis do
  @moduledoc """
  Almacena el resultado canónico del análisis de emociones.
  Cada mensaje puede tener un único análisis de emociones asociado.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @canonical_labels ~w(joy sadness anger fear neutral)
  @score_fields [:joy_score, :sadness_score, :anger_score, :fear_score, :neutral_score]

  schema "emotion_analyses" do
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
      :joy_score,
      :sadness_score,
      :anger_score,
      :fear_score,
      :neutral_score,
      :dominant_label,
      :confidence,
      :processed_at
    ])
    |> validate_required([
      :message_id,
      :dominant_label,
      :confidence,
      :processed_at | @score_fields
    ])
    |> validate_inclusion(:dominant_label, @canonical_labels)
    |> validate_number(:confidence, greater_than: 0.0, less_than_or_equal_to: 1.0)
    |> validate_scores()
    |> validate_nonzero_scores()
  end

  @doc false
  def canonical_scores(results) when is_list(results) do
    with {:ok, scores} <- collect_scores(results),
         true <- map_size(scores) == length(@canonical_labels),
         true <- Enum.any?(scores, fn {_label, score} -> score > 0.0 end) do
      {:ok,
       %{
         joy_score: scores["joy"],
         sadness_score: scores["sadness"],
         anger_score: scores["anger"],
         fear_score: scores["fear"],
         neutral_score: scores["neutral"],
         dominant_label: dominant_label(scores),
         confidence: Enum.max(Map.values(scores))
       }}
    else
      _ -> {:error, :invalid_emotion_scores}
    end
  end

  def canonical_scores(_), do: {:error, :invalid_emotion_scores}

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

  defp validate_scores(changeset) do
    Enum.reduce(@score_fields, changeset, fn field, changeset ->
      validate_number(changeset, field, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    end)
  end

  defp validate_nonzero_scores(changeset) do
    if Enum.all?(@score_fields, &(get_field(changeset, &1) == 0.0)) do
      add_error(changeset, :confidence, "must have at least one non-zero score")
    else
      changeset
    end
  end

  defp collect_scores(results) do
    Enum.reduce_while(results, {:ok, %{}}, fn
      %{label: label, score: score}, {:ok, scores}
      when is_binary(label) and is_number(score) and score == score and score >= 0.0 and
             score <= 1.0 ->
        if label in @canonical_labels and not Map.has_key?(scores, label) do
          {:cont, {:ok, Map.put(scores, label, score)}}
        else
          {:halt, {:error, :invalid_emotion_scores}}
        end

      _result, _scores ->
        {:halt, {:error, :invalid_emotion_scores}}
    end)
  end

  defp dominant_label(scores) do
    {label, _score} = Enum.max_by(scores, fn {_label, score} -> score end)
    label
  end
end
