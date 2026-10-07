defmodule Alethea.AI.Whisper.Disabled do
  @moduledoc """
  Transcription adapter for a deployment where the capability is switched
  off (issue #402).

  Production wires this module into the `:ai_whisper` slot: no production
  transcription adapter exists yet, and the Fake must never be reachable
  there. `transcribe/2` returns `{:error, :disabled}` and never a
  transcript, so an empty transcription cannot be mistaken for a real one.
  `Alethea.AI.enabled?(:ai_whisper)` answers the question without calling
  the adapter.
  """

  use Alethea.AI.Whisper

  @impl true
  def transcribe(_audio, _opts), do: {:error, :disabled}
end
