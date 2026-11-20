defmodule Alethea.AI.Whisper.Fake do
  @moduledoc """
  No-op Whisper adapter for the `:test` environment.

  Implements the `Alethea.AI.Whisper` behaviour with a deterministic
  empty transcription. It does not call any external service and does
  not hit the network.

  ## Why empty

  Tests that wire Whisper into the RAG ingest loop need a stable
  shape but do not need real audio transcription (the RAG test
  fixtures already include pre-transcribed text). The Fake
  returns `text: ""`, `segments: []`, `language: nil`,
  `duration: nil` — a transcription-shaped value the domain code can
  branch on.

  ## Production swap

  `config/runtime.exs` wires `Alethea.AI.Whisper.Deepgram` or
  `Alethea.AI.Whisper.OpenAICompatible` (see
  `Alethea.AI.Whisper.runtime_config/1`); the Fake is never selectable
  there.
  """

  use Alethea.AI.Whisper

  @impl true
  def transcribe(_audio, _opts) do
    {:ok, empty_transcription()}
  end

  defp empty_transcription do
    %{text: "", segments: [], language: nil, duration: nil}
  end
end
