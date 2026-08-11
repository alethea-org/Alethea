defmodule Alethea.AI.EmotionAnalyzerBehaviour do
  @moduledoc false

  @type score :: %{label: String.t(), score: float()}
  @callback analyze_batch([String.t()]) :: {:ok, [score()]} | {:error, :unavailable}
end
