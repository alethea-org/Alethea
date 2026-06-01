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
    |> validate_inclusion(:dominant_label, @canonical_labels ++ [nil])
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
end
