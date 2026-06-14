defmodule Alethea.AI.Whisper.Fake do
  @moduledoc """
  No-op Whisper adapter for the `:test` and `:dev` environments.

  Implements the `Alethea.AI.Whisper` behaviour with a deterministic
  empty transcription. It does not call any external service, does
  not hit the network, and is safe to use in tests and local
  development.

  ## Why empty

  Tests that wire Whisper into the RAG ingest loop need a stable
  shape but do not need real audio transcription (the RAG test
  fixtures already include pre-transcribed text). The Fake
  returns `text: ""`, `segments: []`, `language: nil` — a
  transcription-shaped value the domain code can branch on.

  ## Production swap

  The production adapter is `Alethea.AI.Whisper.Groq`, scoped to
  the `ai-whisper-groq-foundation` change. The swap happens in
  `config :alethea, :ai_whisper, Alethea.AI.Whisper.Groq` —
  this module's surface stays stable.
  """

  use Alethea.AI.Whisper

  @impl true
  def transcribe(_audio, _opts) do
    {:ok, empty_transcription()}
  end

  defp empty_transcription do
    %{text: "", segments: [], language: nil}
  end
end
