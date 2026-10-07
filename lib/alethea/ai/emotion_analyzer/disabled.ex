defmodule Alethea.AI.EmotionAnalyzer.Disabled do
  @moduledoc """
  Emotion-analyzer adapter for a deployment where the capability is
  explicitly switched off (issue #402).

  Production wires this module into the `:emotion_analyzer` slot when
  `EMOTION_ANALYZER_ENABLED=false`, so "disabled" is a configured state
  instead of an unset key that raises. Callers that can skip the work ask
  `Alethea.AI.enabled?(:emotion_analyzer)` first; a caller that does not
  ask still gets the behaviour's fail-closed answer.

  It never returns scores: a disabled capability must not leave emotion
  data, trends or any other derived record in the clinical record.
  """

  @behaviour Alethea.AI.EmotionAnalyzerBehaviour

  @impl true
  def analyze_batch(_texts), do: {:error, :unavailable}
end
